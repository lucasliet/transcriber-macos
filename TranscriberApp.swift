import SwiftUI

@main
struct TranscriberApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        MenuBarExtra {
            ContentMenu()
                .environmentObject(appState)
        } label: {
            Label("Transcriber", systemImage: appState.isRecording ? "mic.fill" : "mic")
        }
        .menuBarExtraStyle(.menu)
        
        Settings {
            EmptyView()
        }
    }
}
