/*
 * DIBS firmware: a data-collection device. On the phone's request it records
 * the microphone and the IMU together and streams both over BLE with the
 * timing needed to align them (see protocol.h); it also reports
 * battery/charging state.
 */
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "audio.h"
#include "battery.h"
#include "ble.h"
#include "imu.h"
#include "protocol.h"
#include "session.h"
#include "timebase.h"
#include "watchdog.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

int main(void)
{
	uint32_t reset_reason = NRF_POWER->RESETREAS;
	int err;

	NRF_POWER->RESETREAS = reset_reason; /* write-1-to-clear */
	LOG_INF("DIBS fw %x, reset reason 0x%08x", DIBS_FW_VERSION, reset_reason);

	err = watchdog_init();
	if (!err) {
		err = timebase_init();
	}
	if (!err) {
		err = imu_init();
	}
	if (!err) {
		err = audio_init();
	}
	if (err) {
		LOG_ERR("init failed: %d", err);
		return 0;
	}

	session_init(reset_reason);
	err = ble_init();
	if (err) {
		return 0;
	}

	battery_init();
	LOG_INF("DIBS ready");
	return 0;
}
