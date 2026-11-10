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
    let packets: [IMUPacket]

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
        return packets.filter(\.hasAnchor).map {
            (Double(ticks.next($0.anchorTicks)), Double(micros.next($0.anchorMicros)))
        }
    }

    func alignedSamples(imu: Fit, audio: Fit?) -> [AlignedSample] {
        let rate = sampleRate(audio)
        // Without audio anchors fall back to the PDM start and nominal rate.
        let startMicros = Double(status.audioT0us)
            + Double(status.audioSkipSamples) * 1e6 / status.nominalSampleRate
        let anchors = imuPoints().filter {
            abs($0.1 - imu.micros(at: $0.0)) <= Self.imuOutlierMicros
        }
        var ticks = Unwrapper()
        var next = 0  // first anchor after the current sample
        var out: [AlignedSample] = []
        out.reserveCapacity(packets.reduce(0) { $0 + $1.samples.count })
        for p in packets {
            for s in p.samples {
                let tick = ticks.next(s.ticks)
                let x = Double(tick)
                while next < anchors.count, anchors[next].0 <= x { next += 1 }
                let micros: Double
                if next == 0 || next == anchors.count {
                    // Before the first or after the last anchor: slope of the
                    // line through the nearest anchor.
                    let a = anchors.isEmpty ? nil : anchors[next == 0 ? 0 : anchors.count - 1]
                    micros = a.map { $0.1 + imu.slopeMicrosPerCount * (x - $0.0) }
                        ?? imu.micros(at: x)
                } else {
                    let (x0, y0) = anchors[next - 1], (x1, y1) = anchors[next]
                    micros = y0 + (y1 - y0) * (x - x0) / (x1 - x0)
                }
                let index = audio?.count(at: micros) ?? (micros - startMicros) * rate / 1e6
                out.append(AlignedSample(time: index / rate, audioIndex: index, packetSeq: p.seq,
                                         ticks: tick, accel: s.accel, gyro: s.gyro))
            }
        }
        return out
    }

    /// Least squares with up to three rounds of outlier removal.
    private static func fit(_ points: [(Double, Double)], outlierMicros: Double) -> Fit? {
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
