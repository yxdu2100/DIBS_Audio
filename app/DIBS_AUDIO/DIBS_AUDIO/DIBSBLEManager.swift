import CoreBluetooth
import Foundation

/// A DIBS board seen advertising nearby.
struct DiscoveredBoard: Identifiable, Equatable {
    /// CoreBluetooth identifier (stable per phone, not across phones).
    let id: UUID
    /// "DIBS_Audio-XXXX", XXXX from the board's FICR device ID.
    var name: String
    var rssi: Int
    var lastSeen: Date
}

/// Finds DIBS boards, connects to the one the user chose, starts/stops
/// sessions and collects the streamed audio and IMU data.
@Observable
final class DIBSBLEManager: NSObject {
    enum ConnectionState: Equatable {
        case poweredOff, unauthorized, noBoardSelected, scanning, connecting, connected
    }

    /// Data collected for the session in progress.
    struct Capture {
        var startedAt = Date()
        var boardName: String?
        /// The session folder, written while recording.
        var spool: CaptureSpool
        /// Samples written to audio.wav (lost packets as silence).
        var audioSampleCount = 0
        var receivedPackets = 0
        var lostPackets = 0
        var nextSeq: UInt16 = 0
        var lastPacketSamples = 0
        var level: Float = 0
        /// Last sample of each 20 ms buffer (index in audio.wav) and the
        /// session time the board's microphone finished it.
        var audioAnchors: [SessionAligner.AudioAnchor] = []

        var imuMode: IMUMode = .standard
        var phy: RadioPHY = .oneM
        /// Standard mode packets.
        var imuPackets: [IMUPacket] = []
        /// Accelerometer samples received (both modes).
        var imuSampleCount = 0
        var imuLostPackets = 0
        var imuNextSeq: UInt16 = 0
        var imuReceivedPackets = 0
        /// Accel samples received per second over the last ~1 s (live display).
        var imuRateHz: Double = 0
        var imuRateMark: (time: Date, count: Int)?

        /// High-rate mode: accel samples written to imu_accel.wav, placed by
        /// their session accel index (samples of lost packets are zeros).
        var hrAccelCount = 0
        /// Accel samples zero-filled for lost packets.
        var hrMissingAccel = 0
        var hrGyro: [(accelIndex: Int64, x: Int16, y: Int16, z: Int16)] = []
        var hrTimestamps: [(accelIndex: Int64, ticks: UInt32)] = []
        var hrAnchors: [(seq: UInt16, ticks: UInt32, micros: UInt32)] = []
        /// Accel index of the first sample after each FIFO overrun.
        var hrOverruns: [Int64] = []

        /// Signal strength at the phone (dBm), read about once a second.
        var rssi: [Int] = []
        var rssiRequestedAt: Date?

        /// Latest status from the board; the final one carries the counters.
        var status: DIBSStatus?
    }

    private(set) var connectionState: ConnectionState = .poweredOff
    private(set) var discoveredBoards: [DiscoveredBoard] = []
    /// The board this phone records from, remembered across launches.
    private(set) var selectedBoardID: UUID?
    private(set) var selectedBoardName: String?
    private(set) var isRecording = false
    private(set) var capture: Capture?
    private(set) var battery: DIBSBattery?
    private(set) var lastError: String?
    /// IMU mode for the next session, remembered across launches.
    var imuMode: IMUMode = .standard {
        didSet { UserDefaults.standard.set(Int(imuMode.rawValue), forKey: DefaultsKey.imuMode) }
    }

    /// Radio PHY for the next session, remembered across launches. 1M by
    /// default: worn on the skin it loses no packets at RSSI where 2M does.
    var phy: RadioPHY = .oneM {
        didSet { UserDefaults.standard.set(Int(phy.rawValue), forKey: DefaultsKey.phy) }
    }

    /// Where session folders are created (RecordingStore's directory).
    var sessionsDirectory = RecordingStore.defaultDirectory

    /// Called with the finished capture once the board confirms it stopped.
    var onRecordingFinished: ((Capture) -> Void)?

    private enum DefaultsKey {
        static let boardID = "DIBS.selectedBoardID"
        static let boardName = "DIBS.selectedBoardName"
        static let imuMode = "DIBS.imuMode"
        static let phy = "DIBS.phy"
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var stopTimeout: Task<Void, Never>?
    /// The device list wants live RSSI updates (picker open).
    private var browsing = false

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        selectedBoardID = defaults.string(forKey: DefaultsKey.boardID).flatMap(UUID.init)
        selectedBoardName = defaults.string(forKey: DefaultsKey.boardName)
        imuMode = IMUMode(rawValue: UInt8(defaults.integer(forKey: DefaultsKey.imuMode))) ?? .standard
        phy = RadioPHY(rawValue: UInt8(defaults.integer(forKey: DefaultsKey.phy))) ?? .oneM
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var isReady: Bool { connectionState == .connected && control != nil }

    /// Boards seen in the last 10 s, strongest first.
    var nearbyBoards: [DiscoveredBoard] {
        let cutoff = Date().addingTimeInterval(-10)
        return discoveredBoards.filter { $0.lastSeen > cutoff || $0.id == selectedBoardID }
            .sorted { $0.rssi > $1.rssi }
    }

    /// Lists nearby boards for the picker, with RSSI updates.
    func startBrowsing() {
        browsing = true
        updateScanning()
    }

    func stopBrowsing() {
        browsing = false
        updateScanning()
    }

    /// Records from `board` from now on. Refused while recording.
    @discardableResult
    func select(_ board: DiscoveredBoard) -> Bool {
        guard !isRecording else { return false }
        guard board.id != selectedBoardID else { return true }
        selectedBoardID = board.id
        selectedBoardName = board.name
        UserDefaults.standard.set(board.id.uuidString, forKey: DefaultsKey.boardID)
        UserDefaults.standard.set(board.name, forKey: DefaultsKey.boardName)
        lastError = nil
        if let peripheral {
            // Connect to the new board once the old link is down.
            central.cancelPeripheralConnection(peripheral)
        } else {
            connectSelected()
        }
        return true
    }

    /// Stops using the selected board on this phone.
    func forgetBoard() {
        guard !isRecording else { return }
        selectedBoardID = nil
        selectedBoardName = nil
        UserDefaults.standard.removeObject(forKey: DefaultsKey.boardID)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.boardName)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        updateScanning()
    }

    func startRecording() {
        guard isReady, !isRecording else { return }
        if battery?.isLow == true {
            lastError = "Battery low. Charge the board before recording."
            return
        }
        let startedAt = Date()
        let folder = sessionsDirectory.appendingPathComponent(RecordingStore.folderName(for: startedAt))
        let spool: CaptureSpool
        do {
            spool = try CaptureSpool(folder: folder, mode: imuMode)
        } catch {
            lastError = "Could not create the session folder: \(error.localizedDescription)"
            return
        }
        capture = Capture(startedAt: startedAt, boardName: selectedBoardName, spool: spool,
                          imuMode: imuMode, phy: phy)
        isRecording = true
        lastError = nil
        // 2M is the firmware's default: leave the byte out so boards before
        // firmware 4.1 still start.
        send(phy == .twoM ? [DIBSProtocol.commandStart, imuMode.rawValue]
                          : [DIBSProtocol.commandStart, imuMode.rawValue, phy.rawValue])
    }

    func stopRecording() {
        guard isRecording else { return }
        send(DIBSProtocol.commandStop)
        // The board answers with an idle status; don't wait forever for it.
        stopTimeout?.cancel()
        stopTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.finishRecording()
        }
    }

    /// Turns the board off for storage (charger shutdown mode, ~15 nA). Only
    /// plugging in USB turns it back on. Refused while recording.
    @discardableResult
    func shutDownBoard() -> Bool {
        guard isReady, !isRecording else { return false }
        send(DIBSProtocol.commandShip)
        return true
    }

    private func send(_ command: UInt8) {
        send([command])
    }

    private func send(_ bytes: [UInt8]) {
        guard let peripheral, let control else { return }
        peripheral.writeValue(Data(bytes), for: control, type: .withResponse)
    }

    /// Changes the capture in place: copying it out and back would copy its
    /// sample arrays on every packet.
    private func updateCapture(_ body: (inout Capture) -> Void) {
        guard capture != nil else { return }
        body(&capture!)
    }

    private func finishRecording() {
        stopTimeout?.cancel()
        stopTimeout = nil
        guard isRecording else { return }
        isRecording = false
        if let capture {
            if capture.receivedPackets + capture.imuReceivedPackets > 0 {
                onRecordingFinished?(capture)
            } else {
                capture.spool.discard()
            }
        }
        capture = nil
    }

    /// Ends a session that never got data, without saving it.
    private func abandonCapture() {
        capture?.spool.discard()
        capture = nil
        isRecording = false
    }

    /// Asks iOS to connect to the selected board. A pending connect needs no
    /// scan and completes whenever the board advertises, also in background.
    private func connectSelected() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        guard let id = selectedBoardID else {
            connectionState = .noBoardSelected
            updateScanning()
            return
        }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = known
            known.delegate = self
            connectionState = .connecting
            central.connect(known)
        } else {
            // Not known to this phone yet: wait for an advertisement.
            connectionState = .scanning
        }
        updateScanning()
    }

    /// Scans while the picker is open or while no board is connected.
    private func updateScanning() {
        guard central.state == .poweredOn else { return }
        if browsing || peripheral == nil || connectionState != .connected {
            central.scanForPeripherals(
                withServices: [DIBSProtocol.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: browsing])
        } else {
            central.stopScan()
        }
    }

    private func handleAudio(_ data: Data) {
        guard isRecording, let packet = AudioPacket(data) else { return }
        updateCapture { c in
            // Fill lost packets with silence so the timing stays right.
            let gap = Int(packet.seq &- c.nextSeq)
            if c.receivedPackets > 0, gap > 0, gap < 1000 {
                c.lostPackets += gap
                c.spool.audio?.appendZeros(frames: gap * c.lastPacketSamples)
                c.audioSampleCount += gap * c.lastPacketSamples
            }
            c.nextSeq = packet.seq &+ 1
            c.receivedPackets += 1
            c.lastPacketSamples = packet.sampleCount

            var block: [Int16] = []
            ADPCMDecoder.decode(packet, into: &block)
            c.spool.audio?.append(block)
            c.audioSampleCount += block.count
            if packet.endMicros != 0 {
                let anchor = (wavIndex: c.audioSampleCount - 1, micros: packet.endMicros)
                c.audioAnchors.append(anchor)
                c.spool.text("audio_anchors.csv", header: "wav_index,session_us\n")
                    .append("\(anchor.wavIndex),\(anchor.micros)\n")
            }
            var sumSquares: Float = 0
            for v in block { sumSquares += Float(v) * Float(v) }
            c.level = (sumSquares / Float(max(block.count, 1))).squareRoot() / 32768
            c.spool.flushIfDue()
            requestRSSIIfDue(&c)
        }
    }

    private func handleIMU(_ data: Data) {
        guard isRecording else { return }
        if IMUHighRatePacket.isHighRate(data) {
            guard let packet = IMUHighRatePacket(data) else { return }
            updateCapture { c in
                countIMUPacket(seq: packet.seq, in: &c)
                // Place the samples by their index: zeros for lost packets.
                let have = c.hrAccelCount
                let start = Int(packet.accelIndex)
                if start > have {
                    c.hrMissingAccel += start - have
                    c.spool.accel?.appendZeros(frames: start - have)
                    c.hrAccelCount = start
                }
                let skip = max(have - start, 0) * 3
                if skip < packet.accel.count {
                    c.spool.accel?.append(packet.accel[skip...])
                    c.hrAccelCount += (packet.accel.count - skip) / 3
                }
                c.imuSampleCount += packet.accel.count / 3
                c.hrGyro.append(contentsOf: packet.gyro)
                c.hrTimestamps.append(contentsOf: packet.timestamps)
                let spool = c.spool
                if !packet.gyro.isEmpty {
                    let f = spool.text("imu_gyro_raw.csv", header: "accel_index,gx,gy,gz\n")
                    for g in packet.gyro { f.append("\(g.accelIndex),\(g.x),\(g.y),\(g.z)\n") }
                }
                if !packet.timestamps.isEmpty {
                    let f = spool.text("imu_accel_timestamps.csv", header: "accel_index,imu_ticks\n")
                    for t in packet.timestamps { f.append("\(t.accelIndex),\(t.ticks)\n") }
                }
                if packet.hasAnchor {
                    c.hrAnchors.append((packet.seq, packet.anchorTicks, packet.anchorMicros))
                    spool.text("imu_anchors.csv", header: RecordingStore.imuAnchorsHeader)
                        .append("\(packet.seq),\(packet.anchorTicks),\(packet.anchorMicros)\n")
                }
                if packet.overrunBefore {
                    c.hrOverruns.append(Int64(packet.accelIndex))
                    spool.text("imu_fifo_overruns.csv", header: "first_accel_index_after\n")
                        .append("\(packet.accelIndex)\n")
                }
                spool.flushIfDue()
                requestRSSIIfDue(&c)
            }
        } else {
            guard let packet = IMUPacket(data) else { return }
            updateCapture { c in
                countIMUPacket(seq: packet.seq, in: &c)
                c.imuSampleCount += packet.samples.count
                c.imuPackets.append(packet)
                c.spool.text("imu_raw.csv", header: RecordingStore.rawCSVHeader)
                    .append(RecordingStore.rawCSVRows(packet))
                if packet.hasAnchor {
                    c.spool.text("imu_anchors.csv", header: RecordingStore.imuAnchorsHeader)
                        .append("\(packet.seq),\(packet.anchorTicks),\(packet.anchorMicros)\n")
                }
                c.spool.flushIfDue()
                requestRSSIIfDue(&c)
            }
        }
    }

    /// Asks for the link's RSSI once a second while data arrives (packet
    /// driven, so it keeps going in the background, unlike a timer).
    private func requestRSSIIfDue(_ c: inout Capture) {
        let now = Date()
        if let last = c.rssiRequestedAt, now.timeIntervalSince(last) < 1 { return }
        c.rssiRequestedAt = now
        peripheral?.readRSSI()
    }

    private func countIMUPacket(seq: UInt16, in c: inout Capture) {
        let gap = Int(seq &- c.imuNextSeq)
        if c.imuReceivedPackets > 0, gap > 0, gap < 1000 {
            c.imuLostPackets += gap
        }
        c.imuNextSeq = seq &+ 1
        c.imuReceivedPackets += 1
        // A rate over the recent past: the average since Start would creep up
        // for the seconds the board waits for the link and lets the IMU settle.
        let now = Date()
        if let mark = c.imuRateMark {
            let dt = now.timeIntervalSince(mark.time)
            if dt >= 1 {
                c.imuRateHz = Double(c.imuSampleCount - mark.count) / dt
                c.imuRateMark = (now, c.imuSampleCount)
            }
        } else {
            c.imuRateMark = (now, c.imuSampleCount)
        }
    }

    private func handleStatus(_ data: Data) {
        guard let status = DIBSStatus(data) else {
            if let v = DIBSStatus.version(of: data), v != DIBSProtocol.version {
                lastError = "Board firmware speaks protocol v\(v); this app needs v\(DIBSProtocol.version). Update the firmware."
            }
            return
        }
        if isRecording { capture?.status = status }
        if status.state == .idle, status.endReason == .lowBattery, isRecording {
            lastError = "Recording stopped: battery low. Charge the board."
            if (capture?.receivedPackets ?? 0) + (capture?.imuReceivedPackets ?? 0) == 0 {
                // Refused before any data: nothing to save.
                abandonCapture()
                return
            }
            finishRecording()
            return
        }
        // Idle while we record: the board stopped (on request or on its own).
        if status.state == .idle, isRecording,
           stopTimeout != nil || (capture?.receivedPackets ?? 0) + (capture?.imuReceivedPackets ?? 0) > 0 {
            finishRecording()
        }
    }
}

extension DIBSBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectSelected()
        case .unauthorized: connectionState = .unauthorized
        default:
            connectionState = .poweredOff
            peripheral = nil
            control = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "DIBS_Audio"
        let rssi = RSSI.intValue == 127 ? -127 : RSSI.intValue  // 127: not available
        let board = DiscoveredBoard(id: peripheral.identifier, name: name, rssi: rssi,
                                    lastSeen: Date())
        if let i = discoveredBoards.firstIndex(where: { $0.id == board.id }) {
            discoveredBoards[i] = board
        } else {
            discoveredBoards.append(board)
        }

        if peripheral.identifier == selectedBoardID, self.peripheral == nil {
            if selectedBoardName != name {
                selectedBoardName = name
                UserDefaults.standard.set(name, forKey: DefaultsKey.boardName)
            }
            self.peripheral = peripheral
            peripheral.delegate = self
            connectionState = .connecting
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([DIBSProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        lastError = error?.localizedDescription
        self.peripheral = nil
        connectSelected()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // Keep whatever arrived before the link dropped.
        finishRecording()
        control = nil
        battery = nil
        self.peripheral = nil
        if let error { lastError = error.localizedDescription }
        // Reconnects to the same board, or to a newly selected one.
        connectSelected()
    }
}

extension DIBSBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == DIBSProtocol.serviceUUID })
        else { return }
        peripheral.discoverCharacteristics(
            [DIBSProtocol.controlUUID, DIBSProtocol.audioUUID, DIBSProtocol.statusUUID,
             DIBSProtocol.batteryUUID, DIBSProtocol.imuUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case DIBSProtocol.controlUUID:
                control = characteristic
            case DIBSProtocol.audioUUID, DIBSProtocol.imuUUID:
                peripheral.setNotifyValue(true, for: characteristic)
            case DIBSProtocol.statusUUID, DIBSProtocol.batteryUUID:
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }
        connectionState = .connected
        updateScanning()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case DIBSProtocol.audioUUID: handleAudio(data)
        case DIBSProtocol.imuUUID: handleIMU(data)
        case DIBSProtocol.statusUUID: handleStatus(data)
        case DIBSProtocol.batteryUUID: battery = DIBSBattery(data)
        default: break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let dbm = RSSI.intValue
        guard error == nil, isRecording, dbm != 127 else { return }  // 127: not available
        updateCapture { c in
            c.rssi.append(dbm)
            // How much data had arrived: audio_samples / sample rate (and the
            // accel index via imu_accel_timeline.csv) place the reading on
            // the data's time axis, to within the link's latency.
            let accel = c.imuMode.isHighRate ? c.hrAccelCount : c.imuSampleCount
            c.spool.text("rssi.csv", header: "phone_s,rssi_dbm,audio_samples,accel_samples\n")
                .append(String(format: "%.3f,%d,%d,%d\n", Date().timeIntervalSince(c.startedAt), dbm,
                               c.audioSampleCount, accel))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            lastError = error.localizedDescription
            if isRecording, stopTimeout == nil { abandonCapture() }
        }
    }
}
