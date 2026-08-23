import AppKit
import Carbon.HIToolbox
import Foundation

/// Which modifier key holds the mic open.
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption
    case fn
    case rightCommand

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)   // 61
        case .fn: Int64(kVK_Function)               // 63
        case .rightCommand: Int64(kVK_RightCommand) // 54
        }
    }

    /// Device-*dependent* bit for this specific physical key.
    ///
    /// `CGEventFlags.maskAlternate` is the union mask — it's set whenever *either* Option
    /// key is down. Using it means: hold Left ⌥, tap Right ⌥, and the release is invisible
    /// (the union bit is still set by the left key), so the release never fires. The mic
    /// stays open, the HUD stays up, and the next press is swallowed too.
    ///
    /// These raw values are the NX_DEVICE* masks from IOKit's event system; they carry the
    /// left/right distinction that the public `CGEventFlags` constants discard.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x40)   // NX_DEVICERALTKEYMASK
        case .rightCommand: CGEventFlags(rawValue: 0x10)  // NX_DEVICERCMDKEYMASK
        case .fn: .maskSecondaryFn                        // no left/right variant exists
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "⌥ direito"
        case .fn: "fn"
        case .rightCommand: "⌘ direito"
        }
    }

    /// Swallowing `fn` would break fn+arrow, fn+delete and the emoji picker, so we let it
    /// through. Dedicated right-hand modifiers are safe to consume.
    var shouldConsumeEvent: Bool { self != .fn }
}

/// Watches for the push-to-talk binding using a `CGEventTap`.
///
/// A tap is required rather than `NSEvent.addGlobalMonitor` because `fn` and left/right
/// modifier discrimination don't surface through the higher-level APIs. This needs
/// Accessibility permission; without it `CGEvent.tapCreate` returns nil.
///
/// The tap also owns the press→recording mapping, because `.hybrid` needs to know how long
/// the key was held and that is a fact about the keyboard, not about dictation.
@MainActor
final class HotkeyMonitor {
    /// A tap under this is a "tap"; anything longer is a hold. Matches the old app.
    private static let toggleThreshold: TimeInterval = 1.0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Physical state of the binding.
    private var isKeyDown = false
    /// Whether the binding is physically held right now. In `.hybrid` a recording can be
    /// running with this false — that's a latched recording.
    var isKeyHeld: Bool { isKeyDown }
    /// Carbon modifier mask as of the last `flagsChanged`.
    private var carbonModifiers: UInt32 = 0
    private var keyDownAt: Date?
    /// Logical state: true between `onStart` and `onStop`, which in `.hybrid` can outlive
    /// the key being held.
    private(set) var isRecording = false

    var binding: HotkeyBinding = .modifier(.rightOption)
    var mode: RecordingMode = .hybrid
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        // `.combination` needs keyDown/keyUp as well; watching all three costs nothing and
        // keeps one code path for both binding kinds.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // CGEvent isn't Sendable, so pull out the plain values before crossing into
                // actor-isolated code. The tap was added to the main run loop, so this
                // callback genuinely does run on the main thread.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let consume = MainActor.assumeIsolated {
                    monitor.handle(type: type, keyCode: keyCode, flags: flags)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            FileLog.error("hotkey: falha ao criar o event tap (permissão de Acessibilidade?)")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let name = binding.displayName
        Log.hotkey.info("listening for \(name, privacy: .public)")
        FileLog.info("hotkey: escutando \(name) (\(mode.rawValue))")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isKeyDown = false
        keyDownAt = nil
        isRecording = false
    }

    /// Drops the latch without firing `onStop` — for when the controller stopped the
    /// recording on its own (an error, a Record button press) and the monitor's idea of
    /// the world is now stale.
    func resetLatch() {
        isRecording = false
        isKeyDown = false
        keyDownAt = nil
    }

    // MARK: - Tap callback

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        // The system disables a tap that runs too slowly or is interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        switch binding {
        case .modifier(let key):
            return handleModifier(key, type: type, keyCode: keyCode, flags: flags)
        case .combination(let combo):
            return handleCombination(combo, type: type, keyCode: keyCode, flags: flags)
        }
    }

    private func handleModifier(
        _ key: PushToTalkKey,
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags
    ) -> Bool {
        guard type == .flagsChanged, keyCode == key.keyCode else { return false }

        let nowDown = flags.contains(key.flag)
        guard nowDown != isKeyDown else { return false }
        isKeyDown = nowDown

        if nowDown { pressed() } else { released() }
        return key.shouldConsumeEvent
    }

    private func handleCombination(
        _ combo: KeyCombination,
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags
    ) -> Bool {
        switch type {
        case .flagsChanged:
            carbonModifiers = KeyCombination.carbonModifiers(from: flags)
            // Letting go of ⌥ while still holding T has to count as a release, or the mic
            // stays open until the letter key happens to come up.
            if isKeyDown, !combo.matches(carbonModifiers: carbonModifiers) {
                isKeyDown = false
                released()
            }
            return false

        case .keyDown:
            guard UInt32(keyCode) == combo.keyCode,
                  combo.matches(carbonModifiers: carbonModifiers),
                  !isKeyDown
            else { return false }
            isKeyDown = true
            pressed()
            return true

        case .keyUp:
            guard UInt32(keyCode) == combo.keyCode, isKeyDown else { return false }
            isKeyDown = false
            released()
            return true

        default:
            return false
        }
    }

    // MARK: - Press → recording

    private func pressed() {
        // Any press while recording stops it. In `.hybrid` this is how a latched recording
        // is ended; in `.pushToTalk` it can only happen if a release was missed.
        if isRecording {
            finishRecording()
            return
        }
        keyDownAt = Date()
        isRecording = true
        onStart?()
    }

    private func released() {
        guard isRecording else { return }

        if mode == .pushToTalk {
            finishRecording()
            return
        }

        let held = keyDownAt.map { Date().timeIntervalSince($0) } ?? 0
        if held < Self.toggleThreshold {
            // Tap: latch on. The recording now ends on the next press, not this release.
            Log.hotkey.info("tap (\(held, format: .fixed(precision: 2))s) — latched on")
            FileLog.info("hotkey: toque curto, gravação travada ligada")
            return
        }
        finishRecording()
    }

    private func finishRecording() {
        isRecording = false
        keyDownAt = nil
        onStop?()
    }
}
