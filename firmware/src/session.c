/*
 * Session: starts the session clock, IMU and microphone together, streams
 * until stopped, and publishes what the phone needs to put both streams on
 * one timeline (struct dibs_status).
 */
#include "session.h"

#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/random/random.h>
#include <zephyr/task_wdt/task_wdt.h>

#include "audio.h"
#include "battery.h"
#include "ble.h"
#include "imu.h"
#include "power.h"
#include "protocol.h"
#include "timebase.h"

LOG_MODULE_REGISTER(session, LOG_LEVEL_INF);

/* D1 runs from VBAT through 1 kOhm (~1.2 mA when lit), so while recording it
 * only blinks: 30 ms every 2 s, ~20 uA on average. */
#define LED_ON_MS  30
#define LED_OFF_MS 1970
/* The loop handles a 20 ms audio block; a stuck BLE send or PDM would
 * stop it feeding. */
#define WDT_TIMEOUT_MS 5000

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
static bool led_on;

static void led_blink(struct k_timer *t)
{
	bool on = led_on = !led_on;

	gpio_pin_set_dt(&led, on);
	k_timer_start(t, K_MSEC(on ? LED_ON_MS : LED_OFF_MS), K_NO_WAIT);
}

static K_TIMER_DEFINE(led_timer, led_blink, NULL);
static K_SEM_DEFINE(start_sem, 0, 1);
static atomic_t running;
static atomic_t end_reason;
static uint8_t next_mode;
static struct dibs_status status;

static void led_off(void)
{
	k_timer_stop(&led_timer);
	led_on = false;
	gpio_pin_set_dt(&led, 0);
}

static void set_mode(uint8_t mode)
{
	struct imu_mode_info info;

	if (imu_mode_get(mode, &info)) {
		mode = DIBS_IMU_MODE_STANDARD;
		imu_mode_get(mode, &info);
	}
	status.imu_mode = mode;
	status.imu_odr_hz = info.accel_odr_hz;
	status.gyro_odr_hz = info.gyro_odr_hz;
	status.imu_accel_per_ts = info.accel_per_ts;
}

static void run(void)
{
	struct audio_stats as = { 0 };
	struct imu_stats is = { 0 };
	bool t0_published = false;
	int wdt;
	int err;

	status.session_id = sys_rand32_get();
	status.end_reason = DIBS_END_NONE;
	status.audio_t0_us = 0;
	status.audio_dropped = 0;
	status.imu_dropped = 0;
	status.imu_overruns = 0;
	status.imu_samples = 0;
	status.imu_i2c_errors = 0;
	set_mode(next_mode);
	ble_tx_reset();
	bool with_audio = status.imu_mode != DIBS_IMU_MODE_HIGHRATE_IMU_ONLY;

	power_set_recording(true);
	ble_set_link(status.imu_mode == DIBS_IMU_MODE_STANDARD ? BLE_LINK_FAST : BLE_LINK_FASTEST);
	/* Phones take a few seconds to apply new connection parameters; in the
	 * high-rate modes the slower link would drop packets until then, so
	 * start the sensors once it is in place (or after 5 s regardless). */
	if (status.imu_mode != DIBS_IMU_MODE_STANDARD) {
		for (int i = 0; i < 100 && !ble_link_ready() && atomic_get(&running); i++) {
			k_msleep(50);
		}
		LOG_INF("link %s", ble_link_ready() ? "ready" : "not at the requested interval");
	}
	err = timebase_start();
	if (!err) {
		timebase_arm_pdm_capture();
		err = imu_start(status.imu_mode);
	}
	if (!err && with_audio) {
		err = audio_begin();
	}
	if (err) {
		LOG_ERR("session start failed: %d", err);
		imu_stop(NULL);
		timebase_stop();
		atomic_set(&running, 0);
		status.state = DIBS_STATE_IDLE;
		status.end_reason = DIBS_END_ERROR;
		ble_set_status(&status);
		ble_set_link(BLE_LINK_IDLE);
		power_set_recording(false);
		return;
	}

	status.state = DIBS_STATE_RECORDING;
	status.pdm_clk_hz = audio_pdm_clk_hz();
	status.audio_skip = audio_skip_samples();
	ble_set_status(&status);
	k_timer_start(&led_timer, K_NO_WAIT, K_NO_WAIT);
	LOG_INF("session %08x started", status.session_id);

	wdt = task_wdt_add(WDT_TIMEOUT_MS, NULL, NULL);
	while (atomic_get(&running)) {
		task_wdt_feed(wdt);
		if (!with_audio) {
			/* The IMU thread does the work; just watch for the stop. */
			k_msleep(50);
			continue;
		}
		err = audio_process_block();
		if (err) {
			LOG_WRN("PDM read: %d", err);
		}
		uint32_t t0;

		if (!t0_published && timebase_pdm_started_us(&t0)) {
			status.audio_t0_us = t0;
			t0_published = true;
			ble_set_status(&status);
		}
	}

	task_wdt_delete(wdt);
	if (with_audio) {
		audio_end(&as);
	}
	imu_stop(&is);
	led_off();

	status.state = DIBS_STATE_IDLE;
	status.end_reason = atomic_get(&end_reason);
	/* imu_stop() waited for the send queue: these counts are final. */
	status.audio_dropped = ble_tx_dropped(BLE_CHAN_AUDIO);
	status.imu_dropped = is.dropped_packets;
	status.imu_overruns = is.overruns;
	status.imu_samples = is.samples;
	status.imu_i2c_errors = is.i2c_errors;
	ble_set_status(&status);
	timebase_stop();
	ble_set_link(BLE_LINK_IDLE);
	power_set_recording(false);
	LOG_INF("session %08x ended (reason %u)", status.session_id, status.end_reason);
}

static void session_thread(void *p1, void *p2, void *p3)
{
	for (;;) {
		k_sem_take(&start_sem, K_FOREVER);
		run();
	}
}

K_THREAD_DEFINE(session_tid, 2048, session_thread, NULL, NULL, NULL, 5, 0, 0);

void session_init(uint32_t reset_reason)
{
	gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);

	status.version = DIBS_PROTOCOL_VERSION;
	status.fw_version = DIBS_FW_VERSION;
	status.board_id_lo = NRF_FICR->DEVICEID[0];
	status.board_id_hi = NRF_FICR->DEVICEID[1];
	status.reset_reason = reset_reason;
	status.imu_freq_fine = imu_freq_fine();
	set_mode(DIBS_IMU_MODE_STANDARD);
	status.accel_ug_lsb = IMU_ACCEL_UG_LSB;
	status.gyro_mdps_lsb = IMU_GYRO_MDPS_LSB;
	status.pdm_clk_hz = audio_pdm_clk_hz();
	status.audio_skip = audio_skip_samples();
	ble_set_status(&status);
}

void session_start(uint8_t imu_mode)
{
	if (battery_is_low()) {
		LOG_WRN("session refused: battery low");
		status.state = DIBS_STATE_IDLE;
		status.end_reason = DIBS_END_LOW_BATTERY;
		ble_set_status(&status);
		return;
	}
	if (atomic_cas(&running, 0, 1)) {
		next_mode = imu_mode;
		atomic_set(&end_reason, DIBS_END_NONE);
		k_sem_give(&start_sem);
	}
}

void session_stop(uint8_t reason)
{
	if (atomic_get(&running)) {
		atomic_set(&end_reason, reason);
		atomic_set(&running, 0);
	}
}
