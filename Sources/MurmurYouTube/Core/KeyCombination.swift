import Carbon.HIToolbox
import Foundation

/// A regular key plus its modifiers — ⌥⌘T and friends.
///
/// The three `PushToTalkKey` options are bare modifiers, which is what a push-to-talk key
/// wants to be: nothing else on the keyboard uses Right ⌥ alone. But a bare modifier can't
/// be typed into a text field, and some people would rather not give up a modifier at all,
/// so a full combination is offered as an alternative binding.
struct KeyCombination: Codable, Equatable, Sendable {
    /// Virtual keycode, as `CGEvent` reports it.
    let keyCode: UInt32
    /// Carbon modifier mask (`controlKey | optionKey | shiftKey | cmdKey`).
    let modifiers: UInt32

    static let `default` = KeyCombination(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(optionKey | cmdKey)
    )

    /// Only these four are considered when matching. Caps Lock, fn and the device-specific
    /// left/right bits are deliberately ignored — a binding shouldn't care which ⌘ you used.
    static let relevantModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.name(for: keyCode))
        return parts.joined()
    }

    /// True when the combination has at least one modifier.
    ///
    /// Binding a bare letter would swallow that letter everywhere on the system, so the
    /// recorder refuses to save one.
    var hasModifier: Bool { modifiers & Self.relevantModifiers != 0 }

    func matches(carbonModifiers: UInt32) -> Bool {
        (carbonModifiers & Self.relevantModifiers) == (modifiers & Self.relevantModifiers)
    }

    /// Translates `CGEventFlags` into the Carbon mask this type stores.
    static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        return result
    }

    static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "?"
    }

    private static let names: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_Space): "Espaço", UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab", UInt32(kVK_Escape): "Esc",
    ]
}

/// What actually opens the mic: one of the three bare modifiers, or a custom combination.
enum HotkeyBinding: Equatable, Sendable {
    case modifier(PushToTalkKey)
    case combination(KeyCombination)

    var displayName: String {
        switch self {
        case .modifier(let key): key.displayName
        case .combination(let combo): combo.displayString
        }
    }
}

/// How a press maps onto a recording.
enum RecordingMode: String, CaseIterable, Sendable {
    /// Hold to talk, release to transcribe. Nothing else.
    case pushToTalk
    /// Hold to talk — but a *tap* (under a second) latches recording on until the next
    /// press. Long dictations don't need the key held down; short ones behave normally.
    case hybrid

    var displayName: String {
        switch self {
        case .pushToTalk: "Segurar para falar"
        case .hybrid: "Híbrido (segurar ou tocar)"
        }
    }

    var blurb: String {
        switch self {
        case .pushToTalk:
            "Grava enquanto a tecla estiver pressionada e transcreve ao soltar."
        case .hybrid:
            "Segurar funciona como sempre. Um toque rápido (menos de 1s) trava a gravação "
            + "ligada até você apertar a tecla de novo — útil para ditados longos."
        }
    }
}
