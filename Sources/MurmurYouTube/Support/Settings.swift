import Foundation
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet
    case elevenlabs

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        case .elevenlabs: "ElevenLabs (cloud)"
        }
    }

    /// Short label for the settings window's key row.
    var shortName: String {
        switch self {
        case .apple: "Apple"
        case .parakeet: "Parakeet"
        case .elevenlabs: "ElevenLabs"
        }
    }

    var blurb: String {
        switch self {
        case .apple:
            "Apple's on-device transcriber. Streams text while you speak; no download."
        case .parakeet:
            "Parakeet on the Neural Engine. Resolves on release; ~470 MB model."
        case .elevenlabs:
            "ElevenLabs Scribe over the network — no API key, no account. Streams while you "
            + "speak, falls back to a single batch request and then to Apple's engine."
        }
    }

    /// Parakeet only resolves on release; the other two stream.
    var showsLiveText: Bool { self != .parakeet }

    /// The only engine that leaves the machine.
    var isCloud: Bool { self == .elevenlabs }
}

/// Which overlay shows the live transcript.
enum HUDStyle: String, CaseIterable, Sendable {
    /// Grows out of the MacBook's physical notch. Falls back to `.panel` on a display
    /// that doesn't have one, since there'd be nothing to anchor to.
    case notch
    /// A floating capsule above the Dock, with a waveform.
    case panel

    var displayName: String {
        switch self {
        case .notch: "Notch"
        case .panel: "Painel flutuante"
        }
    }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    /// A full key combination (⌥⌘T and friends), used instead of `pushToTalkKey` when set.
    var customHotkey: KeyCombination? {
        didSet {
            if let customHotkey, let encoded = try? JSONEncoder().encode(customHotkey) {
                defaults.set(encoded, forKey: Keys.customHotkey)
            } else {
                defaults.removeObject(forKey: Keys.customHotkey)
            }
        }
    }

    /// What actually opens the mic. The custom combination wins when one is set.
    var hotkeyBinding: HotkeyBinding {
        if let customHotkey { return .combination(customHotkey) }
        return .modifier(pushToTalkKey)
    }

    var recordingMode: RecordingMode {
        didSet { defaults.set(recordingMode.rawValue, forKey: Keys.recordingMode) }
    }

    var hudStyle: HUDStyle {
        didSet { defaults.set(hudStyle.rawValue, forKey: Keys.hudStyle) }
    }

    var engine: SpeechEngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// Run every engine on each recording and show them side by side, instead of
    /// transcribing with one. Nothing is typed into the focused app in this mode.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Use the on-device LLM for cleanup instead of the deterministic rule pass.
    var smartCleanup: Bool {
        didSet { defaults.set(smartCleanup, forKey: Keys.smartCleanup) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let customHotkey = "customHotkey"
        static let recordingMode = "recordingMode"
        static let hudStyle = "hudStyle"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let smartCleanup = "smartCleanup"
        static let compareMode = "compareMode"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        customHotkey = defaults.data(forKey: Keys.customHotkey)
            .flatMap { try? JSONDecoder().decode(KeyCombination.self, from: $0) }
        // Hybrid by default: it is a superset of push-to-talk — holding behaves identically
        // — and it is what this app shipped with before.
        recordingMode = RecordingMode(rawValue: defaults.string(forKey: Keys.recordingMode) ?? "") ?? .hybrid
        hudStyle = HUDStyle(rawValue: defaults.string(forKey: Keys.hudStyle) ?? "") ?? .notch
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        smartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
    }
}
