import Foundation
#if canImport(AppKit)
import AppKit
import Carbon
#endif

public class TextPaster {
    public init() {}
    
    #if os(Linux)
    private func findExecutable(_ name: String) -> URL? {
        let paths = ["/usr/bin", "/usr/local/bin", "/bin"]
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
    #endif

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
            
            usleep(50_000) // 50ms delay to ensure X11 clipboard sync
            
            let xdotool = Process()
            xdotool.executableURL = xdotoolURL
            xdotool.arguments = ["key", "ctrl+v"]
            try xdotool.run()
            xdotool.waitUntilExit()
            
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
