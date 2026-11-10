/*
 * Microphone capture: 20 ms PDM blocks -> DC-blocking filter -> IMA ADPCM ->
 * BLE notifications, called from the session thread so a slow link only
 * stalls the mic queue, never the BLE stack.
 */
#include "audio.h"

#include <string.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>
#include <hal/nrf_gpio.h>
#include <hal/nrf_pdm.h>

#include "adpcm.h"
#include "ble.h"
#include "protocol.h"
#include "timebase.h"

LOG_MODULE_REGISTER(audio, LOG_LEVEL_INF);

#define REQ_RATE    16000
#define BLOCK_SAMP  320                            /* 20 ms */
#define BLOCK_BYTES (BLOCK_SAMP * sizeof(int16_t))
#define SETTLE_BLOCKS 5                            /* drop 100 ms of PDM start-up */
/* PDM_CLK (P0.16, see the board DTS); held low between sessions so the
 * microphone sleeps. */
#define MIC_CLK_PIN 16

K_MEM_SLAB_DEFINE_STATIC(mic_slab, BLOCK_BYTES, 8, 4);

static const struct device *const mic = DEVICE_DT_GET(DT_ALIAS(dmic0));

static struct adpcm_state adpcm;
static struct dc_block_state {
	bool primed;
	int32_t x1;
	int32_t y1_q8;
} dc;
static uint32_t blocks;
static struct audio_stats stats;

/* rate 0 releases the PDM peripheral (driver uninit). */
static int mic_configure(uint32_t rate)
{
	struct pcm_stream_cfg stream = {
		.pcm_rate = rate,
		.pcm_width = 16,
		.block_size = BLOCK_BYTES,
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

	return dmic_configure(mic, &cfg);
}

/* First-order DC blocker, y[n] = x[n] - x[n-1] + 0.996 y[n-1] (fc ~10 Hz).
 * y is kept in Q8 so the rounding of the feedback term doesn't add up to a
 * DC offset of its own. */
static void dc_block(struct dc_block_state *f, int16_t *s, size_t n)
{
	if (!f->primed) {
		f->x1 = s[0];
		f->primed = true;
	}
	for (size_t i = 0; i < n; i++) {
		f->y1_q8 = ((s[i] - f->x1) << 8) +
			   (int32_t)(((int64_t)f->y1_q8 * 4080 + 2048) >> 12);
		f->x1 = s[i];
		s[i] = CLAMP((f->y1_q8 + 128) >> 8, INT16_MIN, INT16_MAX);
	}
}

static void drain_mic(void)
{
	void *buf;
	size_t size;

	while (dmic_read(mic, 0, &buf, &size, 0) == 0) {
		k_mem_slab_free(&mic_slab, buf);
	}
}

/* 32 MHz * PDMCLKCTRL / 2^32 is the PDM clock; the decimation ratio is 64. */
uint32_t audio_pdm_clk_hz(void)
{
	return (uint32_t)((32000000ULL * NRF_PDM->PDMCLKCTRL) >> 32);
}

uint16_t audio_skip_samples(void)
{
	return SETTLE_BLOCKS * BLOCK_SAMP;
}

int audio_init(void)
{
	return device_is_ready(mic) ? 0 : -ENODEV;
}

/* The PDM peripheral is configured only for a session, so between sessions
 * it is disabled and the microphone's clock stays off. */
int audio_begin(void)
{
	int err = mic_configure(REQ_RATE);

	if (err) {
		return err;
	}
	memset(&adpcm, 0, sizeof(adpcm));
	memset(&dc, 0, sizeof(dc));
	memset(&stats, 0, sizeof(stats));
	blocks = 0;
	return dmic_trigger(mic, DMIC_TRIGGER_START);
}

int audio_process_block(void)
{
	static uint8_t pkt[247];
	void *buf;
	size_t size;
	int err = dmic_read(mic, 0, &buf, &size, 200);

	if (err) {
		return err;
	}
	/* The driver hands over a buffer on its PDM END event, so the latest
	 * captured END is this buffer's, unless we fell a whole block behind
	 * (the phone's fit rejects that as an outlier). */
	uint32_t end_us = timebase_pdm_end_us();

	int16_t *s = buf;
	size_t n = size / sizeof(int16_t);

	dc_block(&dc, s, n);
	if (blocks++ < SETTLE_BLOCKS || ble_audio_max_len() <= DIBS_AUDIO_HDR_LEN) {
		k_mem_slab_free(&mic_slab, buf);
		return 0;
	}

	/* Split the block into packets that fit the current MTU. */
	size_t max_samp = MIN((ble_audio_max_len() - DIBS_AUDIO_HDR_LEN) * 2,
			      (sizeof(pkt) - DIBS_AUDIO_HDR_LEN) * 2) & ~1U;

	for (size_t off = 0; off < n; off += max_samp) {
		size_t cnt = MIN(max_samp, n - off);

		sys_put_le16(stats.packets++, &pkt[0]);
		sys_put_le16((uint16_t)adpcm.predictor, &pkt[2]);
		pkt[4] = adpcm.index;
		sys_put_le32(off + cnt == n ? end_us : 0, &pkt[5]);
		adpcm_encode(&adpcm, &s[off], cnt, &pkt[DIBS_AUDIO_HDR_LEN]);

		if (ble_send_audio(pkt, DIBS_AUDIO_HDR_LEN + cnt / 2)) {
			stats.dropped++;
		}
	}
	k_mem_slab_free(&mic_slab, buf);
	return 0;
}

void audio_end(struct audio_stats *out)
{
	dmic_trigger(mic, DMIC_TRIGGER_STOP);
	k_msleep(30);
	drain_mic();
	mic_configure(0);
	nrf_gpio_pin_clear(MIC_CLK_PIN);
	nrf_gpio_cfg_output(MIC_CLK_PIN);
	LOG_INF("audio stopped: %u packets, %u dropped", stats.packets, stats.dropped);
	if (out) {
		*out = stats;
	}
}
