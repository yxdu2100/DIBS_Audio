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
#include "session.h"

LOG_MODULE_REGISTER(battery, LOG_LEVEL_INF);

/* Connected and awake: report every 5 s. Otherwise keep guarding the cell
 * once a minute (the hibernating gauge measures every 45 s anyway). */
#define POLL_ACTIVE K_SECONDS(5)
#define POLL_GUARD  K_SECONDS(60)

/* Low-battery protection, on battery only (USB absent), each acting after
 * DEBOUNCE consecutive readings so a load dip does not trigger it:
 *  - below LOW_MV: stop the session and refuse new ones,
 *  - back above LOW_CLEAR_MV (or USB in): allow sessions again,
 *  - below CRITICAL_MV: shut the board down before the charger's 3.0 V
 *    BUVLO cut-off, so the cell is not drained further while idle. */
#define LOW_MV       3300
#define LOW_CLEAR_MV 3450
#define CRITICAL_MV  3150
#define DEBOUNCE     3

/* BQ25180: there is no push button on TS/MR (fixed 10 k to GND). With
 * EN_PUSH set, battery-only mode pulses the TS current source to look for
 * one (IQ_BAT 4-5 uA instead of 3-3.5 uA). EN_RST_SHIP = 01 enters
 * shutdown mode (15 nA, wake on adapter insert only); with an adapter
 * present the request waits until it is removed. */
#define BQ25180_REG_SHIP_RST 0x09
#define BQ25180_EN_PUSH      BIT(0)
#define BQ25180_EN_RST_SHIP  (BIT(6) | BIT(5))
#define BQ25180_SHUTDOWN     BIT(5)
#define SHIP_DELAY           K_MSEC(300) /* let the BLE reply go out first */

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
static atomic_t low;
static bool ship_pending;
static uint8_t below_low, below_critical;

static struct dibs_battery last;
static void poll(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(poll_work, poll);
static void shutdown(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(shutdown_work, shutdown);
static void ship_request(struct k_work *work);
static K_WORK_DEFINE(ship_work, ship_request);

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

static void shutdown(struct k_work *work)
{
	LOG_WRN("entering charger shutdown mode%s", ship_pending ? " when USB is removed" : "");
	if (i2c_reg_update_byte_dt(&charger_bus, BQ25180_REG_SHIP_RST, BQ25180_EN_RST_SHIP,
				   BQ25180_SHUTDOWN)) {
		LOG_ERR("shutdown request failed");
	}
}

static void protect(uint16_t mv, bool usb)
{
	if (usb || mv == 0) {
		below_low = 0;
		below_critical = 0;
		if (usb) {
			atomic_set(&low, 0);
		}
		return;
	}

	below_low = mv < LOW_MV ? MIN(below_low + 1, DEBOUNCE) : 0;
	below_critical = mv < CRITICAL_MV ? MIN(below_critical + 1, DEBOUNCE) : 0;

	if (below_low == DEBOUNCE && !atomic_get(&low)) {
		LOG_WRN("battery low (%u mV): stopping and refusing sessions", mv);
		atomic_set(&low, 1);
		session_stop(DIBS_END_LOW_BATTERY);
	} else if (mv >= LOW_CLEAR_MV) {
		atomic_set(&low, 0);
	}

	if (below_critical == DEBOUNCE) {
		LOG_WRN("battery critical (%u mV)", mv);
		session_stop(DIBS_END_LOW_BATTERY);
		k_work_reschedule(&shutdown_work, SHIP_DELAY);
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
	bool usb = b.charge >= DIBS_CHARGE_NOT_CHARGING;

	protect(b.voltage_mv, usb);
	b.flags = (usb ? DIBS_BATTERY_USB_PRESENT : 0) |
		  (atomic_get(&low) ? DIBS_BATTERY_LOW : 0) |
		  (ship_pending ? DIBS_BATTERY_SHIP_PENDING : 0);

	/* Only notify on a state change or a voltage step worth showing. */
	if (b.charge != last.charge || b.flags != last.flags || b.soc != last.soc ||
	    abs((int)b.voltage_mv - (int)last.voltage_mv) >= 10) {
		LOG_INF("battery %u mV, %u %%, charge %u, usb %u", b.voltage_mv, b.soc,
			b.charge, (b.flags & DIBS_BATTERY_USB_PRESENT) ? 1 : 0);
		last = b;
		ble_set_battery(&b);
	}

	k_work_reschedule(&poll_work, active ? POLL_ACTIVE : POLL_GUARD);
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
	k_work_reschedule(&poll_work, K_NO_WAIT);
}

bool battery_is_low(void)
{
	return atomic_get(&low);
}

/* Runs on the system workqueue, like the polling, so the I2C traffic stays
 * off the BLE thread that received the command. */
static void ship_request(struct k_work *work)
{
	union charger_propval online;

	session_stop(DIBS_END_STOP);
	ship_pending = charger_get_prop(chg, CHARGER_PROP_ONLINE, &online) == 0 &&
		       online.online != CHARGER_ONLINE_OFFLINE;
	/* Publish the pending flag before the board (maybe) loses power. */
	memset(&last, 0, sizeof(last));
	k_work_reschedule(&poll_work, K_NO_WAIT);
	k_work_reschedule(&shutdown_work, SHIP_DELAY);
}

void battery_request_shutdown(void)
{
	k_work_submit(&ship_work);
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
	}
	LOG_INF("fuel gauge %s", on ? "active" : "hibernating");
}
