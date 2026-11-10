#ifndef DIBS_IMU_H_
#define DIBS_IMU_H_

#include <stdint.h>

struct imu_stats {
	uint32_t samples;
	uint16_t dropped_packets; /* notifications the board could not send */
	uint16_t overruns;        /* FIFO overflows (samples lost on the IMU) */
	uint16_t anchors;
	uint16_t anchors_rejected;
	uint16_t i2c_errors;
};

/* LSM6DSV32X, accelerometer + gyroscope at 120 Hz with FIFO timestamps. */
int imu_init(void);
int imu_start(void);
void imu_stop(struct imu_stats *stats);
int8_t imu_freq_fine(void);

#define IMU_ODR_HZ        120
#define IMU_ACCEL_FS_G    8
#define IMU_GYRO_FS_DPS   2000
#define IMU_ACCEL_UG_LSB  244   /* LSM6DSV32X at +-8 g */
#define IMU_GYRO_MDPS_LSB 70    /* +-2000 dps */

#endif /* DIBS_IMU_H_ */
