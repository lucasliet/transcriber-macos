import Foundation
import Carbon

class HotkeyManager {
    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var currentHotkey: KeyCombination?
    private var isHotkeyPressed = false
    private var pressedModifiers: UInt32 = 0
    private var pressedKeyCode: UInt32?
    
    func register(keyCombination: KeyCombination) {
        currentHotkey = keyCombination
        setupEventTap()
    }
    
    func unregister() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        
        isHotkeyPressed = false
        pressedModifiers = 0
        pressedKeyCode = nil
    }
    
    private func setupEventTap() {
        unregister()
        
        // Verificação de Acessibilidade
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        
        if !isTrusted {
            print("⚠️ Accessibility permissions missing!")
            return
        }
        
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                      (1 << CGEventType.keyUp.rawValue) |
                                      (1 << CGEventType.flagsChanged.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("❌ Failed to create event tap")
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let hotkey = currentHotkey else {
            return Unmanaged.passUnretained(event)
        }
        
        switch type {
        case .flagsChanged:
            let flags = event.flags
            pressedModifiers = carbonModifiers(from: flags)
            
            if isHotkeyPressed && !isModifiersMatch(hotkey.modifiers) {
                isHotkeyPressed = false
                pressedKeyCode = nil
                onHotkeyUp?()
            }
            
        case .keyDown:
            let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
            
            if keyCode == hotkey.keyCode && isModifiersMatch(hotkey.modifiers) {
                if !isHotkeyPressed {
                    isHotkeyPressed = true
                    pressedKeyCode = keyCode
                    onHotkeyDown?()
                }
                return nil // Consume event
            }
            
        case .keyUp:
            let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
            
            if keyCode == pressedKeyCode && isHotkeyPressed {
                isHotkeyPressed = false
                pressedKeyCode = nil
                onHotkeyUp?()
                return nil // Consume event
            }
            
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
             if let tap = eventTap {
                 CGEvent.tapEnable(tap: tap, enable: true)
             }
            
        default:
            break
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    private func isModifiersMatch(_ targetModifiers: UInt32) -> Bool {
        let relevantModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return (pressedModifiers & relevantModifiers) == (targetModifiers & relevantModifiers)
    }
    
    private func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        return result
    }
    
    deinit {
        unregister()
    }
}
