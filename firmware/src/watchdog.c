#include "watchdog.h"

#include <hal/nrf_wdt.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/task_wdt/task_wdt.h>

LOG_MODULE_REGISTER(watchdog, LOG_LEVEL_INF);

#define WORKQ_TIMEOUT_MS 10000
#define WORKQ_FEED       K_SECONDS(2)
/* An inherited WDT keeps the previous boot's reload value, as short as
 * CONFIG_TASK_WDT_MIN_TIMEOUT + the fallback delay (~1 s). */
#define INHERITED_FEED   K_MSEC(250)

static int workq_channel;
/* The nRF52 WDT survives soft resets (flashing, reboot after a fatal error)
 * and cannot be reconfigured until a watchdog or power-on reset. If it is
 * already running at boot, keep it fed with its old settings and run the
 * task watchdog in software. */
static bool hw_inherited;

static void feed(struct k_work *work)
{
	task_wdt_feed(workq_channel);
	k_work_reschedule(k_work_delayable_from_work(work), WORKQ_FEED);
}

static K_WORK_DELAYABLE_DEFINE(feed_work, feed);

/* Software task watchdog channels still guard every thread; this only keeps
 * the inherited hardware WDT from firing while the system runs. */
static void feed_inherited(struct k_timer *timer)
{
	for (int i = 0; i < NRF_WDT_CHANNEL_NUMBER; i++) {
		if (nrf_wdt_reload_request_enable_check(NRF_WDT, i)) {
			nrf_wdt_reload_request_set(NRF_WDT, i);
		}
	}
}

static K_TIMER_DEFINE(inherited_timer, feed_inherited, NULL);

int watchdog_init(void)
{
	int err;

	hw_inherited = nrf_wdt_started_check(NRF_WDT);
	if (hw_inherited) {
		LOG_WRN("WDT still running from before the reset; feeding it as is");
		feed_inherited(NULL);
		k_timer_start(&inherited_timer, INHERITED_FEED, INHERITED_FEED);
		err = task_wdt_init(NULL);
	} else {
		err = task_wdt_init(DEVICE_DT_GET(DT_ALIAS(watchdog0)));
	}
	if (err) {
		LOG_ERR("task_wdt_init: %d", err);
		return err;
	}

	workq_channel = task_wdt_add(WORKQ_TIMEOUT_MS, NULL, NULL);
	if (workq_channel < 0) {
		return workq_channel;
	}
	k_work_reschedule(&feed_work, K_NO_WAIT);
	return 0;
}
