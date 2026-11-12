/*
 * IMU capture: the LSM6DSV32X batches accelerometer, gyroscope and its own
 * timestamp into its FIFO. On each FIFO watermark the thread
 *  1. reads the IMU timestamp counter bracketed by two session-clock reads,
 *     giving an anchor (IMU ticks <-> session microseconds) for the phone's
 *     clock fit, and
 *  2. drains the FIFO into BLE packets (see protocol.h).
 * Packets go through the BLE send queue (ble.h), so a slow link never holds
 * up the FIFO drain (the high-rate FIFO fills in ~120 ms).
 *
 * Standard mode: accel + gyro 120 Hz, a timestamp with every sample, one
 * FIFO row per I2C read (as validated in protocol v3).
 * High-rate mode: accel 3840 Hz + gyro 240 Hz, a timestamp every 32 accel
 * samples, FIFO read in bursts of up to 36 rows (the nRF52832 TWIM moves at
 * most 255 bytes per transfer; the FIFO output address rolls back from
 * 0x7E to 0x78 with IF_INC). That is ~4200 rows/s, ~29 kB/s, about 2/3 of
 * the 400 kHz bus.
 *
 * Between sessions the IMU runs only its accelerometer in 15 Hz low-power
 * mode with the activity/inactivity function: after ~68 s without motion it
 * reports "stationary" on INT1 (and drops to its sleep rate), and motion
 * reports "moving" again. That drives the power policy.
 */
#include "imu.h"

#include <string.h>

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
/* ODR codes (CTRL1/CTRL2 ODR fields and FIFO_CTRL3 BDR fields alike);
 * OP_MODE 0 = high-performance. */
#define ODR_120HZ               0x06
#define ODR_240HZ               0x07
#define ODR_3840HZ              0x0B
#define FS_G_2000DPS            0x04
/* LSM6DSV32X: FS_XL code 1 is +-8 g. CTRL8 bit 2 is factory-set on the 32X
 * and doubles every range, so FS_XL must be written read-modify-write. */
#define FS_XL_8G                0x01
#define FS_XL_MASK              0x03
#define TIMESTAMP_EN            BIT(6)
/* FIFO_CTRL4 DEC_TS_BATCH [7:6]: timestamp every 1 / 8 / 32 batches */
#define FIFO_TS_DEC_1           (0x01 << 6)
#define FIFO_TS_DEC_32          (0x03 << 6)
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

#define ROW_LEN       7
#define BURST_ROWS    36 /* 252 bytes: the TWIM's 255-byte limit */
#define POLL_FALLBACK K_MSEC(200)
/* A timestamp read normally takes ~150 us at 400 kHz; anything slower was
 * preempted (BLE, other I2C users) and would blur the anchor. */
#define ANCHOR_MAX_SPAN_US 400
/* Samples from the first 100 ms after power-up are dropped: the first accel
 * samples are garbage (one saturated) and the gyro shows a ~40 ms start-up
 * transient of up to ~35 dps. The microphone drops its first 100 ms too, so
 * both streams begin together, ~0.1 s into the session. */
#define SETTLE_MS 100

struct mode_cfg {
	struct imu_mode_info info;
	uint8_t odr_xl;
	uint8_t odr_g;
	uint8_t bdr;       /* FIFO_CTRL3: gyro [7:4], accel [3:0] */
	uint8_t ts_dec;    /* FIFO_CTRL4 DEC_TS_BATCH */
	uint8_t watermark; /* FIFO rows */
	uint8_t burst;     /* rows per I2C read */
	bool highrate;     /* high-rate packet layout */
};

#define HIGHRATE_CFG {								\
		.info = { .accel_odr_hz = 3840, .gyro_odr_hz = 240, .accel_per_ts = 32 }, \
		.odr_xl = ODR_3840HZ, .odr_g = ODR_240HZ,			\
		.bdr = (ODR_240HZ << 4) | ODR_3840HZ, .ts_dec = FIFO_TS_DEC_32,	\
		/* ~23 ms of rows; the FIFO holds ~120 ms. */			\
		.watermark = 96, .burst = BURST_ROWS, .highrate = true,		\
	}

static const struct mode_cfg modes[] = {
	[DIBS_IMU_MODE_STANDARD] = {
		.info = { .accel_odr_hz = 120, .gyro_odr_hz = 120, .accel_per_ts = 1 },
		.odr_xl = ODR_120HZ, .odr_g = ODR_120HZ,
		.bdr = (ODR_120HZ << 4) | ODR_120HZ, .ts_dec = FIFO_TS_DEC_1,
		/* 12 samples x 3 rows: a drain usually finds one or two samples
		 * beyond the watermark and still fits one 14-sample packet. */
		.watermark = 36, .burst = 1,
	},
	[DIBS_IMU_MODE_HIGHRATE] = HIGHRATE_CFG,
	[DIBS_IMU_MODE_HIGHRATE_IMU_ONLY] = HIGHRATE_CFG,
};

static const struct i2c_dt_spec bus = I2C_DT_SPEC_GET(DT_ALIAS(accel0));
static const struct gpio_dt_spec int1 = GPIO_DT_SPEC_GET(DT_ALIAS(accel0), int1_gpios);

static struct gpio_callback int1_cb;
static K_SEM_DEFINE(irq_sem, 0, 1);
static K_SEM_DEFINE(parked_sem, 0, 1);
static atomic_t enabled;
static int8_t freq_fine;
static struct imu_stats stats;
static int wdt_channel = -1;
static const struct mode_cfg *cfg = &modes[DIBS_IMU_MODE_STANDARD];

/* ---- standard mode: one FIFO time slot (TAG_CNT) collects accel, gyro and
 * timestamp rows into a sample with its own timestamp ---- */

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
/* Accel samples still to drop while the sensors settle (both modes). */
static uint32_t settle_left;

/* Header fields shared by both packet layouts. */
static struct {
	uint16_t seq;
	uint8_t flags;
	uint32_t anchor_ts;
	uint32_t anchor_us;
} hdr;

static struct {
	uint8_t data[DIBS_IMU_MAX_SAMPLES * DIBS_IMU_SAMPLE_LEN];
	uint8_t n;
} std_pkt;

static void put_header(uint8_t *h, uint8_t n, uint8_t flags)
{
	sys_put_le16(hdr.seq++, &h[0]);
	h[2] = n;
	h[3] = hdr.flags | flags;
	sys_put_le32(hdr.anchor_ts, &h[4]);
	sys_put_le32(hdr.anchor_us, &h[8]);
	hdr.flags = 0;
}

static void std_send(void)
{
	if (std_pkt.n == 0) {
		return;
	}

	uint8_t *buf = ble_tx_alloc(BLE_CHAN_IMU);

	if (buf) {
		put_header(buf, std_pkt.n, 0);
		memcpy(&buf[DIBS_IMU_HDR_LEN], std_pkt.data, std_pkt.n * DIBS_IMU_SAMPLE_LEN);
		ble_tx_submit(BLE_CHAN_IMU, buf, DIBS_IMU_HDR_LEN + std_pkt.n * DIBS_IMU_SAMPLE_LEN);
	} else {
		hdr.seq++; /* the phone counts it as lost */
		hdr.flags = 0;
	}
	stats.samples += std_pkt.n;
	std_pkt.n = 0;
}

static void std_add(const struct slot *s)
{
	uint8_t *p = &std_pkt.data[std_pkt.n * DIBS_IMU_SAMPLE_LEN];

	sys_put_le32(s->ts, &p[0]);
	for (int i = 0; i < 3; i++) {
		sys_put_le16(s->accel[i], &p[4 + i * 2]);
		sys_put_le16(s->gyro[i], &p[10 + i * 2]);
	}
	if (++std_pkt.n == DIBS_IMU_MAX_SAMPLES) {
		std_send();
	}
}

static void std_row(uint8_t tag, uint8_t cnt, const uint8_t *d)
{
	struct slot *s = &slots[cnt];

	switch (tag) {
	case TAG_ACCEL:
		for (int i = 0; i < 3; i++) {
			s->accel[i] = sys_get_le16(&d[i * 2]);
		}
		s->have |= HAVE_ACCEL;
		break;
	case TAG_GYRO:
		for (int i = 0; i < 3; i++) {
			s->gyro[i] = sys_get_le16(&d[i * 2]);
		}
		s->have |= HAVE_GYRO;
		break;
	case TAG_TIMESTAMP:
		s->ts = sys_get_le32(d);
		s->have |= HAVE_TS;
		break;
	default:
		stats.bad_tags++;
		break;
	}
	if (s->have == HAVE_ALL) {
		if (settle_left) {
			settle_left--;
		} else {
			std_add(s);
		}
		s->have = 0;
	}
}

/* ---- high-rate mode: accel samples are numbered; gyro and timestamp rows
 * refer to the accel sample of their FIFO time slot ---- */

#define HR_MAX_ACCEL ((DIBS_IMU_HR_MAX_LEN - DIBS_IMU_HR_HDR_LEN) / DIBS_IMU_HR_ACCEL_LEN)
#define HR_MAX_GYRO  ((DIBS_IMU_HR_MAX_LEN - DIBS_IMU_HR_HDR_LEN) / DIBS_IMU_HR_GYRO_LEN)
#define HR_MAX_TS    ((DIBS_IMU_HR_MAX_LEN - DIBS_IMU_HR_HDR_LEN) / DIBS_IMU_HR_TS_LEN)

static struct {
	uint32_t accel_index; /* index of this packet's first accel sample */
	uint8_t na, ng, nt;
	uint8_t accel[HR_MAX_ACCEL][DIBS_IMU_HR_ACCEL_LEN];
	uint8_t gyro[HR_MAX_GYRO][DIBS_IMU_HR_GYRO_LEN];
	uint8_t ts[HR_MAX_TS][DIBS_IMU_HR_TS_LEN];
} hr;

static uint32_t accel_count;  /* accel samples taken from the FIFO */
static bool have_last_accel;
static uint8_t last_accel_cnt; /* TAG_CNT of the latest accel row */
static bool last_accel_settling; /* the latest accel row was dropped */

static size_t hr_len(void)
{
	return DIBS_IMU_HR_HDR_LEN + hr.na * DIBS_IMU_HR_ACCEL_LEN +
	       hr.ng * DIBS_IMU_HR_GYRO_LEN + hr.nt * DIBS_IMU_HR_TS_LEN;
}

static void hr_send(void)
{
	if (hr.na + hr.ng + hr.nt == 0) {
		hr.accel_index = accel_count;
		return;
	}

	uint8_t *buf = ble_tx_alloc(BLE_CHAN_IMU);

	if (buf) {
		uint8_t *p = &buf[DIBS_IMU_HR_HDR_LEN];

		put_header(buf, hr.na, DIBS_IMU_FLAG_HIGHRATE);
		sys_put_le32(hr.accel_index, &buf[12]);
		buf[16] = hr.ng;
		buf[17] = hr.nt;
		memcpy(p, hr.accel, hr.na * DIBS_IMU_HR_ACCEL_LEN);
		p += hr.na * DIBS_IMU_HR_ACCEL_LEN;
		memcpy(p, hr.gyro, hr.ng * DIBS_IMU_HR_GYRO_LEN);
		p += hr.ng * DIBS_IMU_HR_GYRO_LEN;
		memcpy(p, hr.ts, hr.nt * DIBS_IMU_HR_TS_LEN);
		ble_tx_submit(BLE_CHAN_IMU, buf, hr_len());
	} else {
		hdr.seq++; /* the phone counts it as lost */
		hdr.flags = 0;
	}
	stats.samples += hr.na;
	hr.na = hr.ng = hr.nt = 0;
	hr.accel_index = accel_count;
}

/* Makes room for one more record of `len` bytes. */
static void hr_reserve(size_t len)
{
	if (hr_len() + len > DIBS_IMU_HR_MAX_LEN) {
		hr_send();
	}
}

static void hr_row(uint8_t tag, uint8_t cnt, const uint8_t *d)
{
	/* Rows of one time slot share TAG_CNT and come together, in no
	 * documented order: a gyro or timestamp row belongs to the accel row
	 * just read if that has the same TAG_CNT, else to the next one. */
	bool same_slot = have_last_accel && cnt == last_accel_cnt;
	uint32_t target = same_slot ? accel_count - 1 : accel_count;
	/* Drop the rows of settling samples: ones whose accel row was dropped,
	 * or comes next and will be. */
	bool settling = same_slot ? last_accel_settling : settle_left > 0;
	uint8_t *r;

	if (tag == TAG_ACCEL) {
		last_accel_cnt = cnt;
		have_last_accel = true;
		last_accel_settling = settle_left > 0;
		if (settle_left) {
			settle_left--;
			return;
		}
	} else if ((tag == TAG_GYRO || tag == TAG_TIMESTAMP) && settling) {
		return;
	}

	switch (tag) {
	case TAG_ACCEL:
		hr_reserve(DIBS_IMU_HR_ACCEL_LEN);
		memcpy(hr.accel[hr.na++], d, 6);
		accel_count++;
		break;
	case TAG_GYRO:
		hr_reserve(DIBS_IMU_HR_GYRO_LEN);
		r = hr.gyro[hr.ng++];
		sys_put_le16((int16_t)(target - hr.accel_index), &r[0]);
		memcpy(&r[2], d, 6);
		break;
	case TAG_TIMESTAMP:
		hr_reserve(DIBS_IMU_HR_TS_LEN);
		r = hr.ts[hr.nt++];
		sys_put_le16((int16_t)(target - hr.accel_index), &r[0]);
		memcpy(&r[2], d, 4);
		break;
	default:
		stats.bad_tags++;
		break;
	}
}

static bool highrate(void)
{
	return cfg->highrate;
}

static void pkt_flush(void)
{
	if (highrate()) {
		hr_send();
	} else {
		std_send();
	}
}

static void rows_reset(void)
{
	memset(slots, 0, sizeof(slots));
	have_last_accel = false;
	last_accel_settling = false;
}

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
	return reg_write(REG_FIFO_CTRL4, cfg->ts_dec | mode);
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
	hdr.anchor_ts = sys_get_le32(ts);
	hdr.anchor_us = t0 + (t1 - t0) / 2;
	hdr.flags |= DIBS_IMU_FLAG_ANCHOR;
	stats.anchors++;
}

static void flush_fifo(void)
{
	set_fifo_mode(FIFO_MODE_BYPASS);
	set_fifo_mode(FIFO_MODE_CONTINUOUS);
	rows_reset();
}

static void drain_fifo(void)
{
	static uint8_t buf[BURST_ROWS * ROW_LEN];
	bool drained = false;

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
			pkt_flush();
			hdr.flags |= DIBS_IMU_FLAG_OVERRUN;
			flush_fifo();
			return;
		}

		uint16_t rows = st[0] | ((st[1] & 0x01) << 8);

		/* At 3840 Hz rows keep arriving while we read, so "until empty"
		 * would never end (no anchors, no watchdog feed). Drain what is
		 * there, and go round again only while the FIFO is still at the
		 * watermark: below it INT1 drops and the next crossing is a new
		 * edge. */
		if (rows == 0 || (drained && rows < cfg->watermark)) {
			return;
		}
		drained = true;
		task_wdt_feed(wdt_channel);

		while (rows && atomic_get(&enabled)) {
			uint16_t n = MIN(rows, cfg->burst);

			reg = REG_FIFO_DATA_OUT;
			if (i2c_write_read_dt(&bus, &reg, 1, buf, n * ROW_LEN)) {
				/* Rows may already be popped: start the slots over
				 * rather than pair rows from different samples. */
				stats.i2c_errors++;
				rows_reset();
				return;
			}
			rows -= n;

			for (uint16_t i = 0; i < n; i++) {
				const uint8_t *row = &buf[i * ROW_LEN];
				uint8_t tag = row[0] >> 3;
				uint8_t cnt = (row[0] >> 1) & 0x03;

				if (highrate()) {
					hr_row(tag, cnt, &row[1]);
				} else {
					std_row(tag, cnt, &row[1]);
				}
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
		/* Standard packets go out after every drain (low latency, as in
		 * v3); high-rate packets only when full. */
		if (!highrate()) {
			std_send();
		}
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

int imu_mode_get(uint8_t mode, struct imu_mode_info *info)
{
	if (mode >= ARRAY_SIZE(modes)) {
		return -EINVAL;
	}
	*info = modes[mode].info;
	return 0;
}

int imu_start(uint8_t mode)
{
	int err;

	if (mode >= ARRAY_SIZE(modes)) {
		return -EINVAL;
	}
	cfg = &modes[mode];
	memset(&stats, 0, sizeof(stats));
	memset(&hdr, 0, sizeof(hdr));
	memset(&std_pkt, 0, sizeof(std_pkt));
	memset(&hr, 0, sizeof(hr));
	accel_count = 0;
	settle_left = (uint32_t)cfg->info.accel_odr_hz * SETTLE_MS / 1000;
	rows_reset();

	/* Leave motion detection: it would change the ODR when still. */
	gpio_pin_interrupt_configure_dt(&int1, GPIO_INT_DISABLE);
	k_work_cancel_delayable(&motion_work);
	err = reg_write(REG_MD1_CFG, 0);
	err |= reg_write(REG_FUNCTIONS_ENABLE, 0);
	err |= reg_update(REG_CTRL6, 0x0F, FS_G_2000DPS);
	err |= reg_update(REG_CTRL8, FS_XL_MASK, FS_XL_8G);
	err |= reg_update(REG_FUNCTIONS_ENABLE, TIMESTAMP_EN, TIMESTAMP_EN);
	err |= reg_write(REG_FIFO_CTRL1, cfg->watermark);
	err |= reg_write(REG_FIFO_CTRL2, 0);
	err |= reg_write(REG_FIFO_CTRL3, cfg->bdr);
	err |= set_fifo_mode(FIFO_MODE_BYPASS);
	err |= set_fifo_mode(FIFO_MODE_CONTINUOUS);
	err |= reg_write(REG_INT1_CTRL, INT1_FIFO_TH);
	err |= reg_write(REG_CTRL1, cfg->odr_xl);
	err |= reg_write(REG_CTRL2, cfg->odr_g);
	if (err) {
		LOG_ERR("IMU configuration failed");
		return -EIO;
	}

	wdt_channel = task_wdt_add(WDT_TIMEOUT_MS, NULL, NULL);
	gpio_pin_interrupt_configure_dt(&int1, GPIO_INT_EDGE_TO_ACTIVE);
	atomic_set(&enabled, 1);
	k_sem_give(&irq_sem);
	LOG_INF("IMU streaming: accel %u Hz +-%u g, gyro %u Hz +-%u dps", cfg->info.accel_odr_hz,
		IMU_ACCEL_FS_G, cfg->info.gyro_odr_hz, IMU_GYRO_FS_DPS);
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

	/* Send what is left, then let the queue empty before the session
	 * reports idle (the phone stops listening then). */
	pkt_flush();
	ble_tx_wait_idle(1000);
	stats.dropped_packets = ble_tx_dropped(BLE_CHAN_IMU);

	LOG_INF("IMU stopped: %u accel samples, %u anchors (%u rejected), %u overruns, "
		"%u dropped, %u I2C errors, %u bad tags", stats.samples, stats.anchors,
		stats.anchors_rejected, stats.overruns, stats.dropped_packets, stats.i2c_errors,
		stats.bad_tags);
	if (out) {
		*out = stats;
	}
}

int8_t imu_freq_fine(void)
{
	return freq_fine;
}
