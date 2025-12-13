import SwiftUI
import Carbon

struct HotkeySettingsView: View {
    let onSave: (KeyCombination) -> Void
    let onCancel: () -> Void
    
    @State private var capturedHotkey: KeyCombination?
    @State private var isCapturing = false
    @State private var pressedKeys: Set<UInt32> = []
    @State private var currentModifiers: UInt32 = 0
    @State private var eventMonitor: Any?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Configurar Atalho")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 8) {
                Text(isCapturing ? "Pressione a combinação de teclas..." : "Clique para capturar")
                    .foregroundColor(.secondary)
                
                Text(capturedHotkey?.displayString ?? "---")
                    .font(.system(size: 32, weight: .medium, design: .rounded))
                    .frame(width: 200, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isCapturing ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isCapturing ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .onTapGesture {
                        startCapturing()
                    }
            }
            
            HStack(spacing: 16) {
                Button("Cancelar") {
                    stopCapturing()
                    onCancel()
                }
                .keyboardShortcut(.escape)
                
                Button("Salvar") {
                    if let hotkey = capturedHotkey {
                        stopCapturing()
                        onSave(hotkey)
                    }
                }
                .keyboardShortcut(.return)
                .disabled(capturedHotkey == nil)
            }
        }
        .padding(30)
        .frame(width: 400, height: 200)
        .onDisappear {
            stopCapturing()
        }
    }
    
    private func startCapturing() {
        guard !isCapturing else { return }
        isCapturing = true
        capturedHotkey = nil
        pressedKeys.removeAll()
        currentModifiers = 0
        
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            handleKeyEvent(event)
            return nil
        }
    }
    
    private func stopCapturing() {
        isCapturing = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            currentModifiers = carbonModifiers(from: event.modifierFlags)
            
            let modifierKeyCode = event.keyCode
            
            if isModifierPressed(event.modifierFlags, for: modifierKeyCode) {
                pressedKeys.insert(UInt32(modifierKeyCode))
            } else {
                pressedKeys.remove(UInt32(modifierKeyCode))
            }
            
            if pressedKeys.isEmpty && capturedHotkey != nil {
                stopCapturing()
            }
            
        } else if event.type == .keyDown {
            let keyCode = UInt32(event.keyCode)
            pressedKeys.insert(keyCode)
            
            if currentModifiers != 0 {
                capturedHotkey = KeyCombination(keyCode: keyCode, modifiers: currentModifiers)
            }
            
        } else if event.type == .keyUp {
            let keyCode = UInt32(event.keyCode)
            pressedKeys.remove(keyCode)
            
            if pressedKeys.isEmpty && capturedHotkey != nil {
                stopCapturing()
            }
        }
    }
    
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
    
    private func isModifierPressed(_ flags: NSEvent.ModifierFlags, for keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 57: return flags.contains(.capsLock)
        case 63: return flags.contains(.function)
        default: return false
        }
    }
}
