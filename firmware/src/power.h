#ifndef DIBS_POWER_H_
#define DIBS_POWER_H_

#include <stdbool.h>

/*
 * Power policy, from three inputs:
 *  - advertise only while the board moves (or records); after ~68 s still
 *    with no phone connected it goes quiet until the IMU sees motion,
 *  - a connected phone keeps its link; idle links use slave latency,
 *  - the fuel gauge is polled only while a phone is connected and the board
 *    is not parked, and hibernates otherwise.
 */
void power_set_connected(bool connected);
void power_set_stationary(bool stationary);
void power_set_recording(bool recording);

#endif /* DIBS_POWER_H_ */
