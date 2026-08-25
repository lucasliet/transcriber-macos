import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Captures one key combination for the custom binding.
///
/// A local `NSEvent` monitor is enough here — this only listens while the settings window
/// has focus, unlike `HotkeyMonitor`, which has to see keys pressed in other apps and
/// therefore needs a tap and the Accessibility grant.
struct HotkeyRecorder: View {
    @Binding var combination: KeyCombination?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                Button {
                    isRecording ? stop() : begin()
                } label: {
                    Text(buttonTitle)
                        .font(DS.Font.label)
                        .frame(minWidth: 140)
                }

                if combination != nil {
                    Button("Usar tecla modificadora") {
                        stop()
                        combination = nil
                    }
                    .font(DS.Font.label)
                }
            }

            if let rejection {
                Text(rejection)
                    .font(DS.Font.label)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private var buttonTitle: String {
        if isRecording { return "Pressione a combinação…" }
        if let combination { return "Atalho: \(combination.displayString)" }
        return "Definir atalho personalizado…"
    }

    private func begin() {
        rejection = nil
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc cancels rather than being recorded — otherwise there's no way out of the
            // recorder without binding something.
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }

            let candidate = KeyCombination(
                keyCode: UInt32(event.keyCode),
                modifiers: Self.carbonModifiers(from: event.modifierFlags)
            )

            // A bare letter would be swallowed system-wide the moment it's bound, which
            // makes the keyboard unusable and the app hard to get back to.
            guard candidate.hasModifier else {
                rejection = "Escolha uma combinação com ao menos um modificador (⌃ ⌥ ⇧ ⌘)."
                return nil
            }

            combination = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
