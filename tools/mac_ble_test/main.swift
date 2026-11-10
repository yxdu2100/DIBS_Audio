import Foundation

// Runs the iOS app's BLE, storage and alignment code on a Mac:
//   dibs_mactest <output dir> [seconds] [board name, e.g. DIBS_Audio-A05D]
// Selects the named board (or the first one found), records one session,
// saves it like the app does and prints a summary.
let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)
let seconds = args.count > 2 ? Double(args[2]) ?? 5 : 5
let wantedBoard = args.count > 3 ? args[3] : nil
let store = RecordingStore(directory: outDir)
let ble = DIBSBLEManager()
ble.startBrowsing()
var started = false
var lastState: DIBSBLEManager.ConnectionState?

ble.onRecordingFinished = { capture in
    do {
        let r = try store.save(capture)
        let m = r.metadata!
        print(String(format: "audio: %.2f s @ %.3f Hz, %d packets, %d lost, %d dropped on board",
                     m.audio.durationSeconds, m.audio.sampleRateHz, m.audio.receivedPackets,
                     m.audio.lostPackets, m.audio.droppedOnBoard))
        print(String(format: "imu:   %d samples (%.2f Hz), %d packets, %d lost, %d dropped, %d overruns, %d I2C errors",
                     m.imu.samples, Double(m.imu.samples) / m.audio.durationSeconds, m.imu.packets,
                     m.imu.lostPackets, m.imu.droppedOnBoard, m.imu.overruns, m.imu.i2cErrors))
        if let f = m.audioClockFit {
            print(String(format: "audio clock: %.3f Hz measured (nominal %.3f, %+.0f ppm), %d anchors (%d rejected), residual rms %.1f us, max %.1f us",
                         m.audio.sampleRateHz, m.audio.nominalSampleRateHz,
                         (m.audio.sampleRateHz / m.audio.nominalSampleRateHz - 1) * 1e6,
                         f.pointsUsed, f.pointsRejected, f.residualRMSMicros, f.residualMaxMicros))
        } else {
            print("audio clock: no fit")
        }
        if let f = m.imuClockFit {
            print(String(format: "imu clock:   %.6f us/tick (%+.3f %% vs 21.75), %d anchors (%d rejected), residual rms %.1f us, max %.1f us",
                         f.slopeMicrosPerCount, (f.slopeMicrosPerCount / 21.75 - 1) * 100,
                         f.pointsUsed, f.pointsRejected, f.residualRMSMicros, f.residualMaxMicros))
        } else {
            print("imu clock: no fit")
        }
        print("saved", r.folder.path)
        exit(0)
    } catch {
        print("save failed:", error)
        exit(1)
    }
}

Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    MainActor.assumeIsolated {
        if let board = ble.nearbyBoards.first(where: { wantedBoard == nil || $0.name == wantedBoard }),
           ble.selectedBoardID != board.id, !started,
           wantedBoard != nil || ble.selectedBoardID == nil {
            print("selecting", board.name)
            ble.select(board)
        }
        if ble.connectionState != lastState {
            print("state:", ble.connectionState, ble.selectedBoardName ?? "", ble.lastError ?? "")
            lastState = ble.connectionState
        }
        if ble.isReady && !started {
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print("start (\(Int(seconds)) s)"); ble.startRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    print("stop"); ble.stopRecording()
                }
            }
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 30) { print("timeout"); exit(1) }
RunLoop.main.run()
