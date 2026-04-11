import SwiftUI

struct ContentMenu: View {
    @EnvironmentObject var appState: AppState
    @State private var hotkeyWindow: NSWindow?
    @State private var modeWindow: NSWindow?
    
    var body: some View {
        VStack {
            Text(appState.statusMessage)
                .font(.caption)
            
            Divider()
            
            Button("Atalho: \(appState.hotkeyDisplay)") {
                openHotkeySettings()
            }
            
            Button("Transcrição: \(appState.transcriptionModeDisplayName)") {
                openTranscriptionModeSettings()
            }
            
            Divider()
            
            Button("Verificar Atualizações...") {
                appState.checkUpdates()
            }
            
            Divider()
            
            Button("Sair") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
    
    private func openHotkeySettings() {
        if hotkeyWindow == nil {
            let settingsView = HotkeySettingsView { newHotkey in
                appState.updateHotkey(newHotkey)
                hotkeyWindow?.close()
                hotkeyWindow = nil
            } onCancel: {
                hotkeyWindow?.close()
                hotkeyWindow = nil
            }
            
            let hostingController = NSHostingController(rootView: settingsView)
            
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Configurar Atalho"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 400, height: 200))
            window.center()
            window.level = .floating
            
            hotkeyWindow = window
        }
        
        hotkeyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openTranscriptionModeSettings() {
        if modeWindow == nil {
            let settingsView = TranscriptionModeSettingsView(settingsManager: appState.settingsManager) {
                modeWindow?.close()
                modeWindow = nil
            }

            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Modo de Transcrição"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 420, height: 280))
            window.center()
            window.level = .floating

            modeWindow = window
        }

        modeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}