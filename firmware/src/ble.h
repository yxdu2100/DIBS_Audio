#ifndef DIBS_BLE_H_
#define DIBS_BLE_H_

#include <stddef.h>
#include <stdint.h>

#include <stdbool.h>

int ble_init(void);

/* Advertising runs only while allowed (power policy) and not connected. */
void ble_set_advertising(bool allowed);

/* Fast link for streaming, low-duty link with slave latency otherwise. */
void ble_set_link_fast(bool fast);

/* Largest audio notification the current connection can carry (0 if the
 * phone is not connected or not subscribed to audio). */
size_t ble_audio_max_len(void);

int ble_send_audio(const uint8_t *data, size_t len);

int ble_send_imu(const uint8_t *data, size_t len);

struct dibs_status;

/* Updates the status characteristic and notifies the phone. */
void ble_set_status(const struct dibs_status *s);

struct dibs_battery;

/* Updates the battery characteristic and notifies the phone. */
void ble_set_battery(const struct dibs_battery *b);

#endif /* DIBS_BLE_H_ */
