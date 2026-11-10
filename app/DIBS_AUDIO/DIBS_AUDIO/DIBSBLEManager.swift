import CoreBluetooth
import Foundation

/// Finds the DIBS board, starts/stops sessions and collects the streamed
/// audio and IMU data.
@Observable
final class DIBSBLEManager: NSObject {
    enum ConnectionState: Equatable {
        case poweredOff, unauthorized, scanning, connecting, connected
    }

    /// Data collected for the session in progress.
    struct Capture {
        var startedAt = Date()
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
    private(set) var isRecording = false
    private(set) var capture: Capture?
    private(set) var battery: DIBSBattery?
    private(set) var lastError: String?

    /// Called with the finished capture once the board confirms it stopped.
    var onRecordingFinished: ((Capture) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var stopTimeout: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var isReady: Bool { connectionState == .connected && control != nil }

    func startRecording() {
        guard isReady, !isRecording else { return }
        capture = Capture()
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

    private func startScanning() {
        connectionState = .scanning
        central.scanForPeripherals(withServices: [DIBSProtocol.serviceUUID])
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
        case .poweredOn: startScanning()
        case .unauthorized: connectionState = .unauthorized
        default: connectionState = .poweredOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([DIBSProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        lastError = error?.localizedDescription
        startScanning()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // Keep whatever arrived before the link dropped.
        finishRecording()
        control = nil
        battery = nil
        self.peripheral = nil
        if let error { lastError = error.localizedDescription }
        startScanning()
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
