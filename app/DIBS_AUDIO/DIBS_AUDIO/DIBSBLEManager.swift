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
        var samples: [Int16] = []
        var receivedPackets = 0
        var lostPackets = 0
        var nextSeq: UInt16 = 0
        var lastPacketSamples = 0
        var level: Float = 0
        /// Last sample of each 20 ms buffer (index in samples) and the
        /// session time the board's microphone finished it.
        var audioAnchors: [SessionAligner.AudioAnchor] = []

        var imuPackets: [IMUPacket] = []
        var imuSampleCount = 0
        var imuLostPackets = 0
        var imuNextSeq: UInt16 = 0

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

    /// Called with the finished capture once the board confirms it stopped.
    var onRecordingFinished: ((Capture) -> Void)?

    private enum DefaultsKey {
        static let boardID = "DIBS.selectedBoardID"
        static let boardName = "DIBS.selectedBoardName"
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
        capture = Capture(boardName: selectedBoardName)
        isRecording = true
        lastError = nil
        send(DIBSProtocol.commandStart)
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

    private func send(_ command: UInt8) {
        guard let peripheral, let control else { return }
        peripheral.writeValue(Data([command]), for: control, type: .withResponse)
    }

    private func finishRecording() {
        stopTimeout?.cancel()
        stopTimeout = nil
        guard isRecording else { return }
        isRecording = false
        if let capture, !capture.samples.isEmpty {
            onRecordingFinished?(capture)
        }
        capture = nil
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
        guard isRecording, var c = capture, let packet = AudioPacket(data) else { return }

        // Fill lost packets with silence so the timing stays right.
        let gap = Int(packet.seq &- c.nextSeq)
        if c.receivedPackets > 0, gap > 0, gap < 1000 {
            c.lostPackets += gap
            c.samples.append(contentsOf: repeatElement(0, count: gap * c.lastPacketSamples))
        }
        c.nextSeq = packet.seq &+ 1
        c.receivedPackets += 1
        c.lastPacketSamples = packet.sampleCount

        let start = c.samples.count
        ADPCMDecoder.decode(packet, into: &c.samples)
        if packet.endMicros != 0 {
            c.audioAnchors.append((c.samples.count - 1, packet.endMicros))
        }
        let block = c.samples[start...]
        let sumSquares = block.reduce(Float(0)) { $0 + Float($1) * Float($1) }
        c.level = (sumSquares / Float(max(block.count, 1))).squareRoot() / 32768
        capture = c
    }

    private func handleIMU(_ data: Data) {
        guard isRecording, var c = capture, let packet = IMUPacket(data) else { return }

        let gap = Int(packet.seq &- c.imuNextSeq)
        if !c.imuPackets.isEmpty, gap > 0, gap < 1000 {
            c.imuLostPackets += gap
        }
        c.imuNextSeq = packet.seq &+ 1
        c.imuSampleCount += packet.samples.count
        c.imuPackets.append(packet)
        capture = c
    }

    private func handleStatus(_ data: Data) {
        guard let status = DIBSStatus(data) else {
            if let v = DIBSStatus.version(of: data), v != DIBSProtocol.version {
                lastError = "Board firmware speaks protocol v\(v); this app needs v\(DIBSProtocol.version). Update the firmware."
            }
            return
        }
        if isRecording { capture?.status = status }
        // Idle while we record: the board stopped (on request or on its own).
        if status.state == .idle, isRecording,
           stopTimeout != nil || (capture?.receivedPackets ?? 0) > 0 {
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

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            lastError = error.localizedDescription
            if isRecording, stopTimeout == nil { isRecording = false; capture = nil }
        }
    }
}
