#ifndef DIBS_SESSION_H_
#define DIBS_SESSION_H_

#include <stdint.h>

/* A session records audio and IMU together until stopped (see protocol.h). */
void session_init(uint32_t reset_reason);
/* imu_mode: DIBS_IMU_MODE_* (unknown modes fall back to standard). */
void session_start(uint8_t imu_mode);
void session_stop(uint8_t end_reason);

#endif /* DIBS_SESSION_H_ */
