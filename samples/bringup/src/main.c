/*
 * DIBS bring-up: blinks the LED and once a second prints the IMU, battery,
 * charger and microphone readings over RTT.
 */
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/drivers/fuel_gauge.h>
#include <zephyr/drivers/charger.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/logging/log.h>
#include <math.h>

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

#define MIC_RATE        16000
#define MIC_BLOCK_SAMP  (MIC_RATE / 50)                 /* 20 ms */
#define MIC_BLOCK_BYTES (MIC_BLOCK_SAMP * sizeof(int16_t))

K_MEM_SLAB_DEFINE_STATIC(mic_slab, MIC_BLOCK_BYTES, 4, 4);

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
static const struct device *const imu = DEVICE_DT_GET(DT_ALIAS(accel0));
static const struct device *const gauge = DEVICE_DT_GET(DT_ALIAS(fuel_gauge0));
static const struct device *const chg = DEVICE_DT_GET(DT_ALIAS(charger0));
static const struct device *const mic = DEVICE_DT_GET(DT_ALIAS(dmic0));

static int mic_start(void)
{
	struct pcm_stream_cfg stream = {
		.pcm_rate = MIC_RATE,
		.pcm_width = 16,
		.block_size = MIC_BLOCK_BYTES,
		.mem_slab = &mic_slab,
	};
	struct dmic_cfg cfg = {
		.io = {
			.min_pdm_clk_freq = 1000000,
			.max_pdm_clk_freq = 3250000,
			.min_pdm_clk_dc = 40,
			.max_pdm_clk_dc = 60,
		},
		.streams = &stream,
		.channel = {
			.req_num_streams = 1,
			.req_num_chan = 1,
			/* ICS-41350 SELECT = GND: left channel. */
			.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT),
		},
	};
	int err = dmic_configure(mic, &cfg);

	return err ? err : dmic_trigger(mic, DMIC_TRIGGER_START);
}

/* RMS of one 20 ms block with its DC removed. */
static int mic_level(void)
{
	void *buf;
	uint32_t size;
	int64_t sum = 0;
	uint64_t sq = 0;
	int err = dmic_read(mic, 0, &buf, &size, 100);

	if (err) {
		return err;
	}

	const int16_t *s = buf;
	uint32_t n = size / sizeof(int16_t);

	for (uint32_t i = 0; i < n; i++) {
		sum += s[i];
		sq += (int32_t)s[i] * s[i];
	}
	k_mem_slab_free(&mic_slab, buf);

	int64_t mean = sum / n;

	return (int)sqrtf((float)(sq / n - mean * mean));
}

static void print_imu(void)
{
	struct sensor_value a[3], g[3];

	if (sensor_sample_fetch(imu) ||
	    sensor_channel_get(imu, SENSOR_CHAN_ACCEL_XYZ, a)) {
		LOG_WRN("IMU read failed");
		return;
	}
	LOG_INF("IMU accel %.2f %.2f %.2f m/s^2",
		sensor_value_to_double(&a[0]), sensor_value_to_double(&a[1]),
		sensor_value_to_double(&a[2]));
	if (sensor_channel_get(imu, SENSOR_CHAN_GYRO_XYZ, g) == 0) {
		LOG_INF("IMU gyro  %.2f %.2f %.2f rad/s",
			sensor_value_to_double(&g[0]), sensor_value_to_double(&g[1]),
			sensor_value_to_double(&g[2]));
	}
}

static void print_battery(void)
{
	union fuel_gauge_prop_val v, soc;
	union charger_propval online, status;

	if (fuel_gauge_get_prop(gauge, FUEL_GAUGE_VOLTAGE, &v) ||
	    fuel_gauge_get_prop(gauge, FUEL_GAUGE_RELATIVE_STATE_OF_CHARGE, &soc)) {
		LOG_WRN("fuel gauge read failed");
	} else {
		LOG_INF("battery %d mV, %u %%", v.voltage / 1000,
			soc.relative_state_of_charge);
	}

	if (charger_get_prop(chg, CHARGER_PROP_ONLINE, &online) ||
	    charger_get_prop(chg, CHARGER_PROP_STATUS, &status)) {
		LOG_WRN("charger read failed");
		return;
	}

	static const char *const st[] = {
		[CHARGER_STATUS_UNKNOWN] = "unknown",
		[CHARGER_STATUS_CHARGING] = "charging",
		[CHARGER_STATUS_DISCHARGING] = "discharging",
		[CHARGER_STATUS_NOT_CHARGING] = "not charging",
		[CHARGER_STATUS_FULL] = "full",
	};

	LOG_INF("charger: USB %s, %s",
		online.online == CHARGER_ONLINE_OFFLINE ? "unplugged" : "present",
		status.status < ARRAY_SIZE(st) ? st[status.status] : "?");
}

int main(void)
{
	const struct device *const devs[] = { led.port, imu, gauge, chg, mic };
	bool mic_ok;

	LOG_INF("DIBS bring-up on %s", CONFIG_BOARD_TARGET);
	for (size_t i = 0; i < ARRAY_SIZE(devs); i++) {
		LOG_INF("%-12s %s", devs[i]->name,
			device_is_ready(devs[i]) ? "ready" : "NOT READY");
	}

	gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
	mic_ok = device_is_ready(mic) && mic_start() == 0;

	for (int i = 0;; i++) {
		gpio_pin_toggle_dt(&led);

		/* Drain the mic continuously; report the loudest block per second. */
		int peak = 0;
		int64_t until = k_uptime_get() + 1000;

		while (k_uptime_get() < until) {
			if (mic_ok) {
				peak = MAX(peak, mic_level());
			} else {
				k_msleep(100);
			}
		}

		LOG_INF("--- %d s", i + 1);
		if (device_is_ready(imu)) {
			print_imu();
		}
		if (device_is_ready(gauge) && device_is_ready(chg)) {
			print_battery();
		}
		if (mic_ok) {
			LOG_INF("mic peak rms %d", peak);
		}
	}
	return 0;
}
