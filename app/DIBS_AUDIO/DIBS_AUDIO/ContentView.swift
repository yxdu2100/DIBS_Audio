import SwiftUI

struct ContentView: View {
    @Environment(DIBSBLEManager.self) private var ble
    @Environment(RecordingStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @State private var saveError: String?
    @State private var showingBoards = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showingBoards = true } label: {
                        ConnectionRow(state: ble.connectionState, boardName: ble.selectedBoardName)
                    }
                    .foregroundStyle(.primary)
                    if let battery = ble.battery {
                        BatteryRow(battery: battery)
                    }
                    RecordControl()
                } footer: {
                    if let error = ble.lastError ?? saveError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Sessions") {
                    if store.recordings.isEmpty {
                        Text("No sessions yet").foregroundStyle(.secondary)
                    }
                    ForEach(store.recordings) { recording in
                        NavigationLink(value: recording) {
                            RecordingRow(recording: recording)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let recording = store.recordings[index]
                            if player.playingURL == recording.url { player.stop() }
                            store.delete(recording)
                        }
                    }
                }
            }
            .navigationTitle("DIBS Audio")
            .navigationDestination(for: Recording.self) { SessionDetailView(recording: $0) }
            .sheet(isPresented: $showingBoards) { BoardPickerView() }
            .toolbar { EditButton() }
        }
        .onAppear {
            ble.onRecordingFinished = { capture in
                do {
                    try store.save(capture)
                    saveError = nil
                } catch {
                    saveError = "Could not save: \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct ConnectionRow: View {
    let state: DIBSBLEManager.ConnectionState
    let boardName: String?

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
            Spacer()
            if state == .scanning || state == .connecting { ProgressView() }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var label: String {
        let board = boardName ?? "DIBS"
        return switch state {
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth permission needed"
        case .noBoardSelected: "Choose a board"
        case .scanning: "Looking for \(board)…"
        case .connecting: "Connecting to \(board)…"
        case .connected: "Connected to \(board)"
        }
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .scanning, .connecting: .orange
        case .noBoardSelected: .blue
        default: .red
        }
    }
}

private struct BatteryRow: View {
    let battery: DIBSBattery

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(battery.charge == .charging ? .green : .primary)
            Text(battery.voltage, format: .number.precision(.fractionLength(2)))
                .monospacedDigit() + Text(" V")
            Text("\(min(battery.stateOfCharge, 100)) %")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Text(label)
                .foregroundStyle(battery.charge == .charging ? .green : .secondary)
        }
    }

    private var label: String {
        switch battery.charge {
        case .charging: "Charging"
        case .full: "Charged"
        case .notCharging: "USB, not charging"
        case .discharging: "On battery"
        case .unknown: "Unknown"
        }
    }

    private var symbol: String {
        if battery.charge == .charging { return "battery.100percent.bolt" }
        switch battery.stateOfCharge {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct RecordControl: View {
    @Environment(DIBSBLEManager.self) private var ble

    var body: some View {
        VStack(spacing: 12) {
            Button {
                ble.isRecording ? ble.stopRecording() : ble.startRecording()
            } label: {
                Label(ble.isRecording ? "Stop Recording" : "Start Recording",
                      systemImage: ble.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(ble.isRecording ? .red : .accentColor)
            .disabled(!ble.isReady)

            if let capture = ble.capture {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let elapsed = context.date.timeIntervalSince(capture.startedAt)
                    VStack(spacing: 6) {
                        HStack {
                            Text(Duration.seconds(elapsed),
                                 format: .time(pattern: .minuteSecond))
                                .monospacedDigit()
                            ProgressView(value: min(Double(capture.level) * 8, 1))
                        }
                        HStack {
                            Text(String(format: "IMU %.0f Hz", Double(capture.imuSampleCount) / max(elapsed, 1)))
                            Spacer()
                            let lost = capture.lostPackets + capture.imuLostPackets
                            Text("lost: audio \(capture.lostPackets), IMU \(capture.imuLostPackets)")
                                .foregroundStyle(lost > 0 ? .orange : .secondary)
                        }
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(recording.createdAt, format: .dateTime.month().day().hour().minute().second())
                HStack(spacing: 8) {
                    Text(Duration.seconds(recording.duration),
                         format: .time(pattern: .minuteSecond))
                    if let m = recording.metadata {
                        Text("\(m.imu.samples) IMU samples")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if recording.hasIssues {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Data quality issues")
            }
        }
    }
}
