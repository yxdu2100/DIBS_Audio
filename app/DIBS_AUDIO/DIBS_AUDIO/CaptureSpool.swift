import Foundation

/// Writes a session to its folder while it records, so a long session does
/// not grow in memory and an app crash or kill loses at most the last flush
/// interval. Samples go to audio.wav / imu_accel.wav, whose headers are
/// patched to the current length at every flush (the files are valid WAVs at
/// any time); the raw CSVs (anchors, timestamps, gyro) are appended too.
///
/// The folder holds an INCOMPLETE marker until the session is saved: a folder
/// that still has it after a crash has all streamed data up to the last flush,
/// but no session.json and no aligned files.
final class CaptureSpool {
    static let flushInterval: TimeInterval = 2
    static let incompleteMarker = "INCOMPLETE"

    let folder: URL
    let audio: WAVStream?
    let accel: WAVStream?
    private var texts: [String: TextStream] = [:]
    private var lastFlush = Date()

    init(folder: URL, mode: IMUMode) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        fm.createFile(atPath: folder.appendingPathComponent(Self.incompleteMarker).path,
                      contents: Data("Recording in progress or interrupted.\n".utf8))
        self.folder = folder
        // Header rates are nominal until the clock fits patch them at save.
        audio = mode.hasAudio
            ? try WAVStream(url: folder.appendingPathComponent("audio.wav"), channels: 1,
                            sampleRate: 16129)
            : nil
        accel = mode.isHighRate
            ? try WAVStream(url: folder.appendingPathComponent("imu_accel.wav"), channels: 3,
                            sampleRate: 3840)
            : nil
    }

    /// The CSV `name`, created with `header` on first use.
    func text(_ name: String, header: String) -> TextStream {
        if let t = texts[name] { return t }
        let t = (try? TextStream(url: folder.appendingPathComponent(name), header: header))
            ?? TextStream.discarding
        texts[name] = t
        return t
    }

    /// Flushes if the last flush is `flushInterval` ago.
    func flushIfDue() {
        if Date().timeIntervalSince(lastFlush) >= Self.flushInterval { flush() }
    }

    func flush() {
        lastFlush = Date()
        audio?.flush()
        accel?.flush()
        for t in texts.values { t.flush() }
    }

    /// Writes everything and closes the streams (the WAVs stay open for
    /// `finish(sampleRate:)`).
    func closeTexts() {
        flush()
        for t in texts.values { t.close() }
    }

    /// The session was saved.
    func markComplete() {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(Self.incompleteMarker))
    }

    /// Nothing worth keeping arrived: removes the folder.
    func discard() {
        audio?.close()
        accel?.close()
        for t in texts.values { t.close() }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// 16-bit PCM WAV written incrementally; samples interleaved by channel.
final class WAVStream {
    let url: URL
    let channels: Int
    private(set) var sampleRate: Int
    /// Frames (samples per channel) appended so far.
    private(set) var frames = 0
    private let handle: FileHandle
    private var pending = Data()
    private var closed = false

    init(url: URL, channels: Int, sampleRate: Int) throws {
        self.url = url
        self.channels = channels
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path,
                                       contents: WAVWriter.header(dataBytes: 0, sampleRate: sampleRate,
                                                                  channels: channels))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        pending.reserveCapacity(64 * 1024)
    }

    func append<C: Collection>(_ samples: C) where C.Element == Int16 {
        for v in samples { withUnsafeBytes(of: v.littleEndian) { pending.append(contentsOf: $0) } }
        frames += samples.count / channels
    }

    func appendZeros(frames n: Int) {
        guard n > 0 else { return }
        pending.append(Data(count: n * channels * 2))
        frames += n
    }

    /// Writes pending samples and updates the header's sizes.
    func flush() {
        guard !closed else { return }
        do {
            if !pending.isEmpty {
                try handle.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
            try writeHeader()
        } catch {
            // Disk full or similar: keep the samples for the next try.
        }
    }

    /// Final flush with the measured rate in the header, then closes.
    func finish(sampleRate: Int) {
        self.sampleRate = sampleRate
        flush()
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    private func writeHeader() throws {
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVWriter.header(dataBytes: frames * channels * 2,
                                                       sampleRate: sampleRate, channels: channels))
        try handle.seek(toOffset: end)
    }
}

/// A text file written incrementally.
final class TextStream {
    private let handle: FileHandle?
    private var pending = ""

    /// Drops what it is given (when the file could not be created).
    static let discarding = TextStream()

    private init() { handle = nil }

    init(url: URL, header: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    func append(_ line: String) {
        guard handle != nil else { return }
        pending += line
        if pending.utf8.count >= 256 * 1024 { flush() }
    }

    func flush() {
        guard let handle, !pending.isEmpty else { return }
        try? handle.write(contentsOf: Data(pending.utf8))
        pending = ""
    }

    func close() {
        flush()
        try? handle?.close()
    }
}
