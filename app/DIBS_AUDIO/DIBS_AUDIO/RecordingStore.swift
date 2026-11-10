import AVFoundation
import Foundation

/// One saved session: a folder holding
///   audio.wav          16-bit mono, lost packets filled with silence
///   imu_raw.csv        raw IMU samples with their IMU timestamps
///   imu_anchors.csv    IMU tick <-> session clock pairs from the board
///   audio_anchors.csv  audio.wav sample index <-> session clock pairs
///   imu_aligned.csv    IMU samples in SI units on the audio timeline
///   session.json       board, settings, loss counters and both clock fits
struct Recording: Identifiable, Hashable {
    let folder: URL
    let metadata: SessionMetadata?
    let createdAt: Date

    var id: URL { folder }
    var url: URL { folder.appendingPathComponent("audio.wav") }
    var name: String { folder.lastPathComponent }
    var duration: TimeInterval { metadata?.audio.durationSeconds ?? 0 }

    /// Something in this session needs a look before using the data.
    var hasIssues: Bool {
        guard let m = metadata else { return true }
        return m.audio.lostPackets + m.audio.droppedOnBoard > 0
            || m.imu.lostPackets + m.imu.droppedOnBoard + m.imu.overruns > 0
            || m.imu.i2cErrors > 0
            || m.imuClockFit == nil || m.audioClockFit == nil
            || (m.imuClockFit?.residualRMSMicros ?? 0) > 200
            || (m.audioClockFit?.residualRMSMicros ?? 0) > 200
    }

    static func == (a: Recording, b: Recording) -> Bool { a.folder == b.folder }
    func hash(into h: inout Hasher) { h.combine(folder) }
}

extension Recording {
    /// The session folder zipped into the temporary directory, for sharing.
    nonisolated static func zip(_ folder: URL) throws -> URL {
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading,
                                       error: &coordinationError) { zipped in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(folder.lastPathComponent + ".zip")
            result = Result {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipped, to: dest)
                return dest
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}

struct SessionMetadata: Codable {
    struct Audio: Codable {
        /// Measured by the audio clock fit (nominal if it failed).
        var sampleRateHz: Double
        var nominalSampleRateHz: Double
        var wavSampleRateHz: Int
        var t0SessionMicros: UInt32
        var skipSamples: Int
        var samples: Int
        var receivedPackets: Int
        var lostPackets: Int
        var droppedOnBoard: Int
        var durationSeconds: Double
    }

    struct IMU: Codable {
        var odrHz: Int
        var accelRangeG: Int
        var gyroRangeDPS: Int
        var accelMicroGPerLSB: Int
        var gyroMilliDPSPerLSB: Int
        var freqFine: Int
        var samples: Int
        var packets: Int
        var lostPackets: Int
        var droppedOnBoard: Int
        var overruns: Int
        var i2cErrors: Int
    }

    var formatVersion = 1
    var startedAt: Date
    var endedAt: Date
    var boardID: String
    /// Advertised name, "DIBS_Audio-XXXX" (absent in sessions saved before it).
    var boardName: String?
    var firmwareVersion: String
    var resetReason: String
    var sessionID: String
    var endReason: String
    var audio: Audio
    var imu: IMU
    /// session_us = offset + slope * audio.wav sample index
    var audioClockFit: SessionAligner.Fit?
    /// session_us = offset + slope * IMU tick (unwrapped from the first tick)
    var imuClockFit: SessionAligner.Fit?
    /// Constant delay between the microphone and IMU paths, to be measured
    /// with a tap test and subtracted from imu_aligned.csv times.
    var fixedDelayCorrectionMs = 0.0
}

/// Sessions in Documents/Sessions, one folder each.
@Observable
final class RecordingStore {
    private(set) var recordings: [Recording] = []

    let directory: URL

    init(directory: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? docs.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        recordings = folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { folder in
                let metadata = (try? Data(contentsOf: folder.appendingPathComponent("session.json")))
                    .flatMap { try? decoder.decode(SessionMetadata.self, from: $0) }
                let created = metadata?.startedAt
                    ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
                return Recording(folder: folder, metadata: metadata, createdAt: created)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ capture: DIBSBLEManager.Capture) throws -> Recording {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = directory.appendingPathComponent("DIBS \(formatter.string(from: capture.startedAt))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let status = capture.status
        var audioFit: SessionAligner.Fit?
        var imuFit: SessionAligner.Fit?
        var rate = status?.nominalSampleRate ?? 16000
        if let status {
            let aligner = SessionAligner(status: status, audioAnchors: capture.audioAnchors,
                                         packets: capture.imuPackets)
            audioFit = aligner.audioFit()
            imuFit = aligner.imuFit()
            rate = aligner.sampleRate(audioFit)
            try Self.rawCSV(capture.imuPackets).write(
                to: folder.appendingPathComponent("imu_raw.csv"), atomically: true, encoding: .utf8)
            try Self.imuAnchorsCSV(capture.imuPackets).write(
                to: folder.appendingPathComponent("imu_anchors.csv"), atomically: true, encoding: .utf8)
            try Self.audioAnchorsCSV(capture.audioAnchors).write(
                to: folder.appendingPathComponent("audio_anchors.csv"), atomically: true,
                encoding: .utf8)
            if let imuFit {
                try Self.alignedCSV(aligner.alignedSamples(imu: imuFit, audio: audioFit),
                                    status: status).write(
                    to: folder.appendingPathComponent("imu_aligned.csv"), atomically: true,
                    encoding: .utf8)
            }
        }
        try WAVWriter.data(samples: capture.samples, sampleRate: Int(rate.rounded()))
            .write(to: folder.appendingPathComponent("audio.wav"))

        let metadata = SessionMetadata(
            startedAt: capture.startedAt,
            endedAt: Date(),
            boardID: status.map { String(format: "%016llX", $0.boardID) } ?? "unknown",
            boardName: capture.boardName,
            firmwareVersion: status.map { "\($0.firmwareVersion >> 8).\($0.firmwareVersion & 0xFF)" } ?? "unknown",
            resetReason: status.map { String(format: "0x%08X", $0.resetReason) } ?? "unknown",
            sessionID: status.map { String(format: "%08X", $0.sessionID) } ?? "unknown",
            endReason: status.map { "\($0.endReason)" } ?? "unknown",
            audio: .init(sampleRateHz: rate,
                         nominalSampleRateHz: status?.nominalSampleRate ?? 0,
                         wavSampleRateHz: Int(rate.rounded()),
                         t0SessionMicros: status?.audioT0us ?? 0,
                         skipSamples: status?.audioSkipSamples ?? 0,
                         samples: capture.samples.count, receivedPackets: capture.receivedPackets,
                         lostPackets: capture.lostPackets,
                         droppedOnBoard: status?.audioDroppedPackets ?? 0,
                         durationSeconds: Double(capture.samples.count) / rate),
            imu: .init(odrHz: status?.imuODRHz ?? 0,
                       accelRangeG: Int((Double(status?.accelMicroGPerLSB ?? 0) * 32768 / 1e6).rounded()),
                       gyroRangeDPS: Self.gyroRange[status?.gyroMilliDPSPerLSB ?? 0] ?? 0,
                       accelMicroGPerLSB: status?.accelMicroGPerLSB ?? 0,
                       gyroMilliDPSPerLSB: status?.gyroMilliDPSPerLSB ?? 0,
                       freqFine: Int(status?.imuFreqFine ?? 0),
                       samples: capture.imuSampleCount, packets: capture.imuPackets.count,
                       lostPackets: capture.imuLostPackets,
                       droppedOnBoard: status?.imuDroppedPackets ?? 0,
                       overruns: status?.imuOverruns ?? 0,
                       i2cErrors: status?.imuI2CErrors ?? 0),
            audioClockFit: audioFit,
            imuClockFit: imuFit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: folder.appendingPathComponent("session.json"))

        reload()
        return recordings.first { $0.folder == folder }
            ?? Recording(folder: folder, metadata: metadata, createdAt: capture.startedAt)
    }

    /// LSM6DSV gyroscope sensitivity (mdps/LSB, integer part) to full scale.
    private static let gyroRange = [4: 125, 8: 250, 17: 500, 35: 1000, 70: 2000, 140: 4000]

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.folder)
        reload()
    }

    private static func rawCSV(_ packets: [IMUPacket]) -> String {
        var s = "packet_seq,sample,overrun_before,imu_ticks,ax,ay,az,gx,gy,gz\n"
        for p in packets {
            for (k, x) in p.samples.enumerated() {
                s += "\(p.seq),\(k),\(p.overrunBefore && k == 0 ? 1 : 0),\(x.ticks),"
                s += "\(x.accel.0),\(x.accel.1),\(x.accel.2),\(x.gyro.0),\(x.gyro.1),\(x.gyro.2)\n"
            }
        }
        return s
    }

    private static func imuAnchorsCSV(_ packets: [IMUPacket]) -> String {
        var s = "packet_seq,imu_ticks,session_us\n"
        for p in packets where p.hasAnchor {
            s += "\(p.seq),\(p.anchorTicks),\(p.anchorMicros)\n"
        }
        return s
    }

    private static func audioAnchorsCSV(_ anchors: [SessionAligner.AudioAnchor]) -> String {
        var s = "wav_index,session_us\n"
        for a in anchors {
            s += "\(a.wavIndex),\(a.micros)\n"
        }
        return s
    }

    private static func alignedCSV(_ samples: [SessionAligner.AlignedSample], status: DIBSStatus) -> String {
        let g = 9.80665
        let accel = Double(status.accelMicroGPerLSB) * 1e-6 * g
        let gyro = Double(status.gyroMilliDPSPerLSB) * 1e-3 * .pi / 180
        var s = "time_s,audio_index,ax_mps2,ay_mps2,az_mps2,gx_rads,gy_rads,gz_rads\n"
        for x in samples {
            s += String(format: "%.6f,%.1f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f\n", x.time, x.audioIndex,
                        Double(x.accel.0) * accel, Double(x.accel.1) * accel, Double(x.accel.2) * accel,
                        Double(x.gyro.0) * gyro, Double(x.gyro.1) * gyro, Double(x.gyro.2) * gyro)
        }
        return s
    }
}

enum WAVWriter {
    /// 16-bit mono PCM WAV.
    static func data(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                              // PCM
        u16(1)                              // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))         // byte rate
        u16(2)                              // block align
        u16(16)                             // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        samples.withUnsafeBufferPointer { buf in
            for s in buf { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }
}
