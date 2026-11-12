import Foundation

// Runs the iOS app's BLE, storage and alignment code on a Mac:
//   dibs_mactest <output dir> [seconds] [board name, e.g. DIBS_Audio-A05D | any] [std | hr | hrimu] [1m | 2m]
// Selects the named board (or the first one found), records one session,
// saves it like the app does and prints a summary.
let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)
let seconds = args.count > 2 ? Double(args[2]) ?? 5 : 5
let wantedBoard = args.count > 3 && args[3] != "any" ? args[3] : nil
let mode: IMUMode = args.count < 5 ? .standard
    : ["hr": .highRate, "hrimu": .highRateIMUOnly][args[4]] ?? .standard
let store = RecordingStore(directory: outDir)
let ble = DIBSBLEManager()
ble.imuMode = mode
ble.phy = args.count > 5 && args[5].lowercased() == "2m" ? .twoM : .oneM
ble.sessionsDirectory = store.directory
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
        print(String(format: "imu:   %@ mode, %d accel samples (%.2f Hz), %d packets, %d lost, %d dropped, %d overruns, %d I2C errors",
                     "\(m.imu.mode ?? .standard)", m.imu.samples, Double(m.imu.samples) / m.audio.durationSeconds,
                     m.imu.packets, m.imu.lostPackets, m.imu.droppedOnBoard, m.imu.overruns, m.imu.i2cErrors))
        if m.imu.mode?.isHighRate == true {
            print(String(format: "accel: %.3f Hz measured (wav %d Hz), %d zero-filled, timestamps: %@, %d rejected",
                         m.imu.accelSampleRateHz ?? 0, m.imu.accelWavSampleRateHz ?? 0,
                         m.imu.missingAccelSamples ?? 0,
                         m.imu.accelTimestampFit.map { String(format: "%.4f ticks/sample, rms %.2f ticks, %d points", $0.slopeMicrosPerCount, $0.residualRMSMicros, $0.pointsUsed) } ?? "no fit",
                         m.imu.accelTimestampsRejected ?? 0))
        }
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
        let rssi = m.rssi.map { "median \($0.medianDBm) dBm, min \($0.minDBm), max \($0.maxDBm), \($0.readings) readings" } ?? "none"
        print("radio: PHY \(m.blePHY ?? "?") (asked \(m.blePHYRequested ?? "?")), RSSI \(rssi)")
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
