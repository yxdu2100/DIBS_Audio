import AVFoundation
import Foundation

/// One saved session: a folder holding
///   audio.wav          16-bit mono, lost packets filled with silence
///   imu_raw.csv        raw IMU samples with their IMU timestamps (standard mode)
///   imu_anchors.csv    IMU tick <-> session clock pairs from the board
///   audio_anchors.csv  audio.wav sample index <-> session clock pairs
///   imu_aligned.csv    IMU samples in SI units on the audio timeline (in
///                      high-rate mode one row per gyroscope sample, with the
///                      accel sample of the same FIFO slot)
///   session.json       board, settings, loss counters and both clock fits
/// and in high-rate mode also
///   imu_accel.wav      every accel sample, 3 channels (x, y, z) of raw
///                      16-bit LSB, at the measured rate; lost packets zeros
///   imu_accel_timestamps.csv  FIFO timestamps: accel index, IMU ticks
///   imu_accel_timeline.csv    accel index -> session/audio time, piecewise
///                      linear (np.interp over it gives every sample's time)
///   imu_gyro_raw.csv   raw gyroscope samples with their accel index
///   imu_fifo_overruns.csv  first accel index after each FIFO overrun (if any)
///   rssi.csv           signal strength at the phone about once a second, with
///                      how many audio/accel samples had arrived by then
///
/// The raw files are written while recording (CaptureSpool); a folder that
/// still holds an INCOMPLETE file was interrupted (app killed or crashed) and
/// has the raw files up to the last flush but no session.json.
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
            || m.imuClockFit == nil
            || (m.imu.mode?.hasAudio ?? true) && m.audioClockFit == nil
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
        /// "standard" or "highRate" (absent before format 2: standard).
        var mode: IMUMode?
        /// Accelerometer ODR, nominal.
        var odrHz: Int
        var accelRangeG: Int
        var gyroRangeDPS: Int
        var accelMicroGPerLSB: Int
        var gyroMilliDPSPerLSB: Int
        var freqFine: Int
        /// Accelerometer samples received.
        var samples: Int
        var packets: Int
        var lostPackets: Int
        var droppedOnBoard: Int
        var overruns: Int
        var i2cErrors: Int
        var gyroODRHz: Int?
        var accelPerTimestamp: Int?
        /// High-rate: measured accel rate, and the rate written in imu_accel.wav.
        var accelSampleRateHz: Double?
        var accelWavSampleRateHz: Int?
        /// High-rate: accel samples zero-filled for lost packets.
        var missingAccelSamples: Int?
        /// High-rate: accel index -> IMU ticks (slope = ticks per sample).
        var accelTimestampFit: SessionAligner.Fit?
        var accelTimestampsRejected: Int?
    }

    var formatVersion = 2
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
    struct RSSI: Codable {
        var readings: Int
        var medianDBm: Int
        var minDBm: Int
        var maxDBm: Int
    }

    /// Radio PHY asked for, and the one the board reported in use ("1M",
    /// "2M"; absent when unknown).
    var blePHYRequested: String?
    var blePHY: String?
    /// Signal strength at the phone during the session (rssi.csv).
    var rssi: RSSI?
    /// Constant delay between the microphone and IMU paths, to be measured
    /// with a tap test and subtracted from imu_aligned.csv times.
    var fixedDelayCorrectionMs = 0.0
}

/// Sessions in Documents/Sessions, one folder each.
@Observable
final class RecordingStore {
    private(set) var recordings: [Recording] = []

    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    /// "DIBS yyyy-MM-dd HH.mm.ss" from the session start.
    static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "DIBS \(formatter.string(from: date))"
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
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
        // The raw streams are already on disk; this finishes the WAV headers
        // and adds the fits and the aligned files.
        let spool = capture.spool
        let folder = spool.folder
        spool.closeTexts()

        let status = capture.status
        var audioFit: SessionAligner.Fit?
        var imuFit: SessionAligner.Fit?
        var rate = status?.nominalSampleRate ?? 16000
        var hr: HighRateResult?
        if let status {
            let aligner = capture.imuMode.isHighRate
                ? SessionAligner(status: status, audioAnchors: capture.audioAnchors,
                                 imuAnchors: capture.hrAnchors.map { ($0.ticks, $0.micros) })
                : SessionAligner(status: status, audioAnchors: capture.audioAnchors,
                                 packets: capture.imuPackets)
            audioFit = aligner.audioFit()
            imuFit = aligner.imuFit()
            rate = aligner.sampleRate(audioFit)
            if capture.imuMode.isHighRate {
                hr = try Self.saveHighRate(capture, status: status, aligner: aligner,
                                           imuFit: imuFit, audioFit: audioFit, folder: folder)
            } else if let imuFit {
                try Self.writeAlignedCSV(aligner.alignedSamples(imu: imuFit, audio: audioFit),
                                         status: status,
                                         to: folder.appendingPathComponent("imu_aligned.csv"))
            }
        }
        spool.audio?.finish(sampleRate: Int(rate.rounded()))
        spool.accel?.finish(sampleRate: hr?.wavRate ?? status?.imuODRHz ?? 3840)
        // Without audio the session lasts as long as the accel stream.
        let duration = capture.imuMode.hasAudio
            ? Double(capture.audioSampleCount) / rate
            : Double(capture.hrAccelCount) / (hr?.accelRate ?? Double(status?.imuODRHz ?? 3840))

        let audioMeta = SessionMetadata.Audio(
            sampleRateHz: rate,
            nominalSampleRateHz: status?.nominalSampleRate ?? 0,
            wavSampleRateHz: Int(rate.rounded()),
            t0SessionMicros: status?.audioT0us ?? 0,
            skipSamples: status?.audioSkipSamples ?? 0,
            samples: capture.audioSampleCount, receivedPackets: capture.receivedPackets,
            lostPackets: capture.lostPackets,
            droppedOnBoard: status?.audioDroppedPackets ?? 0,
            durationSeconds: duration)
        let accelUgLSB: Int = status?.accelMicroGPerLSB ?? 0
        let gyroMdpsLSB: Int = status?.gyroMilliDPSPerLSB ?? 0
        var imuMeta = SessionMetadata.IMU(
            mode: capture.imuMode,
            odrHz: status?.imuODRHz ?? 0,
            accelRangeG: Int((Double(accelUgLSB) * 32768 / 1e6).rounded()),
            gyroRangeDPS: Self.gyroRange[gyroMdpsLSB] ?? 0,
            accelMicroGPerLSB: accelUgLSB,
            gyroMilliDPSPerLSB: gyroMdpsLSB,
            freqFine: Int(status?.imuFreqFine ?? 0),
            samples: capture.imuSampleCount, packets: capture.imuReceivedPackets,
            lostPackets: capture.imuLostPackets,
            droppedOnBoard: status?.imuDroppedPackets ?? 0,
            overruns: status?.imuOverruns ?? 0,
            i2cErrors: status?.imuI2CErrors ?? 0)
        imuMeta.gyroODRHz = status?.gyroODRHz
        imuMeta.accelPerTimestamp = status?.imuAccelPerTimestamp
        if let hr {
            imuMeta.accelSampleRateHz = hr.accelRate
            imuMeta.accelWavSampleRateHz = hr.wavRate
            imuMeta.missingAccelSamples = capture.hrMissingAccel
            imuMeta.accelTimestampFit = hr.timeline.fit
            imuMeta.accelTimestampsRejected = hr.timeline.rejected
        }
        var metadata = SessionMetadata(
            startedAt: capture.startedAt,
            endedAt: Date(),
            boardID: status.map { String(format: "%016llX", $0.boardID) } ?? "unknown",
            boardName: capture.boardName,
            firmwareVersion: status.map { "\($0.firmwareVersion >> 8).\($0.firmwareVersion & 0xFF)" } ?? "unknown",
            resetReason: status.map { String(format: "0x%08X", $0.resetReason) } ?? "unknown",
            sessionID: status.map { String(format: "%08X", $0.sessionID) } ?? "unknown",
            endReason: status.map { "\($0.endReason)" } ?? "unknown",
            audio: audioMeta,
            imu: imuMeta,
            audioClockFit: audioFit,
            imuClockFit: imuFit)
        metadata.blePHYRequested = capture.phy.name
        metadata.blePHY = status.flatMap { RadioPHY(rawValue: $0.phy) }?.name
        let rssi = capture.rssi.sorted()
        if let lo = rssi.first, let hi = rssi.last {
            metadata.rssi = SessionMetadata.RSSI(readings: rssi.count, medianDBm: rssi[rssi.count / 2],
                                                 minDBm: lo, maxDBm: hi)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: folder.appendingPathComponent("session.json"))
        spool.markComplete()

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

    struct HighRateResult {
        var timeline: AccelTimeline
        var accelRate: Double?
        var wavRate: Int
    }

    private static func saveHighRate(_ c: DIBSBLEManager.Capture, status: DIBSStatus,
                                     aligner: SessionAligner, imuFit: SessionAligner.Fit?,
                                     audioFit: SessionAligner.Fit?, folder: URL) throws -> HighRateResult {
        let count = Int64(c.hrAccelCount)
        let timeline = AccelTimeline(timestamps: c.hrTimestamps, overruns: c.hrOverruns, count: count)
        var accelRate: Double?
        if let tps = timeline.ticksPerSample, let imuFit {
            accelRate = 1e6 / (tps * imuFit.slopeMicrosPerCount)
        }
        let wavRate = Int((accelRate ?? Double(status.imuODRHz)).rounded())
        // imu_accel.wav, the timestamps, anchors and gyro were written while
        // recording.
        c.spool.accel?.finish(sampleRate: wavRate)

        if let imuFit {
            let clock = aligner.tickClock(imuFit)
            let tl = try TextStream(url: folder.appendingPathComponent("imu_accel_timeline.csv"),
                                    header: "accel_index,measured,imu_ticks,session_us,time_s,audio_index\n")
            for p in timeline.points {
                let us = clock.micros(at: p.ticks)
                let t = aligner.audioTime(micros: us, audio: audioFit)
                tl.append(String(format: "%lld,%d,%.2f,%.2f,%.7f,%.2f\n", p.accelIndex,
                                 p.measured ? 1 : 0, p.ticks, us, t.time, t.index))
            }
            tl.close()

            // Gyro-rate summary in the standard columns (chart, tap_check),
            // with the accel sample at each gyro sample's index (mapped from
            // imu_accel.wav, not held in memory).
            let g = 9.80665
            let accel = Double(status.accelMicroGPerLSB) * 1e-6 * g
            let gyro = Double(status.gyroMilliDPSPerLSB) * 1e-3 * .pi / 180
            let wav = try Data(contentsOf: folder.appendingPathComponent("imu_accel.wav"),
                               options: .alwaysMapped)
            let frames = Int64(max(wav.count - 44, 0) / 6)
            let out = try TextStream(url: folder.appendingPathComponent("imu_aligned.csv"),
                                     header: "time_s,audio_index,ax_mps2,ay_mps2,az_mps2,gx_rads,gy_rads,gz_rads,accel_index\n")
            wav.withUnsafeBytes { raw in
                func a(_ i: Int) -> Double {
                    Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 44 + i * 2,
                                                                  as: Int16.self))) * accel
                }
                for x in c.hrGyro {
                    guard x.accelIndex >= 0, x.accelIndex < min(count, frames),
                          let ticks = timeline.ticks(at: x.accelIndex) else { continue }
                    let t = aligner.audioTime(micros: clock.micros(at: ticks), audio: audioFit)
                    let i = Int(x.accelIndex) * 3
                    out.append(String(format: "%.6f,%.1f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%lld\n",
                                      t.time, t.index, a(i), a(i + 1), a(i + 2), Double(x.x) * gyro,
                                      Double(x.y) * gyro, Double(x.z) * gyro, x.accelIndex))
                }
            }
            out.close()
        }
        return HighRateResult(timeline: timeline, accelRate: accelRate, wavRate: wavRate)
    }

    static let rawCSVHeader = "packet_seq,sample,overrun_before,imu_ticks,ax,ay,az,gx,gy,gz\n"
    static let imuAnchorsHeader = "packet_seq,imu_ticks,session_us\n"

    /// imu_raw.csv rows of one standard-mode packet.
    static func rawCSVRows(_ p: IMUPacket) -> String {
        var s = ""
        for (k, x) in p.samples.enumerated() {
            s += "\(p.seq),\(k),\(p.overrunBefore && k == 0 ? 1 : 0),\(x.ticks),"
            s += "\(x.accel.0),\(x.accel.1),\(x.accel.2),\(x.gyro.0),\(x.gyro.1),\(x.gyro.2)\n"
        }
        return s
    }

    private static func writeAlignedCSV(_ samples: [SessionAligner.AlignedSample], status: DIBSStatus,
                                        to url: URL) throws {
        let g = 9.80665
        let accel = Double(status.accelMicroGPerLSB) * 1e-6 * g
        let gyro = Double(status.gyroMilliDPSPerLSB) * 1e-3 * .pi / 180
        let out = try TextStream(url: url,
                                 header: "time_s,audio_index,ax_mps2,ay_mps2,az_mps2,gx_rads,gy_rads,gz_rads\n")
        for x in samples {
            out.append(String(format: "%.6f,%.1f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f\n", x.time, x.audioIndex,
                              Double(x.accel.0) * accel, Double(x.accel.1) * accel, Double(x.accel.2) * accel,
                              Double(x.gyro.0) * gyro, Double(x.gyro.1) * gyro, Double(x.gyro.2) * gyro))
        }
        out.close()
    }
}

enum WAVWriter {
    /// 16-bit PCM WAV; `samples` interleaved when `channels` > 1.
    static func data(samples: [Int16], sampleRate: Int, channels: Int = 1) -> Data {
        var d = header(dataBytes: samples.count * 2, sampleRate: sampleRate, channels: channels)
        d.reserveCapacity(d.count + samples.count * 2)
        // Int16 is little-endian on every Apple platform.
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// The 44-byte header of a 16-bit PCM WAV with `dataBytes` of samples.
    static func header(dataBytes: Int, sampleRate: Int, channels: Int) -> Data {
        let dataSize = UInt32(clamping: dataBytes)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8)); u32(36 &+ dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                              // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2 * channels))  // byte rate
        u16(UInt16(2 * channels))               // block align
        u16(16)                             // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        return d
    }
}
