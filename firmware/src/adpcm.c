#include "adpcm.h"

static const int16_t step_table[89] = {
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37,
	41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173,
	190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
	724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
	2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
	6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289,
	16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};

static const int8_t index_table[16] = {
	-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8,
};

static uint8_t encode_sample(struct adpcm_state *st, int16_t sample)
{
	int step = step_table[st->index];
	int diff = sample - st->predictor;
	int vpdiff = step >> 3;
	uint8_t nibble = 0;

	if (diff < 0) {
		nibble = 8;
		diff = -diff;
	}
	if (diff >= step) {
		nibble |= 4;
		diff -= step;
		vpdiff += step;
	}
	step >>= 1;
	if (diff >= step) {
		nibble |= 2;
		diff -= step;
		vpdiff += step;
	}
	step >>= 1;
	if (diff >= step) {
		nibble |= 1;
		vpdiff += step;
	}

	int pred = st->predictor + ((nibble & 8) ? -vpdiff : vpdiff);

	st->predictor = pred > INT16_MAX ? INT16_MAX : pred < INT16_MIN ? INT16_MIN : pred;

	int index = st->index + index_table[nibble];

	st->index = index < 0 ? 0 : index > 88 ? 88 : index;
	return nibble;
}

void adpcm_encode(struct adpcm_state *st, const int16_t *in, size_t n, uint8_t *out)
{
	for (size_t i = 0; i < n; i += 2) {
		uint8_t lo = encode_sample(st, in[i]);
		uint8_t hi = encode_sample(st, in[i + 1]);

		*out++ = lo | (hi << 4);
	}
}
