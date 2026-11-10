#include "power.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "battery.h"
#include "ble.h"

LOG_MODULE_REGISTER(power, LOG_LEVEL_INF);

static atomic_t connected;
static atomic_t stationary;
static atomic_t recording;

static void apply(struct k_work *work)
{
	bool c = atomic_get(&connected);
	bool parked = atomic_get(&stationary) && !atomic_get(&recording);

	ble_set_advertising(!parked);
	battery_set_active(c && !parked);
	LOG_INF("connected %u, stationary %u, recording %u -> %s", c,
		(unsigned int)atomic_get(&stationary), (unsigned int)atomic_get(&recording),
		parked ? "parked" : "active");
}

static K_WORK_DEFINE(apply_work, apply);

static void set(atomic_t *flag, bool v)
{
	if (atomic_set(flag, v) != v) {
		k_work_submit(&apply_work);
	}
}

void power_set_connected(bool v)
{
	set(&connected, v);
}

void power_set_stationary(bool v)
{
	set(&stationary, v);
}

void power_set_recording(bool v)
{
	set(&recording, v);
}
