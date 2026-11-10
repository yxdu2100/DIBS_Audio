# DIBS

Firmware, board definition and (later) companion app for the DIBS board
(KiCad project `dibs_nrf52_v21`).

```
DIBS/
├── boards/dibs/        Zephyr board definition, target dibs/nrf52832
├── firmware/           data-collection firmware (nRF Connect SDK application)
├── samples/bringup/    hardware bring-up test (LED, IMU, battery, mic level)
├── app/DIBS_AUDIO/     iOS companion app (DIBS_AUDIO.xcodeproj)
├── tools/              flash + RTT script, Mac BLE test, tap alignment check
└── .vscode/            nRF Connect for VS Code settings (board root)
```

## Data collection

The phone app finds the board (advertises as `DIBS`). **Start / Stop** runs a
session: the board records the microphone and the IMU together and streams
both; the LED blinks every 2 s while recording. The app saves each session as
a folder (Files app › DIBS_AUDIO › Sessions, or export as .zip):

| File | Content |
|---|---|
| `audio.wav` | 16-bit mono at the measured rate (≈16129 Hz); lost packets are silence |
| `imu_raw.csv` | IMU samples, raw LSB, each with its own IMU hardware timestamp |
| `imu_aligned.csv` | IMU in m/s² and rad/s with `time_s` / `audio_index` on the audio timeline |
| `imu_anchors.csv`, `audio_anchors.csv` | clock anchors used for the alignment |
| `session.json` | board, firmware, settings, loss counters, both clock fits |

- Audio: ICS-41350 PDM, 32 MHz / 31 / 64 = 16129.03 Hz (the PDMCLKCTRL
  formula gives 16113 Hz, 978 ppm off), DC-blocked, IMA ADPCM ≈ 64 kbit/s
- IMU: LSM6DSV32X accel ±8 g + gyro ±2000 dps at 120 Hz nominal (this
  part's oscillator runs ~1.3 % slow, ≈118.5 Hz), FIFO with timestamps
- Link: 2M PHY, ATT MTU 247; 15–30 ms interval while recording
- Protocol v3: `firmware/src/protocol.h` ↔ `app/DIBS_AUDIO/DIBS_AUDIO/DIBSProtocol.swift`

### How audio and IMU are aligned

The board runs a session clock (TIMER3, 1 µs) from the same 32 MHz crystal
as the microphone. A PPI channel captures every PDM buffer end on it, and the
IMU thread reads the IMU's timestamp counter between two session-clock reads.
The app fits a line per stream (audio samples → µs, IMU ticks → µs) and
places each IMU sample by interpolating between neighbouring IMU anchors
(the IMU's RC oscillator wanders ±150 µs over a minute). Measured 2026-11-09:
audio fit residual 0 µs, IMU fit 10–60 µs, no drift between taps over 30 s.

A constant delay remains between the two signal paths: tapping the board
puts the IMU peak ≈6 ms after the audio click (±3 ms, one IMU sample is
8.4 ms). `python3 tools/tap_check.py "<session folder>"` measures it;
record it in `session.json` → `fixedDelayCorrectionMs` once settled.

### Power policy

| State | BLE | Fuel gauge |
|---|---|---|
| moving, no phone | advertising every 1.0–1.08 s | hibernating |
| still for ~68 s, no phone | **advertising stops**; IMU at 15 Hz low power wakes it on motion | hibernating |
| phone connected | 30–45 ms interval, slave latency 20 | polled every 5 s |
| phone connected, still | link kept | hibernating |
| recording | 15–30 ms, no latency; never parks | polled every 5 s |

Measured 2026-11-09 (PPK2 sourcing 4.2 V at the battery pins, SWD unplugged):

| State | Current | 30 mAh lasts |
|---|---|---|
| parked (still, no phone) | 86 µA | ~14 days |
| advertising (1 s) | 93–96 µA | ~13 days |
| connected idle | ~110 µA | ~11 days |
| recording audio + IMU | 2.89 mA | ~10 h |

IMU INT1 (P0.28) must use GPIO SENSE (`sense-edge-mask` in the board DTS):
as a GPIOTE IN channel it cost ~300 µA (16 MHz clock kept on, nRF52832
anomaly 89 with TWIM).

Open: an ~80 µA floor is hardware. `samples/sleep_floor` (board init only,
everything else off) draws 103 µA, with or without the microphone clock held
low and with the PDM, logging or fuel gauge state changed. The nRF52832 itself
sleeps at ~2 µA either regulator (the DC/DC is not used in System ON idle),
so look at the boards' rails: power +1V8 at J1 pin 4 directly from the PPK2
(no battery) to split the 1.8 V loads (nRF, IMU, mic, pull-ups) from the
VBAT side (BQ25180, MAX17048, TPS82740, D1/Q1).

### Robustness

- Task watchdog over the hardware WDT: the system workqueue, the session
  thread and the IMU thread each have a channel; a hang resets the board.
  The nRF52 WDT survives soft resets, so after one the firmware keeps the
  running WDT fed instead of failing to configure it.
- Fatal errors reboot (`CONFIG_RESET_ON_FATAL_ERROR`); the reset reason
  (RESETREAS) goes to the app in every session.json.
- `firmware/release.conf` builds without RTT/logging (Extra Kconfig fragment
  in VS Code).

### Run the app

Open `app/DIBS_AUDIO/DIBS_AUDIO.xcodeproj` in Xcode, pick your iPhone and
press Run (team 8BDVU68JXP, bundle id `com.yuxin.DIBS-AUDIO`). Bluetooth
doesn't work in the simulator. The app keeps receiving with the screen locked
(bluetooth-central background mode).

### Tools

- `tools/flash_rtt.sh [seconds]` flashes `firmware/build`, then prints the RTT
  log; `--read` prints the log of the running board.
- `tools/mac_ble_test/build.sh` builds `dibs_mactest` from the app's own BLE,
  storage and alignment code; run `dibs_mactest <dir> <seconds>` in a
  Terminal to record a session from the Mac.
- `tools/tap_check.py` checks audio/IMU alignment on a session with taps.

## Hardware

| Part | Function | Connection |
|---|---|---|
| nRF52832-CIAA (U1) | MCU + BLE | VDD 1.8 V, LDO only (DCC not connected) |
| ICS-41350 (MK2) | PDM microphone | CLK P0.16, DATA P0.15, SELECT = GND (left) |
| LSM6DSV32X (U2) | IMU | I2C 0x6B, INT1 P0.28 (schematic symbol says 16X) |
| BQ25180 (U3) | Li-ion charger | I2C 0x6A |
| MAX17048 (U4) | Fuel gauge | I2C 0x36, ALRT P0.08 |
| D1 + Q1 | Green LED, battery powered | gate P0.18 (active high) |
| Y1 / Y2 | 32 MHz / 32.768 kHz crystals | |
| J1 | SWD + VBUS | NRST pin is not routed to P0.21 |

I2C: SDA P0.03, SCL P0.04, 4.7 kΩ pull-ups to 1.8 V.

## Build and flash (VS Code)

1. Open the `DIBS` folder in VS Code (nRF Connect SDK v3.1.1).
2. nRF Connect → Applications → `firmware` (or `samples/bringup`) →
   **Add build configuration**,
   board target **`dibs/nrf52832`** (listed under custom boards).
3. **Build**, then **Flash** through the nRF52 DK's Debug Out (P19) to J1.
4. Console output is on **RTT** (the board has no UART); open it from the
   connected device's RTT entry in the nRF Connect panel.

Command line equivalent:

```
west build -b dibs/nrf52832 -d firmware/build firmware -- -DBOARD_ROOT=$PWD
west flash -d firmware/build
```

## Debug port (APPROTECT)

The nRF52832 on this board is build code G (Rev 3): its debug port locks on
every reset unless `UICR.APPROTECT = 0x5A`. A locked chip gets recovered
(fully erased) on the next J-Link connection, which looks like "the firmware
disappeared". The board code (`boards/dibs/board.c`) writes `0x5A` on the
first boot and resets once, so RTT and debugging keep working whatever tool
flashed the image. Disable `CONFIG_DIBS_OPEN_DEBUG_PORT` for production.

## Bring-up results (2026-10-19)

- SWD, boot, LDO supply, 32.768 kHz crystal (+27 ppm vs. 32 MHz crystal)
- BLE advertising and connection from a phone
- PDM microphone: noise floor ≈ 70–120 RMS, claps and speech 30–40 dB above
- IMU, charger, fuel gauge through the Zephyr drivers; LED blinks on battery

Battery: 30 mAh cell, charged at 10 mA (~0.33 C) to 4.2 V
(`constant-charge-current-max-microamp` in the DTS). Without a battery the
charger holds BAT at 4.2 V, so the app shows ~4.20 V, ~100 %, "Charged".

Open items: the MAX17048 has no battery model yet (SOC reads ~103 % when full); Q1 has no
gate pull-down (board code drives P0.18 low at boot).
