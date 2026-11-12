import CoreBluetooth

/// BLE protocol v4, shared with firmware/src/protocol.h.
enum DIBSProtocol {
    static let version: UInt8 = 4

    static let serviceUUID = CBUUID(string: "D1B50001-6E2B-4C1F-9A7D-3E8B5F0C2A41")
    static let controlUUID = CBUUID(string: "D1B50002-6E2B-4C1F-9A7D-3E8B5F0C2A41")
    static let audioUUID = CBUUID(string: "D1B50003-6E2B-4C1F-9A7D-3E8B5F0C2A41")
    static let statusUUID = CBUUID(string: "D1B50004-6E2B-4C1F-9A7D-3E8B5F0C2A41")
    static let batteryUUID = CBUUID(string: "D1B50005-6E2B-4C1F-9A7D-3E8B5F0C2A41")
    static let imuUUID = CBUUID(string: "D1B50006-6E2B-4C1F-9A7D-3E8B5F0C2A41")

    static let commandStop: UInt8 = 0x00
    static let commandStart: UInt8 = 0x01
    /// Charger shutdown mode for storage; only USB wakes the board. With USB
    /// present it takes effect when USB is removed.
    static let commandShip: UInt8 = 0x02

    /// seq (u16) + predictor (i16) + step index (u8) + buffer end time (u32)
    static let audioHeaderLength = 9
    static let imuHeaderLength = 12
    static let imuSampleLength = 16
    static let imuHighRateHeaderLength = 18
    static let imuFlagHighRate: UInt8 = 0x80
}

/// What the IMU records in a session (byte 2 of the start command).
enum IMUMode: UInt8, Codable, CaseIterable, Identifiable {
    /// Accelerometer + gyroscope at 120 Hz.
    case standard = 0
    /// Accelerometer at 3840 Hz + gyroscope at 240 Hz.
    case highRate = 1
    /// As highRate with the microphone off (no audio.wav; times are on the
    /// board's session clock).
    case highRateIMUOnly = 2

    var isHighRate: Bool { self != .standard }
    var hasAudio: Bool { self != .highRateIMUOnly }

    var id: UInt8 { rawValue }

    /// session.json stores the name ("standard", "highRate").
    private static let names: [IMUMode: String] = [.standard: "standard", .highRate: "highRate",
                                                     .highRateIMUOnly: "highRateIMUOnly"]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let name = try? c.decode(String.self),
           let mode = Self.names.first(where: { $0.value == name })?.key {
            self = mode
        } else {
            self = IMUMode(rawValue: try c.decode(UInt8.self)) ?? .standard
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Self.names[self]!)
    }

    var label: String {
        switch self {
        case .standard: "IMU 120 Hz"
        case .highRate: "3.84k + mic"
        case .highRateIMUOnly: "3.84k, no mic"
        }
    }
}

/// Radio PHY for a session (byte 3 of the start command). 1M reaches ~3 dB
/// further at half the raw bit rate.
enum RadioPHY: UInt8, CaseIterable, Identifiable {
    case oneM = 1
    case twoM = 2

    var id: UInt8 { rawValue }
    var label: String { self == .oneM ? "1M PHY" : "2M PHY" }
    /// "1M" / "2M" for session.json.
    var name: String { self == .oneM ? "1M" : "2M" }
}

/// Little-endian readers for notification payloads.
private extension Array where Element == UInt8 {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func i16(_ i: Int) -> Int16 { Int16(bitPattern: u16(i)) }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
}

/// Contents of the status characteristic (struct dibs_status in firmware).
struct DIBSStatus: Equatable, Codable {
    enum State: UInt8, Codable {
        case idle = 0
        case recording = 1
    }

    enum EndReason: UInt8, Codable {
        case none = 0, stop = 1, disconnect = 2, error = 3, lowBattery = 4
    }

    var state: State
    var firmwareVersion: UInt16
    var boardID: UInt64
    var resetReason: UInt32
    var sessionID: UInt32
    var endReason: EndReason
    var imuFreqFine: Int8
    var audioSkipSamples: Int
    var pdmClockHz: UInt32
    /// Session-clock microseconds when the PDM started; 0 until known.
    var audioT0us: UInt32
    var audioDroppedPackets: Int
    var imuODRHz: Int
    var accelMicroGPerLSB: Int
    var gyroMilliDPSPerLSB: Int
    var imuDroppedPackets: Int
    var imuOverruns: Int
    var imuSamples: Int
    var imuI2CErrors: Int
    var imuMode: IMUMode
    var gyroODRHz: Int
    /// Accelerometer samples per FIFO timestamp (1 in standard mode).
    var imuAccelPerTimestamp: Int
    /// PHY in use during the session (RadioPHY raw value), 0 = unknown
    /// (firmware before 4.1).
    var phy: UInt8

    static let length = 56

    /// Nominal audio sample rate from the PDM clock register; the session's
    /// audio clock fit measures the real one.
    var nominalSampleRate: Double { Double(pdmClockHz) / 64 }

    /// Protocol version of a raw status value, to report a firmware/app mismatch.
    static func version(of data: Data) -> UInt8? { data.first }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= Self.length, b[0] == DIBSProtocol.version,
              let state = State(rawValue: b[1]) else { return nil }
        self.state = state
        firmwareVersion = b.u16(2)
        boardID = UInt64(b.u32(4)) | UInt64(b.u32(8)) << 32
        resetReason = b.u32(12)
        sessionID = b.u32(16)
        endReason = EndReason(rawValue: b[20]) ?? .error
        imuFreqFine = Int8(bitPattern: b[21])
        audioSkipSamples = Int(b.u16(22))
        pdmClockHz = b.u32(24)
        audioT0us = b.u32(28)
        audioDroppedPackets = Int(b.u16(32))
        imuODRHz = Int(b.u16(34))
        accelMicroGPerLSB = Int(b.u16(36))
        gyroMilliDPSPerLSB = Int(b.u16(38))
        imuDroppedPackets = Int(b.u16(40))
        imuOverruns = Int(b.u16(42))
        imuSamples = Int(b.u32(44))
        imuI2CErrors = Int(b.u16(48))
        imuMode = IMUMode(rawValue: b[50]) ?? .standard
        gyroODRHz = Int(b.u16(52))
        imuAccelPerTimestamp = Int(b.u16(54))
        phy = b[51]
    }
}

/// Contents of the battery characteristic (struct dibs_battery in firmware).
struct DIBSBattery: Equatable {
    enum Charge: UInt8 {
        case unknown = 0
        case discharging = 1   // no USB power
        case notCharging = 2   // USB present, charger idle
        case charging = 3
        case full = 4
    }

    var charge: Charge
    var usbPresent: Bool
    /// On battery below ~3.3 V: the board stops and refuses sessions.
    var isLow: Bool
    /// Shutdown requested on USB: the board turns off when USB is removed.
    var shutdownPending: Bool
    /// Fuel gauge estimate; the generic cell model can report a bit over 100.
    var stateOfCharge: Int
    var voltage: Double

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 6, b[0] == 1 else { return nil }
        usbPresent = b[1] & 0x01 != 0
        isLow = b[1] & 0x02 != 0
        shutdownPending = b[1] & 0x04 != 0
        charge = Charge(rawValue: b[2]) ?? .unknown
        stateOfCharge = Int(b[3])
        voltage = Double(UInt16(b[4]) | UInt16(b[5]) << 8) / 1000
    }
}

/// One audio notification: IMA ADPCM with its own decoder state.
struct AudioPacket {
    var seq: UInt16
    var predictor: Int16
    var stepIndex: UInt8
    /// Session time the PDM finished the buffer ending with this packet's
    /// last sample; 0 if that sample is not a buffer end.
    var endMicros: UInt32
    var payload: Data

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count > DIBSProtocol.audioHeaderLength else { return nil }
        seq = b.u16(0)
        predictor = b.i16(2)
        stepIndex = b[4]
        endMicros = b.u32(5)
        payload = data.subdata(in: data.startIndex + DIBSProtocol.audioHeaderLength ..< data.endIndex)
    }

    var sampleCount: Int { payload.count * 2 }
}

/// One IMU notification: up to 14 samples, each with its own IMU
/// timestamp, plus an optional clock anchor.
struct IMUPacket {
    struct Sample {
        var ticks: UInt32
        var accel: (Int16, Int16, Int16)
        var gyro: (Int16, Int16, Int16)
    }

    var seq: UInt16
    var hasAnchor: Bool
    var overrunBefore: Bool
    var anchorTicks: UInt32
    var anchorMicros: UInt32
    var samples: [Sample]

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= DIBSProtocol.imuHeaderLength,
              b[3] & DIBSProtocol.imuFlagHighRate == 0 else { return nil }
        let n = Int(b[2])
        guard n > 0, b.count >= DIBSProtocol.imuHeaderLength + n * DIBSProtocol.imuSampleLength
        else { return nil }
        seq = b.u16(0)
        hasAnchor = b[3] & 0x01 != 0
        overrunBefore = b[3] & 0x02 != 0
        anchorTicks = b.u32(4)
        anchorMicros = b.u32(8)
        samples = (0..<n).map { k in
            let o = DIBSProtocol.imuHeaderLength + k * DIBSProtocol.imuSampleLength
            return Sample(ticks: b.u32(o),
                          accel: (b.i16(o + 4), b.i16(o + 6), b.i16(o + 8)),
                          gyro: (b.i16(o + 10), b.i16(o + 12), b.i16(o + 14)))
        }
    }
}

/// One high-rate IMU notification: consecutive accelerometer samples
/// numbered from the session start, plus the gyroscope samples and FIFO
/// timestamps that fell in the same FIFO time slots.
struct IMUHighRatePacket {
    var seq: UInt16
    var hasAnchor: Bool
    var overrunBefore: Bool
    var anchorTicks: UInt32
    var anchorMicros: UInt32
    /// Index of `accel[0]` among all accelerometer samples of the session.
    var accelIndex: UInt32
    /// x, y, z interleaved, raw LSB.
    var accel: [Int16]
    /// Gyroscope samples with the index of the accel sample of their slot.
    var gyro: [(accelIndex: Int64, x: Int16, y: Int16, z: Int16)]
    /// FIFO timestamps (IMU ticks) with the index of their accel sample.
    var timestamps: [(accelIndex: Int64, ticks: UInt32)]

    static func isHighRate(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex + 3] & DIBSProtocol.imuFlagHighRate != 0
    }

    init?(_ data: Data) {
        let b = [UInt8](data)
        let h = DIBSProtocol.imuHighRateHeaderLength
        guard b.count >= h, b[3] & DIBSProtocol.imuFlagHighRate != 0 else { return nil }
        let na = Int(b[2]), ng = Int(b[16]), nt = Int(b[17])
        guard b.count >= h + na * 6 + ng * 8 + nt * 6 else { return nil }
        seq = b.u16(0)
        hasAnchor = b[3] & 0x01 != 0
        overrunBefore = b[3] & 0x02 != 0
        anchorTicks = b.u32(4)
        anchorMicros = b.u32(8)
        accelIndex = b.u32(12)
        let base = Int64(accelIndex)
        accel = (0..<na * 3).map { b.i16(h + $0 * 2) }
        var o = h + na * 6
        gyro = (0..<ng).map { k in
            let r = o + k * 8
            return (base + Int64(b.i16(r)), b.i16(r + 2), b.i16(r + 4), b.i16(r + 6))
        }
        o += ng * 8
        timestamps = (0..<nt).map { k in
            let r = o + k * 6
            return (base + Int64(b.i16(r)), b.u32(r + 2))
        }
    }
}
