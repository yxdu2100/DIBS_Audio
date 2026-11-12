#ifndef DIBS_IMU_H_
#define DIBS_IMU_H_

#include <stdint.h>

struct imu_stats {
	uint32_t samples;         /* accelerometer samples sent */
	uint16_t dropped_packets; /* notifications the board could not send */
	uint16_t overruns;        /* FIFO overflows (samples lost on the IMU) */
	uint16_t anchors;
	uint16_t anchors_rejected;
	uint16_t i2c_errors;
	uint16_t bad_tags;        /* FIFO rows with an unexpected tag */
};

/* Rates of one IMU mode (DIBS_IMU_MODE_*), nominal. */
struct imu_mode_info {
	uint16_t accel_odr_hz;
	uint16_t gyro_odr_hz;
	uint16_t accel_per_ts; /* accel samples per FIFO timestamp */
};

/* LSM6DSV32X: accelerometer + gyroscope through the FIFO with timestamps. */
int imu_init(void);
/* 0 or -EINVAL for an unknown mode. */
int imu_mode_get(uint8_t mode, struct imu_mode_info *info);
int imu_start(uint8_t mode);
/* Stops the FIFO and waits (bounded) until queued packets went out. */
void imu_stop(struct imu_stats *stats);
int8_t imu_freq_fine(void);

#define IMU_ACCEL_FS_G    8
#define IMU_GYRO_FS_DPS   2000
#define IMU_ACCEL_UG_LSB  244   /* LSM6DSV32X at +-8 g */
#define IMU_GYRO_MDPS_LSB 70    /* +-2000 dps */

#endif /* DIBS_IMU_H_ */
