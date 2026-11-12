import Foundation

/// Puts audio and IMU samples on one timeline.
///
/// The board stamps both streams with its session clock (microseconds from
/// the 32 MHz crystal): every 20 ms audio buffer with the moment the
/// microphone finished it, and the IMU's own timestamp counter with the
/// moment it was read. A least-squares line per stream converts sample
/// positions to session time, so neither the microphone's sample rate nor the
/// IMU's oscillator has to be known in advance; the fits measure them.
///
/// The IMU's RC oscillator also wanders slowly (about +-150 us around the
/// line over 40 s), so IMU samples are placed by interpolating between the
/// two anchors around them (one every ~120 ms); the line only rejects bad
/// anchors and extends past the first and last.
struct SessionAligner {
    /// session_us = offset + slope * count (count unwrapped).
    struct Fit: Codable {
        var offsetMicros: Double
        var slopeMicrosPerCount: Double
        var pointsUsed: Int
        var pointsRejected: Int
        var residualRMSMicros: Double
        var residualMaxMicros: Double

        func micros(at count: Double) -> Double { offsetMicros + slopeMicrosPerCount * count }
        func count(at micros: Double) -> Double { (micros - offsetMicros) / slopeMicrosPerCount }
    }

    struct AlignedSample {
        /// Seconds from the first sample in audio.wav.
        var time: Double
        /// Position in audio.wav, in samples.
        var audioIndex: Double
        var packetSeq: UInt16
        var ticks: UInt64
        var accel: (Int16, Int16, Int16)
        var gyro: (Int16, Int16, Int16)
    }

    /// (index in audio.wav of the last sample of a buffer, session time).
    typealias AudioAnchor = (wavIndex: Int, micros: UInt32)

    let status: DIBSStatus
    let audioAnchors: [AudioAnchor]
    /// Standard mode packets (empty in high-rate mode).
    let packets: [IMUPacket]
    /// IMU tick <-> session microsecond pairs read on the board.
    let imuAnchors: [(ticks: UInt32, micros: UInt32)]

    init(status: DIBSStatus, audioAnchors: [AudioAnchor], packets: [IMUPacket]) {
        self.status = status
        self.audioAnchors = audioAnchors
        self.packets = packets
        imuAnchors = packets.filter(\.hasAnchor).map { ($0.anchorTicks, $0.anchorMicros) }
    }

    init(status: DIBSStatus, audioAnchors: [AudioAnchor],
         imuAnchors: [(ticks: UInt32, micros: UInt32)]) {
        self.status = status
        self.audioAnchors = audioAnchors
        self.packets = []
        self.imuAnchors = imuAnchors
    }

    /// Audio samples per second measured by the audio fit.
    func sampleRate(_ audio: Fit?) -> Double {
        audio.map { 1e6 / $0.slopeMicrosPerCount } ?? status.nominalSampleRate
    }

    /// An anchor read late on the board lands a block (20 ms) or a
    /// preempted I2C read (> 0.4 ms) off the line.
    func audioFit() -> Fit? {
        var micros = Unwrapper()
        let points = audioAnchors.map { (Double($0.wavIndex), Double(micros.next($0.micros))) }
        return Self.fit(points, outlierMicros: 1000)
    }

    static let imuOutlierMicros = 500.0

    func imuFit() -> Fit? {
        Self.fit(imuPoints(), outlierMicros: Self.imuOutlierMicros)
    }

    private func imuPoints() -> [(Double, Double)] {
        var ticks = Unwrapper()
        var micros = Unwrapper()
        return imuAnchors.map {
            (Double(ticks.next($0.ticks)), Double(micros.next($0.micros)))
        }
    }

    /// Session microseconds of an (unwrapped) IMU tick: interpolated between
    /// the good anchors around it, along the fit line's slope outside them.
    struct TickClock {
        let anchors: [(Double, Double)]
        let fit: Fit

        func micros(at x: Double) -> Double {
            guard let first = anchors.first, let last = anchors.last else {
                return fit.micros(at: x)
            }
            if x <= first.0 { return first.1 + fit.slopeMicrosPerCount * (x - first.0) }
            if x >= last.0 { return last.1 + fit.slopeMicrosPerCount * (x - last.0) }
            var lo = 0, hi = anchors.count - 1  // anchors[lo].0 < x <= anchors[hi].0
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if anchors[mid].0 < x { lo = mid } else { hi = mid }
            }
            let (x0, y0) = anchors[lo], (x1, y1) = anchors[hi]
            return x1 > x0 ? y0 + (y1 - y0) * (x - x0) / (x1 - x0) : y0
        }
    }

    func tickClock(_ imu: Fit) -> TickClock {
        let good = imuPoints().filter {
            abs($0.1 - imu.micros(at: $0.0)) <= Self.imuOutlierMicros
        }
        return TickClock(anchors: good.sorted { $0.0 < $1.0 }, fit: imu)
    }

    /// Session microseconds -> (seconds from the first audio.wav sample,
    /// position in audio.wav).
    /// Without a microphone (IMU-only mode): seconds on the session clock
    /// (from the session start) and index -1.
    func audioTime(micros: Double, audio: Fit?) -> (time: Double, index: Double) {
        if !status.imuMode.hasAudio { return (micros / 1e6, -1) }
        let rate = sampleRate(audio)
        // Without audio anchors fall back to the PDM start and nominal rate.
        let startMicros = Double(status.audioT0us)
            + Double(status.audioSkipSamples) * 1e6 / status.nominalSampleRate
        let index = audio?.count(at: micros) ?? (micros - startMicros) * rate / 1e6
        return (index / rate, index)
    }

    func alignedSamples(imu: Fit, audio: Fit?) -> [AlignedSample] {
        let clock = tickClock(imu)
        var ticks = Unwrapper()
        var out: [AlignedSample] = []
        out.reserveCapacity(packets.reduce(0) { $0 + $1.samples.count })
        for p in packets {
            for s in p.samples {
                let tick = ticks.next(s.ticks)
                let t = audioTime(micros: clock.micros(at: Double(tick)), audio: audio)
                out.append(AlignedSample(time: t.time, audioIndex: t.index, packetSeq: p.seq,
                                         ticks: tick, accel: s.accel, gyro: s.gyro))
            }
        }
        return out
    }

    /// Least squares with up to three rounds of outlier removal.
    static func fit(_ points: [(Double, Double)], outlierMicros: Double) -> Fit? {
        guard points.count >= 2 else { return nil }
        var used = points
        var line = leastSquares(used)
        for _ in 0..<3 {
            let kept = used.filter { abs($0.1 - (line.a + line.b * $0.0)) <= outlierMicros }
            guard kept.count >= 2, kept.count != used.count else { break }
            used = kept
            line = leastSquares(used)
        }
        let residuals = used.map { $0.1 - (line.a + line.b * $0.0) }
        let rms = (residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count)).squareRoot()
        return Fit(offsetMicros: line.a, slopeMicrosPerCount: line.b, pointsUsed: used.count,
                   pointsRejected: points.count - used.count, residualRMSMicros: rms,
                   residualMaxMicros: residuals.map(abs).max() ?? 0)
    }

    private static func leastSquares(_ pts: [(Double, Double)]) -> (a: Double, b: Double) {
        // Center first: the counts and microsecond values are large.
        let n = Double(pts.count)
        let mx = pts.map(\.0).reduce(0, +) / n
        let my = pts.map(\.1).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for p in pts {
            sxx += (p.0 - mx) * (p.0 - mx)
            sxy += (p.0 - mx) * (p.1 - my)
        }
        let b = sxx > 0 ? sxy / sxx : 0
        return (my - b * mx, b)
    }
}

/// Extends a wrapping 32-bit counter to 64 bits; values must arrive in order
/// and less than half a wrap apart.
struct Unwrapper {
    private var last: UInt32?
    private var high: UInt64 = 0

    mutating func next(_ v: UInt32) -> UInt64 {
        if let last, v < last, last &- v > UInt32.max / 2 { high += 1 << 32 }
        last = v
        return high | UInt64(v)
    }
}

/// High-rate mode: the FIFO stores an IMU timestamp only every N accel
/// samples, so accel sample k gets its IMU tick by interpolating between the
/// timestamps around it. Index and timestamp both count the IMU's own
/// oscillator, so between timestamps this is exact. A FIFO overrun loses an
/// unknown number of samples: the map is split there into segments, each
/// extended to its first and last sample with the session's ticks-per-sample
/// slope. Lost BLE packets keep the numbering (their samples are zeros in
/// imu_accel.wav) and only thin out the timestamps.
struct AccelTimeline {
    /// One point of the piecewise-linear index -> tick map.
    struct Point {
        var accelIndex: Int64
        var ticks: Double
        /// A FIFO timestamp, or an extrapolated segment end.
        var measured: Bool
    }

    /// accel index -> ticks over the longest segment ("micros" = ticks here).
    let fit: SessionAligner.Fit?
    let points: [Point]
    /// Timestamps more than 3 ticks off their segment's line.
    let rejected: Int

    /// Ticks per accel sample, if the fit worked.
    var ticksPerSample: Double? { fit?.slopeMicrosPerCount }

    /// `count`: accel samples in the session; `overruns`: index of the first
    /// sample after each FIFO overrun.
    init(timestamps: [(accelIndex: Int64, ticks: UInt32)], overruns: [Int64], count: Int64) {
        var unwrap = Unwrapper()
        let raw = timestamps.map { (Double($0.accelIndex), Double(unwrap.next($0.ticks))) }
        var bounds: [Int64] = [0]
        bounds += overruns.filter { $0 > 0 && $0 < count }.sorted()
        bounds.append(max(count, 1))
        var segments: [(lo: Int64, hi: Int64, ts: [(Double, Double)])] = []
        for i in 0..<(bounds.count - 1) where bounds[i + 1] > bounds[i] {
            let lo = bounds[i], hi = bounds[i + 1]
            let ts = raw.filter { $0.0 >= Double(lo) && $0.0 < Double(hi) }
            segments.append((lo, hi - 1, ts))
        }
        // Slope from the longest segment (a fit across a break would bend).
        let main = segments.max { $0.ts.count < $1.ts.count }?.ts ?? []
        fit = SessionAligner.fit(main, outlierMicros: 3)
        guard let slope = fit?.slopeMicrosPerCount else {
            points = []
            rejected = 0
            return
        }
        var pts: [Point] = []
        var bad = 0
        for seg in segments where !seg.ts.isEmpty {
            let offsets = seg.ts.map { $0.1 - slope * $0.0 }.sorted()
            let median = offsets[offsets.count / 2]
            let good = seg.ts.filter { abs($0.1 - slope * $0.0 - median) <= 3 }
            bad += seg.ts.count - good.count
            guard let first = good.first, let last = good.last else { continue }
            if Double(seg.lo) < first.0 {
                pts.append(Point(accelIndex: seg.lo, ticks: first.1 - slope * (first.0 - Double(seg.lo)),
                                 measured: false))
            }
            pts += good.map { Point(accelIndex: Int64($0.0), ticks: $0.1, measured: true) }
            if Double(seg.hi) > last.0 {
                pts.append(Point(accelIndex: seg.hi, ticks: last.1 + slope * (Double(seg.hi) - last.0),
                                 measured: false))
            }
        }
        points = pts
        rejected = bad
    }

    /// IMU tick (unwrapped) of accel sample `k`.
    func ticks(at k: Int64) -> Double? {
        guard let slope = ticksPerSample, let first = points.first, let last = points.last
        else { return nil }
        if k <= first.accelIndex { return first.ticks - slope * Double(first.accelIndex - k) }
        if k >= last.accelIndex { return last.ticks + slope * Double(k - last.accelIndex) }
        var lo = 0, hi = points.count - 1  // points[lo] < k <= points[hi]
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].accelIndex < k { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        return a.ticks + (b.ticks - a.ticks) * Double(k - a.accelIndex)
            / Double(b.accelIndex - a.accelIndex)
    }
}
