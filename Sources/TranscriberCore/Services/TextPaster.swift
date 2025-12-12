import Foundation
#if canImport(AppKit)
import AppKit
import Carbon
#endif

public class TextPaster {
    public init() {}

    public func pasteText(_ text: String) {
        #if os(Linux)
        // 1. Copy to clipboard using xclip
        let xclip = Process()
        xclip.executableURL = URL(fileURLWithPath: "/usr/bin/xclip")
        xclip.arguments = ["-selection", "clipboard", "-in"]
        
        let pipe = Pipe()
        xclip.standardInput = pipe
        
        do {
            try xclip.run()
            if let data = text.data(using: .utf8) {
                try pipe.fileHandleForWriting.write(contentsOf: data)
                try pipe.fileHandleForWriting.close()
            }
            xclip.waitUntilExit()
            
            // 2. Simulate Ctrl+V using xdotool
            let xdotool = Process()
            xdotool.executableURL = URL(fileURLWithPath: "/usr/bin/xdotool")
            xdotool.arguments = ["key", "ctrl+v"]
            try xdotool.run()
            xdotool.waitUntilExit()
            
        } catch {
            print("TextPaster Error: \(error)")
        }
        #else
        let pasteboard = NSPasteboard.general
        
        let previousContents = pasteboard.string(forType: .string)
        
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        simulatePaste()
        
        if let previous = previousContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        #endif
    }
    
    #if os(macOS)
    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    #endif
}
