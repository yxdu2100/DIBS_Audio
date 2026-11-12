# DIBS

Firmware, board definition and (later) companion app for the DIBS board
(KiCad project `dibs_nrf52_v21`).

```
DIBS/
├── boards/dibs/        Zephyr board definition, target dibs/nrf52832
├── firmware/           data-collection firmware (nRF Connect SDK application)
├── samples/bringup/    hardware bring-up test (LED, IMU, battery, mic level)
├── samples/sleep_floor/  board init only, for measuring sleep current
├── app/DIBS_AUDIO/     iOS companion app (DIBS_AUDIO.xcodeproj)
└── tools/              flash + RTT script, Mac BLE test, tap alignment check
```

## Data collection

Each board advertises as **`DIBS_Audio-XXXX`**, XXXX being the low 16
bits of its nRF52832 FICR device ID (the same digits end the `boardID` in
session.json). In the app, tap the connection row to open **Choose Board**:
it lists nearby boards with signal strength; the chosen one is remembered
and reconnected automatically (also with the app in the background), and
each session.json records its `boardName`. A parked board does not
advertise, so move it to make it appear.

The phone app connects to the chosen board. **Start / Stop** runs a
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
- Protocol v4: `firmware/src/protocol.h` ↔ `app/DIBS_AUDIO/DIBS_AUDIO/DIBSProtocol.swift`

### High-rate IMU mode

The segmented control above **Start** picks the IMU mode for the next
session (remembered by the app; `dibs_mactest ... <board|any> std|hr|hrimu`
on the Mac):

| Mode | Accelerometer | Gyroscope | Audio |
|---|---|---|---|
| IMU 120 Hz (standard) | 120 Hz | 120 Hz | 16 kHz |
| 3.84k + mic (high-rate) | 3840 Hz nominal (≈3783 Hz measured) | 240 Hz | 16 kHz |
| 3.84k, no mic (high-rate IMU only) | as above | 240 Hz | off |

IMU-only sessions have no `audio.wav`; their `time_s` columns count seconds
from the session start on the board's clock (`audio_index` is -1). To pair
one with audio from a second board, tap both boards together at the start
and end of the recording.

High-rate sessions add these files (all other files as above; `imu_aligned.csv`
then has one row per gyroscope sample, 240 Hz, with the accel sample of the
same FIFO slot, so the app's chart and `tap_check.py` still work):

| File | Content |
|---|---|
| `imu_accel.wav` | every accel sample, 3 channels x/y/z, raw 16-bit LSB (×`accelMicroGPerLSB`), at the measured rate; samples of lost packets are zeros |
| `imu_accel_timestamps.csv` | the FIFO's IMU timestamps, one per 32 accel samples |
| `imu_accel_timeline.csv` | accel index → `session_us` / `time_s` / `audio_index`; `np.interp` over it times every sample (exact between timestamps, split at FIFO overruns) |
| `imu_gyro_raw.csv` | raw gyroscope samples with the accel index of their slot |

`python3 tools/load_session.py "<session folder>"` loads audio and accel
(either mode) onto the audio timeline.

The IMU's first 100 ms are dropped on the board (both modes): right after
power-up accel samples 1–2 are garbage (one saturated) and the gyroscope
has a ~40 ms start-up transient of up to ~35 dps, the same in every session.
The microphone drops its first 100 ms too, so both streams now begin ~0.1 s
into the session, within a few ms of each other (time_s ≈ 0). Sessions recorded before 2026-11-12 still contain
these samples.

How it works: the FIFO is read in 36-row bursts (the TWIM's 255-byte limit),
~4200 rows/s, about 2/3 of the 400 kHz I2C bus; the IMU timestamp is
batched every 32 accel samples. Audio and IMU packets go through one send
queue (`ble_tx_*` in `ble.c`), so a slow link drops packets (counted, and
zero-filled by the app) instead of stalling the microphone or overflowing
the IMU FIFO. The stream is ~33 kB/s (~150 notifications/s); high-rate
sessions ask for a 15 ms connection interval and start the sensors once
the phone has applied it (it takes ~3 s; at most 5 s), so the stream does
not begin on the slower link.

Measured 2026-11-11 with a MacBook as central (`dibs_mactest`): accel
3782.9 Hz, timestamps exactly 12.000 ticks/sample, no FIFO overruns, but the
Mac carries only ~2 packets per connection event, so **~17 % of audio and
IMU packets were lost** (standard mode: 0 %). Check the loss on the iPhone
before relying on high-rate data (Quality section of the session).

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

### Battery protection and storage

On battery (USB absent) the board checks the cell every 5 s while a phone
is connected, else once a minute (three readings in a row decide):

| Cell | Action |
|---|---|
| < 3.30 V | stop the session (`endReason: lowBattery`), refuse new ones; app shows "Battery low" |
| ≥ 3.45 V or USB in | sessions allowed again |
| < 3.15 V | charger shutdown mode, ahead of the BQ25180's 3.0 V BUVLO cut-off |

**Turn off for storage** (Choose Board sheet, BLE command 0x02) puts the
BQ25180 in shutdown mode: ~15 nA from the cell, and only plugging in USB
turns the board back on. With USB connected the request waits until USB is
removed ("Turns off when unplugged").

A deeply discharged cell (below 3.0 V) is pre-charged at a reduced current
first; one that does not climb past 3.0 V within an hour or gets warm should
be replaced.

### Recording to disk

The app writes a session to its folder while it records (`CaptureSpool`):
audio and accel samples are appended to `audio.wav` / `imu_accel.wav`, whose
headers are updated at every flush (every 2 s), and the anchors, timestamps
and gyro rows to their CSVs. Memory stays flat however long the session is;
only the small per-second streams (anchors, timestamps, gyro: ~20 MB per
hour in high-rate mode) are also kept for the clock fits at Stop. Disk use is
~300 MB per hour in high-rate mode with audio. A folder that still holds an
`INCOMPLETE` file was interrupted (app killed or crashed): its WAVs and CSVs
are valid up to the last flush, but it has no `session.json` or aligned
files.

`rssi.csv` logs the signal strength at the phone about once a second
(`phone_s, rssi_dbm, audio_samples, accel_samples`); the sample counts say
how much data had arrived, so `audio_samples / sampleRateHz` puts each reading
on the data's `time_s` axis (to within the link's latency). `session.json` →
`rssi` has the median, min and max. Packet loss that coincides with a drop
in RSSI is the radio path (distance, body, hand); loss at good RSSI points
at the phone (busy, background) instead.

### Radio PHY and transmit power

The board transmits at +4 dBm, the nRF52832's maximum: worn against the skin
the chip antenna loses 10–20 dB. The app's PHY picker (start command byte 3)
chooses 1M or 2M per session; `session.json` → `blePHY` is the PHY the board
reported in use. **1M is the default**: on the face, 1M with the standard
mode (mic + IMU 120 Hz, ~10 kB/s) lost no packets even at low RSSI. High-rate
mode (~33 kB/s) needs a good link (phone close, same side, Wi-Fi off); check
its loss per session. Boards on firmware before 4.1 reject a 1M start:
pick 2M for them (the app then sends the old 2-byte command) or flash them.

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
  storage and alignment code; run `dibs_mactest <dir> <seconds> [DIBS_Audio-XXXX]`
  in a Terminal to record a session from the Mac.
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

1. Open the `DIBS` folder in VS Code (nRF Connect SDK v3.1.1). The board
   lives in this repository, so add the folder as a board root: in
   `.vscode/settings.json` (not tracked) set
   `"nrf-connect.boardRoots": ["${workspaceFolder}"]`.
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
