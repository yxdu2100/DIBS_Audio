#ifndef DIBS_BLE_H_
#define DIBS_BLE_H_

#include <stddef.h>
#include <stdint.h>

#include <stdbool.h>

int ble_init(void);

/* Advertising runs only while allowed (power policy) and not connected. */
void ble_set_advertising(bool allowed);

/* Low-duty link with slave latency between sessions, fast links for
 * streaming (fastest for high-rate IMU). */
enum ble_link {
	BLE_LINK_IDLE,
	BLE_LINK_FAST,
	BLE_LINK_FASTEST,
};
void ble_set_link(enum ble_link link);
/* The central has applied an interval within the requested link's range. */
bool ble_link_ready(void);

/* Largest audio notification the current connection can carry (0 if the
 * phone is not connected or not subscribed to audio). */
size_t ble_audio_max_len(void);

/* Streaming notifications go through one queue to a sender thread, so the
 * microphone and IMU threads never wait for the link. */
enum ble_chan {
	BLE_CHAN_AUDIO,
	BLE_CHAN_IMU,
	BLE_CHAN_COUNT,
};

#define BLE_TX_MAX_LEN 244 /* ATT MTU 247 - 3 */

/* A buffer of BLE_TX_MAX_LEN bytes for one notification, or NULL when the
 * link has fallen too far behind (the packet then counts as dropped). */
uint8_t *ble_tx_alloc(enum ble_chan chan);
/* Queues a buffer from ble_tx_alloc(); it is freed once sent. */
void ble_tx_submit(enum ble_chan chan, uint8_t *buf, size_t len);
/* Packets of a channel not sent since ble_tx_reset() (no buffer, or the
 * notification failed). */
uint16_t ble_tx_dropped(enum ble_chan chan);
void ble_tx_reset(void);
/* Waits up to timeout_ms for the queue to empty. */
void ble_tx_wait_idle(int timeout_ms);

struct dibs_status;

/* Updates the status characteristic and notifies the phone. */
void ble_set_status(const struct dibs_status *s);

struct dibs_battery;

/* Updates the battery characteristic and notifies the phone. */
void ble_set_battery(const struct dibs_battery *b);

#endif /* DIBS_BLE_H_ */
