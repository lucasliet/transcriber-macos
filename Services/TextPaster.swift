import Foundation
import AppKit
import Carbon

class TextPaster {
    func pasteText(_ text: String) {
        Logger.info("TextPaster: Starting paste operation (\(text.count) chars)")

        let pasteboard = NSPasteboard.general

        let previousContents = pasteboard.string(forType: .string)
        Logger.debug("TextPaster: Saved previous clipboard content")

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Logger.debug("TextPaster: Text copied to clipboard")

        simulatePaste()

        if let previous = previousContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
                Logger.debug("TextPaster: Restored previous clipboard content")
            }
        }

        Logger.info("TextPaster: Paste operation completed")
    }

    private func simulatePaste() {
        Logger.debug("TextPaster: Creating CGEventSource...")
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Logger.error("TextPaster: Failed to create CGEventSource")
            return
        }

        Logger.debug("TextPaster: Creating Cmd+V key events...")
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            Logger.error("TextPaster: Failed to create CGEvent for Cmd+V")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        Logger.debug("TextPaster: Posting Cmd+V events...")
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        Logger.info("TextPaster: Cmd+V events posted successfully")
    }
}
