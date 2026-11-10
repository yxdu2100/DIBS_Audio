#!/bin/zsh
# Builds dibs_mactest from the app's sources. Run it from a Terminal (the
# process needs the Terminal's Bluetooth permission).
set -e
HERE=${0:A:h}
APP=$HERE/../../app/DIBS_AUDIO/DIBS_AUDIO
cd $HERE
swiftc -O -default-isolation MainActor -o dibs_mactest main.swift \
  $APP/DIBSBLEManager.swift $APP/DIBSProtocol.swift $APP/ADPCMDecoder.swift \
  $APP/RecordingStore.swift $APP/SessionAligner.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign -s - -f dibs_mactest
