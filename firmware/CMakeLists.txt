cmake_minimum_required(VERSION 3.20.0)
# Board definition lives in <repo>/boards/dibs.
list(APPEND BOARD_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/..)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})

project(dibs_firmware)

target_sources(app PRIVATE
    src/main.c
    src/adpcm.c
    src/audio.c
    src/ble.c
    src/battery.c
    src/imu.c
    src/power.c
    src/session.c
    src/timebase.c
    src/watchdog.c
)
