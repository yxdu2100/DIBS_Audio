#ifndef DIBS_ADPCM_H_
#define DIBS_ADPCM_H_

#include <stddef.h>
#include <stdint.h>

struct adpcm_state {
	int16_t predictor;
	uint8_t index;
};

/* IMA ADPCM: encodes n samples (n even) into n / 2 bytes, low nibble first. */
void adpcm_encode(struct adpcm_state *st, const int16_t *in, size_t n, uint8_t *out);

#endif /* DIBS_ADPCM_H_ */
