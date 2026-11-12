import Charts
import SwiftUI

/// One session: playback with the IMU on the same timeline, data quality,
/// and export of the whole folder.
struct SessionDetailView: View {
    let recording: Recording

    @Environment(RecordingStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var motion: [MotionPoint] = []
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                PlaybackChart(recording: recording, motion: motion)
                    .frame(height: 160)
                Button {
                    player.toggle(recording.url)
                } label: {
                    Label(isPlaying ? "Stop" : "Play",
                          systemImage: isPlaying ? "stop.fill" : "play.fill")
                }
            } footer: {
                Text("Acceleration change on the audio timeline (m/s² per sample).")
            }

            if let m = recording.metadata {
                Section("Data") {
                    LabeledContent("Duration", value: Duration.seconds(m.audio.durationSeconds),
                                   format: .time(pattern: .minuteSecond))
                    LabeledContent("Audio", value: String(format: "%.3f Hz, %d samples",
                                                          m.audio.sampleRateHz, m.audio.samples))
                    LabeledContent("IMU", value: "\(m.imu.samples) samples, ±\(m.imu.accelRangeG) g, ±\(m.imu.gyroRangeDPS) dps")
                    if m.imu.mode?.isHighRate == true {
                        LabeledContent("IMU mode", value: String(
                            format: "accel %.1f Hz, gyro %d Hz", m.imu.accelSampleRateHz ?? Double(m.imu.odrHz),
                            m.imu.gyroODRHz ?? 0))
                    }
                    LabeledContent("Board", value: "\(m.boardName ?? m.boardID) · fw \(m.firmwareVersion)")
                    LabeledContent("Ended by", value: m.endReason)
                }

                Section("Quality") {
                    QualityRow("Audio packets lost", m.audio.lostPackets + m.audio.droppedOnBoard)
                    QualityRow("IMU packets lost", m.imu.lostPackets + m.imu.droppedOnBoard)
                    QualityRow("IMU FIFO overruns", m.imu.overruns)
                    QualityRow("IMU read errors", m.imu.i2cErrors)
                    FitRow(title: "Audio clock fit", fit: m.audioClockFit)
                    FitRow(title: "IMU clock fit", fit: m.imuClockFit)
                }
            } else {
                Section {
                    Text("session.json is missing or unreadable.").foregroundStyle(.red)
                }
            }

            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export session (.zip)", systemImage: "square.and.arrow.up")
                    }
                } else if let exportError {
                    Text(exportError).foregroundStyle(.red)
                } else {
                    ProgressView("Preparing export…")
                }
                Button("Delete session", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("All files are also in the Files app under On My iPhone › DIBS_AUDIO › Sessions.")
            }
        }
        .navigationTitle(Text(recording.createdAt, format: .dateTime.month().day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if isPlaying { player.stop() }
                store.delete(recording)
                dismiss()
            }
        } message: {
            Text("Audio, IMU data and metadata are removed from this phone.")
        }
        .task {
            let folder = recording.folder
            motion = await Task.detached { MotionPoint.load(folder) }.value
            do {
                exportURL = try await Task.detached { try Recording.zip(folder) }.value
            } catch {
                exportError = "Export failed: \(error.localizedDescription)"
            }
        }
        .onDisappear { if isPlaying { player.stop() } }
    }

    private var isPlaying: Bool { player.playingURL == recording.url }
}

/// Peak acceleration change per time bin, for drawing.
struct MotionPoint: Identifiable {
    var time: Double
    var value: Double
    var id: Double { time }

    nonisolated static func load(_ folder: URL, bins: Int = 1500) -> [MotionPoint] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("imu_aligned.csv"),
                                     encoding: .utf8) else { return [] }
        var times: [Double] = []
        var change: [Double] = []
        var last: (Double, Double, Double)?
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",")
            guard f.count >= 5, let t = Double(f[0]), let x = Double(f[2]), let y = Double(f[3]),
                  let z = Double(f[4]) else { continue }
            if let l = last {
                times.append(t)
                change.append(((x - l.0) * (x - l.0) + (y - l.1) * (y - l.1) + (z - l.2) * (z - l.2)).squareRoot())
            }
            last = (x, y, z)
        }
        guard let t0 = times.first, let t1 = times.last, t1 > t0 else { return [] }
        let width = (t1 - t0) / Double(bins)
        var peak = [Double](repeating: 0, count: bins)
        for (t, v) in zip(times, change) {
            let i = min(Int((t - t0) / width), bins - 1)
            peak[i] = max(peak[i], v)
        }
        return peak.enumerated().map { MotionPoint(time: t0 + (Double($0.offset) + 0.5) * width, value: $0.element) }
    }
}

private struct PlaybackChart: View {
    let recording: Recording
    let motion: [MotionPoint]
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        TimelineView(.animation(paused: player.playingURL != recording.url)) { _ in
            Chart {
                ForEach(motion) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Change", p.value))
                        .foregroundStyle(.blue)
                }
                if player.playingURL == recording.url {
                    RuleMark(x: .value("Playhead", player.currentTime))
                        .foregroundStyle(.red)
                }
            }
            .chartXScale(domain: 0...max(recording.duration, 0.1))
            .chartXAxisLabel("s")
        }
        .overlay {
            if motion.isEmpty { Text("No IMU data").foregroundStyle(.secondary) }
        }
    }
}

private struct QualityRow: View {
    let title: String
    let count: Int

    init(_ title: String, _ count: Int) {
        self.title = title
        self.count = count
    }

    var body: some View {
        LabeledContent(title) {
            Text("\(count)").foregroundStyle(count > 0 ? .orange : .secondary)
        }
    }
}

private struct FitRow: View {
    let title: String
    let fit: SessionAligner.Fit?

    var body: some View {
        LabeledContent(title) {
            if let fit {
                Text(String(format: "rms %.0f µs, %d/%d points", fit.residualRMSMicros,
                            fit.pointsUsed, fit.pointsUsed + fit.pointsRejected))
                    .foregroundStyle(fit.residualRMSMicros > 200 ? .orange : .secondary)
            } else {
                Text("not enough anchors").foregroundStyle(.orange)
            }
        }
    }
}
