import TranscriberCore
import Gtk
import GLib
import Foundation
import OpenCombine

class SubscriptionHolder {
    var appState: AppState!
    static let shared = SubscriptionHolder()
    var subscriptions = Set<AnyCancellable>()
    private init() {}
}

private var _appState: AppState?

// Initialize GTK
guard let status = Application.run(startupHandler: { app in
    print("Transcriber for Linux started")
    
    // Initialize Core State
    _appState = AppState()
    guard let appState = _appState else { return }
    
    // Create Status Icon (System Tray)
    let iconPath = "transcriber.png" 
    let statusIcon = StatusIcon(file: iconPath) ?? StatusIcon(stock: .yes)
    statusIcon.tooltipText = "Transcriber"
    statusIcon.visible = true
    
    // Create Menu
    let menu = Menu()
    
    // Status Item
    let statusItem = MenuItem(label: appState.statusMessage)
    statusItem.sensitive = false
    menu.append(statusItem)
    menu.append(SeparatorMenuItem())
    
    // Record Item
    let recordItem = MenuItem(label: "Iniciar Gravação")
    recordItem.connect(signal: "activate") { 
        Task {
            if appState.isRecording {
                await appState.stopRecordingAndTranscribe()
            } else {
                appState.startRecording()
            }
        }
    }
    menu.append(recordItem)
    
    // Quit Item
    let quitItem = MenuItem(label: "Sair")
    quitItem.connect(signal: "activate") { 
        app.quit()
    }
    menu.append(quitItem)
    
    menu.showAll()
    
    // Handle Right Click
    statusIcon.connect(signal: "popup-menu") { _, button, time in
        menu.popup(at: nil, button: Int(button), time: time)
    }
    
    // Observe State Changes using GTK main loop idle
    appState.$statusMessage
        .sink { msg in
            let capturedMsg = msg
            _ = GLib.idleAdd {
                statusItem.label = capturedMsg
                return false
            }
        }
        .store(in: &SubscriptionHolder.shared.subscriptions)
    
    appState.$isRecording
        .sink { isRecording in
            let label = isRecording ? "Parar Gravação" : "Iniciar Gravação"
            _ = GLib.idleAdd {
                recordItem.label = label
                return false
            }
        }
        .store(in: &SubscriptionHolder.shared.subscriptions)
    
}) else {
    fatalError("Failed to initialize GTK application")
}
