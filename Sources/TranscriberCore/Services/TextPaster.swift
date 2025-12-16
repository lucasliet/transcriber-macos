import Foundation
#if canImport(AppKit)
import AppKit
import Carbon
#endif

public class TextPaster {
    public init() {}

    public func pasteText(_ text: String) {
        #if os(Linux)
        guard let xclipURL = findExecutable("xclip") else {
            print("TextPaster Error: xclip not found. Install with: sudo apt install xclip")
            return
        }
        guard let xdotoolURL = findExecutable("xdotool") else {
            print("TextPaster Error: xdotool not found. Install with: sudo apt install xdotool")
            return
        }
        
        var previousContents: String?
        let readClipboard = Process()
        readClipboard.executableURL = xclipURL
        readClipboard.arguments = ["-selection", "clipboard", "-out"]
        let outPipe = Pipe()
        readClipboard.standardOutput = outPipe
        readClipboard.standardError = FileHandle.nullDevice
        do {
            try readClipboard.run()
            readClipboard.waitUntilExit()
            if readClipboard.terminationStatus == 0 {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                previousContents = String(data: data, encoding: .utf8)
            }
        } catch {
            print("TextPaster Warning: Could not read previous clipboard: \(error)")
        }
        
        let xclip = Process()
        xclip.executableURL = xclipURL
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
            
            Thread.sleep(forTimeInterval: 0.05)
            
            let xdotool = Process()
            xdotool.executableURL = xdotoolURL
            xdotool.arguments = ["key", "ctrl+v"]
            try xdotool.run()
            xdotool.waitUntilExit()
            
            if let previous = previousContents, !previous.isEmpty {
                Thread.sleep(forTimeInterval: 0.5)
                let restoreClip = Process()
                restoreClip.executableURL = xclipURL
                restoreClip.arguments = ["-selection", "clipboard", "-in"]
                let restorePipe = Pipe()
                restoreClip.standardInput = restorePipe
                try restoreClip.run()
                if let data = previous.data(using: .utf8) {
                    try restorePipe.fileHandleForWriting.write(contentsOf: data)
                    try restorePipe.fileHandleForWriting.close()
                }
                restoreClip.waitUntilExit()
            }
            
        } catch {
            print("TextPaster Error: \(error)")
        }
        #else
        guard AXIsProcessTrusted() else {
            print("TextPaster Error: Accessibility permissions required. Grant access in System Preferences > Security & Privacy > Accessibility.")
            return
        }
        
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount
        
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        simulatePaste()
        
        if let previous = previousContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if pasteboard.changeCount == previousChangeCount + 1 {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
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
