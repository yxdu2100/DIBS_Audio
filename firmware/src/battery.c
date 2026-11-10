#include "battery.h"

#include <stdlib.h>
#include <string.h>
#include <zephyr/drivers/charger.h>
#include <zephyr/drivers/fuel_gauge.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "ble.h"
#include "protocol.h"

LOG_MODULE_REGISTER(battery, LOG_LEVEL_INF);

#define POLL_INTERVAL K_SECONDS(5)

/* BQ25180: there is no push button on TS/MR (fixed 10 k to GND). With
 * EN_PUSH set, battery-only mode pulses the TS current source to look for
 * one (IQ_BAT 4-5 uA instead of 3-3.5 uA). */
#define BQ25180_REG_SHIP_RST 0x09
#define BQ25180_EN_PUSH      BIT(0)

/* MAX17048 HIBRT: 0xFFFF forces hibernate (ADC every 45 s, ~3 uA),
 * 0x0000 keeps it active (every 250 ms, ~23 uA). */
#define MAX17048_REG_HIBRT  0x0A
#define HIBRT_ALWAYS_HIBERNATE 0xFFFF
#define HIBRT_NEVER_HIBERNATE  0x0000

static const struct device *const gauge = DEVICE_DT_GET(DT_ALIAS(fuel_gauge0));
static const struct device *const chg = DEVICE_DT_GET(DT_ALIAS(charger0));
static const struct i2c_dt_spec gauge_bus = I2C_DT_SPEC_GET(DT_ALIAS(fuel_gauge0));
static const struct i2c_dt_spec charger_bus = I2C_DT_SPEC_GET(DT_ALIAS(charger0));
static bool active;

static struct dibs_battery last;
static void poll(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(poll_work, poll);

static uint8_t charge_state(void)
{
	union charger_propval online, status;

	if (charger_get_prop(chg, CHARGER_PROP_ONLINE, &online) ||
	    charger_get_prop(chg, CHARGER_PROP_STATUS, &status)) {
		return DIBS_CHARGE_UNKNOWN;
	}
	if (online.online == CHARGER_ONLINE_OFFLINE) {
		return DIBS_CHARGE_DISCHARGING;
	}

	switch (status.status) {
	case CHARGER_STATUS_CHARGING:
		return DIBS_CHARGE_CHARGING;
	case CHARGER_STATUS_FULL:
		return DIBS_CHARGE_FULL;
	case CHARGER_STATUS_NOT_CHARGING:
		return DIBS_CHARGE_NOT_CHARGING;
	default:
		return DIBS_CHARGE_UNKNOWN;
	}
}

static void poll(struct k_work *work)
{
	struct dibs_battery b = { .version = 1 };
	union fuel_gauge_prop_val v, soc;

	if (fuel_gauge_get_prop(gauge, FUEL_GAUGE_VOLTAGE, &v) == 0) {
		b.voltage_mv = v.voltage / 1000;
	}
	if (fuel_gauge_get_prop(gauge, FUEL_GAUGE_RELATIVE_STATE_OF_CHARGE, &soc) == 0) {
		b.soc = soc.relative_state_of_charge;
	}
	b.charge = charge_state();
	b.flags = (b.charge >= DIBS_CHARGE_NOT_CHARGING) ? DIBS_BATTERY_USB_PRESENT : 0;

	/* Only notify on a state change or a voltage step worth showing. */
	if (b.charge != last.charge || b.flags != last.flags || b.soc != last.soc ||
	    abs((int)b.voltage_mv - (int)last.voltage_mv) >= 10) {
		LOG_INF("battery %u mV, %u %%, charge %u, usb %u", b.voltage_mv, b.soc,
			b.charge, (b.flags & DIBS_BATTERY_USB_PRESENT) ? 1 : 0);
		last = b;
		ble_set_battery(&b);
	}

	if (active) {
		k_work_reschedule(&poll_work, POLL_INTERVAL);
	}
}

static void set_hibernate(bool hibernate)
{
	uint16_t v = hibernate ? HIBRT_ALWAYS_HIBERNATE : HIBRT_NEVER_HIBERNATE;
	uint8_t buf[3] = { MAX17048_REG_HIBRT, v >> 8, v & 0xFF };

	if (i2c_write_dt(&gauge_bus, buf, sizeof(buf))) {
		LOG_WRN("fuel gauge hibernate %u failed", hibernate);
	}
}

void battery_init(void)
{
	if (!device_is_ready(gauge) || !device_is_ready(chg)) {
		LOG_ERR("fuel gauge or charger not ready");
		return;
	}
	if (i2c_reg_update_byte_dt(&charger_bus, BQ25180_REG_SHIP_RST, BQ25180_EN_PUSH, 0)) {
		LOG_WRN("could not disable the charger push button");
	}
	set_hibernate(true);
}

void battery_set_active(bool on)
{
	if (on == active) {
		return;
	}
	active = on;
	set_hibernate(!on);
	if (on) {
		/* Report right away so the phone sees fresh values. */
		memset(&last, 0, sizeof(last));
		k_work_reschedule(&poll_work, K_NO_WAIT);
	} else {
		k_work_cancel_delayable(&poll_work);
	}
	LOG_INF("fuel gauge %s", on ? "active" : "hibernating");
}
