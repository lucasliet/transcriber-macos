import TranscriberCore
import Gtk
import Foundation
import OpenCombine

// Initialize GTK
guard let status = Application.run(startupHandler: { app in
    print("Transcriber for Linux started")
    
    // Initialize Core State
    let appState = AppState()
    
    // Create Status Icon (System Tray)
    // Note: In a real deployment, we'd look for the icon in standard paths.
    // Here we'll try relative path or fallback to a standard name.
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
    
    // Observe State Changes
    appState.$statusMessage
        .sink { msg in
            DispatchQueue.main.async {
                statusItem.label = msg
            }
        }
        .store(in: &appState.cancellables) // Need to expose cancellables or hold locally?
        // AppState cancellables is private. access via property if needed or just let it live?
        // Actually sink returns a cancellable we need to keep alive.
        // We'll keep a reference here but we are in a closure.
        // SwiftGtk main loop runs indefinitely.
    
    appState.$isRecording
        .sink { isRecording in
            DispatchQueue.main.async {
                 recordItem.label = isRecording ? "Parar Gravação" : "Iniciar Gravação"
            }
        }
        .store(in: &appState.cancellables) // Can't access private 'cancellables' of appState.
        
    // Workaround: Store subscriptions in global holder
    globalHolder.set = holder.set
    
}) else {
    fatalError("Failed to initialize GTK application")
}

func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
        block()
    } else {
        DispatchQueue.main.async(execute: block)
    }
}

class SubscriptionHolder {
    var set = Set<AnyCancellable>()
}

let globalHolder = SubscriptionHolder()
