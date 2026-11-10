import SwiftUI

/// Lists nearby DIBS boards; the chosen one is remembered and reconnected.
struct BoardPickerView: View {
    @Environment(DIBSBLEManager.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @State private var confirmShutdown = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                List {
                    if ble.isRecording {
                        Section {
                            Text("Stop recording before changing boards.")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section {
                        if ble.nearbyBoards.isEmpty {
                            ContentUnavailableView(
                                "Looking for DIBS boards",
                                systemImage: "dot.radiowaves.left.and.right",
                                description: Text("A board that has been still for about a minute stops advertising. Move it to wake it up."))
                        }
                        ForEach(ble.nearbyBoards) { board in
                            Button {
                                if ble.select(board) { dismiss() }
                            } label: {
                                BoardRow(board: board, selected: board.id == ble.selectedBoardID,
                                         connected: board.id == ble.selectedBoardID
                                            && ble.connectionState == .connected)
                            }
                            .foregroundStyle(.primary)
                            .disabled(ble.isRecording)
                        }
                    } header: {
                        Text("Nearby boards")
                    } footer: {
                        Text("Each board advertises as DIBS_Audio-XXXX, from its chip ID. The board ID in every session.json ends with the same four digits.")
                    }

                    if ble.selectedBoardID != nil {
                        Section {
                            Button("Turn off for storage") { confirmShutdown = true }
                                .disabled(!ble.isReady || ble.isRecording)
                            Button("Forget \(ble.selectedBoardName ?? "this board")", role: .destructive) {
                                ble.forgetBoard()
                            }
                            .disabled(ble.isRecording)
                        } footer: {
                            Text("Turning off puts the charger in shutdown mode: the battery is not drained while the board is stored. Plug in USB to turn it back on.")
                        }
                    }
                }
            }
            .navigationTitle("Choose Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Turn off \(ble.selectedBoardName ?? "the board")?",
                                isPresented: $confirmShutdown, titleVisibility: .visible) {
                Button("Turn Off", role: .destructive) {
                    if ble.shutDownBoard() { dismiss() }
                }
            } message: {
                Text(ble.battery?.usbPresent == true
                     ? "USB is connected: the board turns off when you unplug it. Plugging USB in again turns it back on."
                     : "The board turns off now. Plug in USB to turn it back on.")
            }
            .onAppear { ble.startBrowsing() }
            .onDisappear { ble.stopBrowsing() }
        }
    }
}

private struct BoardRow: View {
    let board: DiscoveredBoard
    let selected: Bool
    let connected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(board.name)
                Group {
                    if connected {
                        Text("Connected")
                    } else if Date().timeIntervalSince(board.lastSeen) > 10 {
                        Text("Not seen recently")
                    } else {
                        Text("\(board.rssi) dBm")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            SignalBars(rssi: board.rssi)
        }
        .contentShape(Rectangle())
    }
}

private struct SignalBars: View {
    let rssi: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(5 + i * 4))
            }
        }
        .accessibilityLabel("Signal \(bars) of 4")
    }

    private var bars: Int {
        switch rssi {
        case (-60)...: 4
        case (-70)..<(-60): 3
        case (-80)..<(-70): 2
        case (-90)..<(-80): 1
        default: 0
        }
    }
}
