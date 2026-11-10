#ifndef DIBS_AUDIO_H_
#define DIBS_AUDIO_H_

#include <stdint.h>

struct audio_stats {
	uint16_t packets;
	uint16_t dropped; /* notifications the board could not send */
};

/* Microphone capture driven by the session thread. */
int audio_init(void);
int audio_begin(void);
/* Waits for the next 20 ms block, encodes and sends it. */
int audio_process_block(void);
void audio_end(struct audio_stats *stats);

uint32_t audio_pdm_clk_hz(void);
uint16_t audio_skip_samples(void);

#endif /* DIBS_AUDIO_H_ */
