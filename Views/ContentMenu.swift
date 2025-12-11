import SwiftUI

struct ContentMenu: View {
    @EnvironmentObject var appState: AppState
    @State private var hotkeyWindow: NSWindow?
    
    var body: some View {
        VStack {
            Text(appState.statusMessage)
                .font(.caption)
            
            Divider()
            
            Button("Atalho: \(appState.hotkeyDisplay)") {
                openHotkeySettings()
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
}
