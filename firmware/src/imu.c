/*
 * IMU capture: the LSM6DSV32X batches accelerometer, gyroscope and its own
 * timestamp into its FIFO at 120 Hz. On each FIFO watermark the thread
 *  1. reads the IMU timestamp counter bracketed by two session-clock reads,
 *     giving an anchor (IMU ticks <-> session microseconds) for the phone's
 *     clock fit, and
 *  2. drains the FIFO into BLE packets, each sample with its own IMU
 *     timestamp (see protocol.h).
 *
 * Between sessions the IMU runs only its accelerometer in 15 Hz low-power
 * mode with the activity/inactivity function: after ~68 s without motion it
 * reports "stationary" on INT1 (and drops to its sleep rate), and motion
 * reports "moving" again. That drives the power policy.
 */
#include "imu.h"

#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/task_wdt/task_wdt.h>

#include "ble.h"
#include "power.h"
#include "protocol.h"
#include "timebase.h"

LOG_MODULE_REGISTER(imu, LOG_LEVEL_INF);

#define REG_FIFO_CTRL1       0x07
#define REG_FIFO_CTRL2       0x08
#define REG_FIFO_CTRL3       0x09
#define REG_FIFO_CTRL4       0x0A
#define REG_INT1_CTRL        0x0D
#define REG_WHO_AM_I         0x0F
#define REG_CTRL1            0x10
#define REG_CTRL2            0x11
#define REG_CTRL3            0x12
#define REG_CTRL6            0x15
#define REG_CTRL8            0x17
#define REG_FIFO_STATUS1     0x1B
#define REG_TIMESTAMP0       0x40
#define REG_INTERNAL_FREQ    0x4F
#define REG_FUNCTIONS_ENABLE 0x50
#define REG_FIFO_DATA_OUT    0x78
#define REG_WAKE_UP_SRC      0x45
#define REG_INACTIVITY_DUR   0x54
#define REG_INACTIVITY_THS   0x55
#define REG_WAKE_UP_THS      0x5B
#define REG_WAKE_UP_DUR      0x5C
#define REG_MD1_CFG          0x5E

#define CTRL3_SW_RESET          BIT(0)
#define CTRL3_IF_INC            BIT(2)
#define CTRL3_BDU               BIT(6)
#define ODR_120HZ               0x06 /* high-performance mode */
#define FS_G_2000DPS            0x04
/* LSM6DSV32X: FS_XL code 1 is +-8 g. CTRL8 bit 2 is factory-set on the 32X
 * and doubles every range, so FS_XL must be written read-modify-write. */
#define FS_XL_8G                0x01
#define FS_XL_MASK              0x03
#define TIMESTAMP_EN            BIT(6)
#define FIFO_BDR_120HZ          0x66 /* gyro [7:4], accel [3:0] */
#define FIFO_TS_EVERY_SAMPLE    (0x01 << 6)
#define FIFO_MODE_BYPASS        0x00
#define FIFO_MODE_CONTINUOUS    0x06
#define INT1_FIFO_TH            BIT(3)
#define FIFO_STATUS2_OVR_IA     BIT(6)

/* Idle motion detection (register values as proven in fing_wild). */
#define ODR_15HZ_LOW_POWER      0x43 /* OP_MODE_XL low-power 1, 15 Hz */
#define INACT_THS_W_31MG        (0x02 << 4)
#define INACT_ODR_15HZ          BIT(2)
#define INACT_WAKE_TWO_SAMPLES  0x01
#define INACT_THS_ONE_LSB       0x01
/* SLEEP_DUR LSB is 512 / ODR_XL s: 2 at 15 Hz is ~68 s. */
#define SLEEP_DUR_68S           0x02
#define MD1_SLEEP_CHANGE        BIT(7)
#define FUNCTIONS_INTERRUPTS    BIT(7)
#define FUNCTIONS_INACT_DEEP    0x03 /* accel to sleep ODR, gyro off */
#define WAKE_UP_SRC_SLEEP_STATE BIT(4)
#define MOTION_POLL             K_SECONDS(10)
#define WDT_TIMEOUT_MS          5000

#define TAG_GYRO      0x01
#define TAG_ACCEL     0x02
#define TAG_TIMESTAMP 0x04

#define ROW_LEN           7
#define ROWS_PER_SAMPLE   3 /* accel, gyro, timestamp */
/* A drain usually finds one or two samples beyond the watermark; 12 keeps
 * a drain inside one 14-sample packet. */
#define WATERMARK_SAMPLES 12
#define POLL_FALLBACK     K_MSEC(200)
/* A timestamp read normally takes ~150 us at 400 kHz; anything slower was
 * preempted (BLE, other I2C users) and would blur the anchor. */
#define ANCHOR_MAX_SPAN_US 400

static const struct i2c_dt_spec bus = I2C_DT_SPEC_GET(DT_ALIAS(accel0));
static const struct gpio_dt_spec int1 = GPIO_DT_SPEC_GET(DT_ALIAS(accel0), int1_gpios);

static struct gpio_callback int1_cb;
static K_SEM_DEFINE(irq_sem, 0, 1);
static K_SEM_DEFINE(parked_sem, 0, 1);
static atomic_t enabled;
static int8_t freq_fine;
static struct imu_stats stats;
static int wdt_channel = -1;

/* One FIFO time slot (TAG_CNT) collects accel, gyro and timestamp rows. */
struct slot {
	int16_t accel[3];
	int16_t gyro[3];
	uint32_t ts;
	uint8_t have;
};
#define HAVE_ACCEL BIT(0)
#define HAVE_GYRO  BIT(1)
#define HAVE_TS    BIT(2)
#define HAVE_ALL   (HAVE_ACCEL | HAVE_GYRO | HAVE_TS)

static struct slot slots[4];

static struct {
	uint8_t buf[DIBS_IMU_HDR_LEN + DIBS_IMU_MAX_SAMPLES * DIBS_IMU_SAMPLE_LEN];
	uint8_t n;
	uint8_t flags;
	uint16_t seq;
	uint32_t anchor_ts;
	uint32_t anchor_us;
} pkt;

static int reg_write(uint8_t reg, uint8_t val)
{
	return i2c_reg_write_byte_dt(&bus, reg, val);
}

static int reg_update(uint8_t reg, uint8_t mask, uint8_t val)
{
	return i2c_reg_update_byte_dt(&bus, reg, mask, val);
}

static int set_fifo_mode(uint8_t mode)
{
	return reg_write(REG_FIFO_CTRL4, FIFO_TS_EVERY_SAMPLE | mode);
}

static void motion_check(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(motion_work, motion_check);

/* Between sessions: read the sleep state on every sleep-change interrupt,
 * and every few seconds in case an edge was missed. */
static void motion_check(struct k_work *work)
{
	uint8_t src;

	if (atomic_get(&enabled)) {
		return;
	}
	if (i2c_reg_read_byte_dt(&bus, REG_WAKE_UP_SRC, &src) == 0) {
		power_set_stationary(src & WAKE_UP_SRC_SLEEP_STATE);
	}
	k_work_reschedule(&motion_work, MOTION_POLL);
}

static void int1_handler(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
	if (atomic_get(&enabled)) {
		k_sem_give(&irq_sem);
	} else {
		k_work_reschedule(&motion_work, K_NO_WAIT);
	}
}

static int motion_arm(void)
{
	int err;

	err = reg_write(REG_INT1_CTRL, 0);
	err |= set_fifo_mode(FIFO_MODE_BYPASS);
	err |= reg_write(REG_CTRL2, 0);
	err |= reg_write(REG_CTRL1, ODR_15HZ_LOW_POWER);
	err |= reg_write(REG_INACTIVITY_DUR,
			 INACT_THS_W_31MG | INACT_ODR_15HZ | INACT_WAKE_TWO_SAMPLES);
	err |= reg_write(REG_INACTIVITY_THS, INACT_THS_ONE_LSB);
	err |= reg_update(REG_WAKE_UP_THS, 0x3F, INACT_THS_ONE_LSB);
	err |= reg_update(REG_WAKE_UP_DUR, 0x0F, SLEEP_DUR_68S);
	err |= reg_write(REG_MD1_CFG, MD1_SLEEP_CHANGE);
	err |= reg_write(REG_FUNCTIONS_ENABLE, FUNCTIONS_INTERRUPTS | FUNCTIONS_INACT_DEEP);
	if (err) {
		LOG_ERR("motion detection setup failed");
		return -EIO;
	}
	gpio_pin_interrupt_configure_dt(&int1, GPIO_INT_EDGE_TO_ACTIVE);
	/* Restarting the function starts from "moving". */
	power_set_stationary(false);
	k_work_reschedule(&motion_work, MOTION_POLL);
	return 0;
}

static void pkt_send(void)
{
	if (pkt.n == 0) {
		return;
	}

	uint8_t *h = pkt.buf;

	sys_put_le16(pkt.seq++, &h[0]);
	h[2] = pkt.n;
	h[3] = pkt.flags;
	sys_put_le32(pkt.anchor_ts, &h[4]);
	sys_put_le32(pkt.anchor_us, &h[8]);

	if (ble_send_imu(pkt.buf, DIBS_IMU_HDR_LEN + pkt.n * DIBS_IMU_SAMPLE_LEN)) {
		stats.dropped_packets++;
	}
	stats.samples += pkt.n;
	pkt.n = 0;
	pkt.flags = 0;
}

static void pkt_add(const struct slot *s)
{
	uint8_t *p = &pkt.buf[DIBS_IMU_HDR_LEN + pkt.n * DIBS_IMU_SAMPLE_LEN];

	sys_put_le32(s->ts, &p[0]);
	for (int i = 0; i < 3; i++) {
		sys_put_le16(s->accel[i], &p[4 + i * 2]);
		sys_put_le16(s->gyro[i], &p[10 + i * 2]);
	}
	if (++pkt.n == DIBS_IMU_MAX_SAMPLES) {
		pkt_send();
	}
}

static void take_anchor(void)
{
	uint8_t reg = REG_TIMESTAMP0, ts[4];
	uint32_t t0 = timebase_now_us();
	int err = i2c_write_read_dt(&bus, &reg, 1, ts, sizeof(ts));
	uint32_t t1 = timebase_now_us();

	if (err) {
		stats.i2c_errors++;
	}
	if (err || t1 - t0 > ANCHOR_MAX_SPAN_US) {
		stats.anchors_rejected++;
		return;
	}
	/* The packet that follows carries the anchor; a packet without a fresh
	 * one has DIBS_IMU_FLAG_ANCHOR clear. */
	pkt.anchor_ts = sys_get_le32(ts);
	pkt.anchor_us = t0 + (t1 - t0) / 2;
	pkt.flags |= DIBS_IMU_FLAG_ANCHOR;
	stats.anchors++;
}

static void flush_fifo(void)
{
	set_fifo_mode(FIFO_MODE_BYPASS);
	set_fifo_mode(FIFO_MODE_CONTINUOUS);
	memset(slots, 0, sizeof(slots));
}

static void drain_fifo(void)
{
	while (atomic_get(&enabled)) {
		uint8_t st[2];
		uint8_t reg = REG_FIFO_STATUS1;

		if (i2c_write_read_dt(&bus, &reg, 1, st, sizeof(st))) {
			stats.i2c_errors++;
			return;
		}
		if (st[1] & FIFO_STATUS2_OVR_IA) {
			LOG_WRN("FIFO overrun, flushing");
			stats.overruns++;
			pkt_send();
			pkt.flags |= DIBS_IMU_FLAG_OVERRUN;
			flush_fifo();
			return;
		}

		uint16_t rows = st[0] | ((st[1] & 0x01) << 8);

		if (rows == 0) {
			return;
		}

		while (rows-- && atomic_get(&enabled)) {
			uint8_t row[ROW_LEN];

			reg = REG_FIFO_DATA_OUT;
			if (i2c_write_read_dt(&bus, &reg, 1, row, sizeof(row))) {
				/* The row may already be popped: start the slots over
				 * rather than pair rows from different samples. */
				stats.i2c_errors++;
				memset(slots, 0, sizeof(slots));
				return;
			}

			uint8_t tag = row[0] >> 3;
			struct slot *s = &slots[(row[0] >> 1) & 0x03];

			switch (tag) {
			case TAG_ACCEL:
				for (int i = 0; i < 3; i++) {
					s->accel[i] = sys_get_le16(&row[1 + i * 2]);
				}
				s->have |= HAVE_ACCEL;
				break;
			case TAG_GYRO:
				for (int i = 0; i < 3; i++) {
					s->gyro[i] = sys_get_le16(&row[1 + i * 2]);
				}
				s->have |= HAVE_GYRO;
				break;
			case TAG_TIMESTAMP:
				s->ts = sys_get_le32(&row[1]);
				s->have |= HAVE_TS;
				break;
			default:
				break;
			}

			if (s->have == HAVE_ALL) {
				pkt_add(s);
				s->have = 0;
			}
		}
	}
}

static void imu_thread(void *p1, void *p2, void *p3)
{
	for (;;) {
		(void)k_sem_take(&irq_sem, POLL_FALLBACK);

		if (!atomic_get(&enabled)) {
			k_sem_give(&parked_sem);
			k_sem_take(&irq_sem, K_FOREVER);
			continue;
		}

		task_wdt_feed(wdt_channel);
		take_anchor();
		/* Watermark INT1 is a level: draining below it re-arms the edge,
		 * and the poll fallback recovers if an edge is ever missed. */
		drain_fifo();
		pkt_send();
	}
}

K_THREAD_DEFINE(imu_tid, 2048, imu_thread, NULL, NULL, NULL, 6, 0, 0);

int imu_init(void)
{
	uint8_t id;
	int err;

	if (!i2c_is_ready_dt(&bus) || !gpio_is_ready_dt(&int1)) {
		return -ENODEV;
	}
	err = i2c_reg_read_byte_dt(&bus, REG_WHO_AM_I, &id);
	if (err || id != 0x70) {
		LOG_ERR("IMU not found (err %d, id 0x%02x)", err, id);
		return -ENODEV;
	}

	/* Software reset to a known state: everything powered down. */
	reg_write(REG_CTRL3, CTRL3_SW_RESET);
	k_msleep(5);
	reg_write(REG_CTRL3, CTRL3_BDU | CTRL3_IF_INC);
	i2c_reg_read_byte_dt(&bus, REG_INTERNAL_FREQ, (uint8_t *)&freq_fine);

	gpio_pin_configure_dt(&int1, GPIO_INPUT);
	gpio_init_callback(&int1_cb, int1_handler, BIT(int1.pin));
	gpio_add_callback(int1.port, &int1_cb);

	LOG_INF("LSM6DSV32X ready, freq fine %d", freq_fine);
	return motion_arm();
}

int imu_start(void)
{
	int err;

	memset(&stats, 0, sizeof(stats));
	memset(slots, 0, sizeof(slots));
	memset(&pkt, 0, sizeof(pkt));

	/* Leave motion detection: it would change the ODR when still. */
	gpio_pin_interrupt_configure_dt(&int1, GPIO_INT_DISABLE);
	k_work_cancel_delayable(&motion_work);
	err = reg_write(REG_MD1_CFG, 0);
	err |= reg_write(REG_FUNCTIONS_ENABLE, 0);
	err |= reg_update(REG_CTRL6, 0x0F, FS_G_2000DPS);
	err |= reg_update(REG_CTRL8, FS_XL_MASK, FS_XL_8G);
	err |= reg_update(REG_FUNCTIONS_ENABLE, TIMESTAMP_EN, TIMESTAMP_EN);
	err |= reg_write(REG_FIFO_CTRL1, WATERMARK_SAMPLES * ROWS_PER_SAMPLE);
	err |= reg_write(REG_FIFO_CTRL2, 0);
	err |= reg_write(REG_FIFO_CTRL3, FIFO_BDR_120HZ);
	err |= set_fifo_mode(FIFO_MODE_BYPASS);
	err |= set_fifo_mode(FIFO_MODE_CONTINUOUS);
	err |= reg_write(REG_INT1_CTRL, INT1_FIFO_TH);
	err |= reg_write(REG_CTRL1, ODR_120HZ);
	err |= reg_write(REG_CTRL2, ODR_120HZ);
	if (err) {
		LOG_ERR("IMU configuration failed");
		return -EIO;
	}

	wdt_channel = task_wdt_add(WDT_TIMEOUT_MS, NULL, NULL);
	gpio_pin_interrupt_configure_dt(&int1, GPIO_INT_EDGE_TO_ACTIVE);
	atomic_set(&enabled, 1);
	k_sem_give(&irq_sem);
	LOG_INF("IMU streaming %u Hz, +-%u g, +-%u dps", IMU_ODR_HZ, IMU_ACCEL_FS_G,
		IMU_GYRO_FS_DPS);
	return 0;
}

void imu_stop(struct imu_stats *out)
{
	k_sem_reset(&parked_sem);
	atomic_set(&enabled, 0);
	gpio_pin_interrupt_configure_dt(&int1, GPIO_INT_DISABLE);
	k_sem_give(&irq_sem);
	(void)k_sem_take(&parked_sem, K_MSEC(500));

	if (wdt_channel >= 0) {
		task_wdt_delete(wdt_channel);
		wdt_channel = -1;
	}
	motion_arm();

	LOG_INF("IMU stopped: %u samples, %u anchors (%u rejected), %u overruns, %u dropped, "
		"%u I2C errors", stats.samples, stats.anchors, stats.anchors_rejected,
		stats.overruns, stats.dropped_packets, stats.i2c_errors);
	if (out) {
		*out = stats;
	}
}

int8_t imu_freq_fine(void)
{
	return freq_fine;
}
