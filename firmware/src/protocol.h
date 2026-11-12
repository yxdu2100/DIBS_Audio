/*
 * DIBS BLE protocol v4, shared with app/DIBS_AUDIO/DIBS_AUDIO/DIBSProtocol.swift.
 *
 * Service   D1B50001-6E2B-4C1F-9A7D-3E8B5F0C2A41
 *   Control D1B50002-...  write:  0x01 [mode] start session, 0x00 stop,
 *                                 0x02 shut down for storage (DIBS_CMD_SHIP)
 *                                 mode: DIBS_IMU_MODE_*, 0 if omitted
 *   Audio   D1B50003-...  notify: audio packets (below)
 *   Status  D1B50004-...  read/notify: struct dibs_status
 *   Battery D1B50005-...  read/notify: struct dibs_battery, every 5 s on change
 *   IMU     D1B50006-...  notify: IMU packets (below)
 *
 * A session records audio and IMU together. Times are on the session clock:
 * microseconds of a timer clocked by the same 32 MHz crystal as the
 * microphone, starting near 0 at session start and wrapping at 2^32.
 *
 * Audio packet: IMA ADPCM, mono, 4 bits per sample, low nibble first.
 *   u16 seq        packet counter, restarts at 0 on every start
 *   i16 predictor  decoder state before the first sample of this packet
 *   u8  index      step index before the first sample of this packet
 *   u32 end_us     session time the PDM finished the buffer holding this
 *                  packet's last sample (0 if that sample is not a buffer end)
 *   u8  data[]     2 samples per byte
 * Every packet carries its own decoder state, so a lost packet only loses
 * its own samples. Counting lost packets and the audio_skip samples
 * discarded before seq 0, the phone fits session_us = a + b * sample_index
 * over all end_us values; audio_t0_us (first PDM start) is a cross-check.
 *
 * IMU packet:
 *   u16 seq        packet counter, restarts at 0 on every start
 *   u8  n          samples in this packet (1..DIBS_IMU_MAX_SAMPLES)
 *   u8  flags      DIBS_IMU_FLAG_*
 *   u32 anchor_ts  IMU timestamp counter read ...
 *   u32 anchor_us  ... at this session-clock time (valid if FLAG_ANCHOR)
 *   n x { u32 ts, i16 ax, ay, az, gx, gy, gz }
 *                  ts: the sample's IMU timestamp (LSM6DSV ticks, ~21.75 us);
 *                  axes raw, scaled by the status fields
 * The phone fits session_us = a + b * imu_ticks over all anchors.
 *
 * Modes (byte 2 of the start command, reported in dibs_status.imu_mode):
 *   DIBS_IMU_MODE_STANDARD  accel + gyro 120 Hz, packets above
 *   DIBS_IMU_MODE_HIGHRATE  accel 3840 Hz + gyro 240 Hz, packets below
 *   DIBS_IMU_MODE_HIGHRATE_IMU_ONLY  as HIGHRATE, microphone off (no audio
 *                           packets; audio_t0_us stays 0)
 * Audio runs in the first two.
 *
 * Optional byte 3 of the start command: the radio PHY for the session,
 * DIBS_PHY_1M or DIBS_PHY_2M (default, also when absent). 1M reaches ~3 dB
 * further at half the raw bit rate. dibs_status.phy reports the PHY in use.
 *
 * High-rate IMU packet (flags has DIBS_IMU_FLAG_HIGHRATE):
 *   u16 seq, u8 n_accel, u8 flags, u32 anchor_ts, u32 anchor_us  as above
 *   u32 accel_index  index of this packet's first accel sample, counted from
 *                    0 at session start over every sample the FIFO delivered
 *                    (samples lost in a FIFO overrun are not counted)
 *   u8  n_gyro
 *   u8  n_ts
 *   n_accel x { i16 ax, ay, az }                     consecutive samples
 *   n_gyro  x { i16 rel, i16 gx, gy, gz }
 *   n_ts    x { i16 rel, u32 ts }
 *                    rel: accel_index + rel is the accel sample of the same
 *                    FIFO time slot (may be -1 or past this packet's last)
 * The FIFO stores one IMU timestamp every dibs_status.imu_accel_per_ts accel
 * samples; the phone interpolates the accel sample times between them.
 *
 * All integers are little-endian.
 */
#ifndef DIBS_PROTOCOL_H_
#define DIBS_PROTOCOL_H_

#include <stdint.h>
#include <zephyr/sys/util.h>

#define DIBS_PROTOCOL_VERSION 4
#define DIBS_FW_VERSION       0x0401 /* major.minor */

#define DIBS_UUID(n) \
	BT_UUID_128_ENCODE(0xD1B50000 + (n), 0x6E2B, 0x4C1F, 0x9A7D, 0x3E8B5F0C2A41)

#define DIBS_UUID_SERVICE DIBS_UUID(1)
#define DIBS_UUID_CONTROL DIBS_UUID(2)
#define DIBS_UUID_AUDIO   DIBS_UUID(3)
#define DIBS_UUID_STATUS  DIBS_UUID(4)
#define DIBS_UUID_BATTERY DIBS_UUID(5)
#define DIBS_UUID_IMU     DIBS_UUID(6)

#define DIBS_PHY_1M 1
#define DIBS_PHY_2M 2

#define DIBS_CMD_STOP  0x00
#define DIBS_CMD_START 0x01
/* Charger shutdown mode (15 nA from the cell); only plugging in USB wakes
 * the board. With USB present it takes effect when USB is removed. */
#define DIBS_CMD_SHIP  0x02

#define DIBS_AUDIO_HDR_LEN 9

#define DIBS_IMU_HDR_LEN      12
#define DIBS_IMU_SAMPLE_LEN   16
#define DIBS_IMU_MAX_SAMPLES  14
#define DIBS_IMU_FLAG_ANCHOR  BIT(0) /* anchor_ts/anchor_us are fresh */
#define DIBS_IMU_FLAG_OVERRUN BIT(1) /* IMU FIFO overflowed before this packet */
#define DIBS_IMU_FLAG_HIGHRATE BIT(7) /* high-rate packet layout */

#define DIBS_IMU_MODE_STANDARD 0
#define DIBS_IMU_MODE_HIGHRATE 1
#define DIBS_IMU_MODE_HIGHRATE_IMU_ONLY 2

#define DIBS_IMU_HR_HDR_LEN   18
#define DIBS_IMU_HR_ACCEL_LEN 6
#define DIBS_IMU_HR_GYRO_LEN  8
#define DIBS_IMU_HR_TS_LEN    6
/* Largest notification: ATT MTU 247 - 3. */
#define DIBS_IMU_HR_MAX_LEN   244

enum dibs_state {
	DIBS_STATE_IDLE = 0,
	DIBS_STATE_RECORDING = 1,
};

enum dibs_end_reason {
	DIBS_END_NONE = 0,       /* still running */
	DIBS_END_STOP = 1,       /* stop command */
	DIBS_END_DISCONNECT = 2, /* phone disconnected */
	DIBS_END_ERROR = 3,
	DIBS_END_LOW_BATTERY = 4, /* stopped, or a start refused, on low battery */
};

struct dibs_status {
	uint8_t version;         /* DIBS_PROTOCOL_VERSION */
	uint8_t state;           /* enum dibs_state */
	uint16_t fw_version;
	uint32_t board_id_lo;    /* FICR DEVICEID */
	uint32_t board_id_hi;
	uint32_t reset_reason;   /* RESETREAS at boot */
	uint32_t session_id;
	uint8_t end_reason;      /* enum dibs_end_reason */
	int8_t imu_freq_fine;    /* LSM6DSV INTERNAL_FREQ_FINE */
	uint16_t audio_skip;     /* samples discarded before audio seq 0 */
	uint32_t pdm_clk_hz;     /* audio sample rate = pdm_clk_hz / 64 */
	uint32_t audio_t0_us;    /* session clock when the PDM started; 0 = unknown */
	uint16_t audio_dropped;  /* audio packets the board could not send */
	uint16_t imu_odr_hz;     /* accelerometer ODR (nominal) */
	uint16_t accel_ug_lsb;
	uint16_t gyro_mdps_lsb;
	uint16_t imu_dropped;    /* IMU packets the board could not send */
	uint16_t imu_overruns;   /* IMU FIFO overflows */
	uint32_t imu_samples;
	uint16_t imu_i2c_errors; /* failed IMU reads (FIFO rows may be lost) */
	uint8_t imu_mode;        /* DIBS_IMU_MODE_* of the current/last session */
	uint8_t phy;             /* DIBS_PHY_* in use (TX), 0 = unknown */
	uint16_t gyro_odr_hz;    /* gyroscope ODR (nominal) */
	uint16_t imu_accel_per_ts; /* accel samples per FIFO timestamp */
} __packed;

enum dibs_charge {
	DIBS_CHARGE_UNKNOWN = 0,
	DIBS_CHARGE_DISCHARGING = 1,  /* no USB power */
	DIBS_CHARGE_NOT_CHARGING = 2, /* USB present, charger idle */
	DIBS_CHARGE_CHARGING = 3,
	DIBS_CHARGE_FULL = 4,
};

#define DIBS_BATTERY_USB_PRESENT BIT(0)
/* On battery below ~3.3 V: sessions are stopped and refused until charged. */
#define DIBS_BATTERY_LOW         BIT(1)
/* Shutdown requested while on USB: the board turns off when USB is removed. */
#define DIBS_BATTERY_SHIP_PENDING BIT(2)

struct dibs_battery {
	uint8_t version;     /* 1 */
	uint8_t flags;       /* DIBS_BATTERY_* */
	uint8_t charge;      /* enum dibs_charge */
	uint8_t soc;         /* % from the fuel gauge, may exceed 100 */
	uint16_t voltage_mv; /* BAT pin voltage */
} __packed;

#endif /* DIBS_PROTOCOL_H_ */
