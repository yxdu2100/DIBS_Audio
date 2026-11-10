#!/bin/zsh
# Flash the DIBS board through J-Link and print its RTT log.
#
#   tools/flash_rtt.sh [seconds]       flash firmware/build, wait, print log
#   tools/flash_rtt.sh --read          print the log of the running board
#   BUILD=firmware/build_release tools/flash_rtt.sh
#                                      flash another build (no log without RTT)
#
# Writes UICR.APPROTECT = 0x5A (debug port stays open) and clears the stale
# RTT control block before reset, because RAM survives a reset.
set -e
ROOT=${0:A:h:h}
BUILD=${BUILD:-$ROOT/firmware/build}
[[ $BUILD = /* ]] || BUILD=$ROOT/$BUILD
HEX=$BUILD/merged.hex
# sysbuild names the image directory after the application
ELF=$(ls $BUILD/*/zephyr/zephyr.elf 2>/dev/null | grep -v _sysbuild | head -1)
NM=/opt/nordic/ncs/toolchains/561dce9adf/opt/zephyr-sdk/arm-zephyr-eabi/bin/arm-zephyr-eabi-nm
[[ -f $ELF && -f $HEX ]] || { echo "no build in $BUILD; build first" >&2; exit 1; }
D=$(mktemp -d)
CB_SYM=$($NM $ELF | awk '$3=="_SEGGER_RTT"{print $1}')
CB=$([[ -n $CB_SYM ]] && printf '0x%x' $((0x$CB_SYM)) || echo 0x20000000)
J() { /usr/local/bin/JLinkExe -device NRF52832_XXAA -if SWD -speed 4000 -autoconnect 1 -NoGui 1 -CommandFile $1 2>&1; }

if [[ $1 != --read ]]; then
  cat > $D/f.jlink <<X
connect
h
erase
loadfile $HEX
w4 0x4001E504 1
sleep 10
w4 0x10001208 0x5A
sleep 10
w4 0x4001E504 0
w4 $CB 0
r
g
exit
X
  J $D/f.jlink | grep -E "rror|Could not|FAILED" || true
  [[ -n $CB_SYM ]] || { echo "flashed $BUILD (no RTT in this build)"; exit 0; }
  sleep ${1:-3}
fi

printf 'connect\nmem32 %s 10\nexit\n' $CB > $D/c.jlink
L=$(J $D/c.jlink | grep -i -A2 "^${CB#0x}" | tr '\n' ' ')
BUF=$(echo $L | awk '{print $12}'); WR=$(echo $L | awk '{print $16}')
printf 'connect\nsavebin %s/b.bin 0x%s 0x%s\nexit\n' $D $BUF $WR > $D/s.jlink
J $D/s.jlink >/dev/null
LC_ALL=C sed 's/\x1b\[[0-9;]*m//g' $D/b.bin | tr -d '\000'
