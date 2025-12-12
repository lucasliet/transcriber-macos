import TranscriberCore
import Gtk
import Foundation
import OpenCombine

class SubscriptionHolder {
    var set = Set<AnyCancellable>()
}

let globalHolder = SubscriptionHolder()

// Initialize GTK
guard let status = Application.run(startupHandler: { app in
    print("Transcriber for Linux started")
    
    // Initialize Core State
    let appState = AppState()
    
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
        Task { @MainActor in
            appState.startRecording()
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
    
    // Observe State Changes using global holder
    appState.$statusMessage
        .sink { msg in
            DispatchQueue.main.async {
                statusItem.label = msg
            }
        }
        .store(in: &globalHolder.set)
    
    appState.$isRecording
        .sink { isRecording in
            DispatchQueue.main.async {
                recordItem.label = isRecording ? "Parar Gravação" : "Iniciar Gravação"
            }
        }
        .store(in: &globalHolder.set)
    
}) else {
    fatalError("Failed to initialize GTK application")
}
