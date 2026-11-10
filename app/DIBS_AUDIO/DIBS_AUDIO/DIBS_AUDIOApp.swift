import SwiftUI

@main
struct DIBS_AUDIOApp: App {
    @State private var ble = DIBSBLEManager()
    @State private var store = RecordingStore()
    @State private var player = AudioPlayer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ble)
                .environment(store)
                .environment(player)
        }
    }
}
