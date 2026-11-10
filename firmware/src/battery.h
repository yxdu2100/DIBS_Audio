#ifndef DIBS_BATTERY_H_
#define DIBS_BATTERY_H_

#include <stdbool.h>

/* While active, polls the fuel gauge and charger every 5 s and publishes
 * changes over BLE; otherwise the fuel gauge hibernates and the battery is
 * checked once a minute. Starts inactive. Guards the cell on battery: low
 * stops sessions, critical shuts the board down (see battery.c). */
void battery_init(void);
void battery_set_active(bool on);

/* On battery and below the low threshold: no new sessions. */
bool battery_is_low(void);

/* Charger shutdown mode for storage; deferred until USB is removed. */
void battery_request_shutdown(void);

#endif /* DIBS_BATTERY_H_ */
