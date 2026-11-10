#ifndef DIBS_BATTERY_H_
#define DIBS_BATTERY_H_

#include <stdbool.h>

/* While active, polls the fuel gauge and charger every 5 s and publishes
 * changes over BLE; otherwise the fuel gauge hibernates. Starts inactive. */
void battery_init(void);
void battery_set_active(bool on);

#endif /* DIBS_BATTERY_H_ */
