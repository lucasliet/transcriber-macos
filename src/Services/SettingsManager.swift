import Foundation
import Combine

class SettingsManager: ObservableObject {
    private let hotkeyKey = "savedHotkey"
    private let transcriptionModeKey = "transcriptionMode"
    private let defaults = UserDefaults.standard
    
    var currentHotkey: KeyCombination {
        loadHotkey() ?? KeyCombination.defaultHotkey
    }
    
    @Published var transcriptionMode: TranscriptionMode {
        didSet {
            defaults.set(transcriptionMode.rawValue, forKey: transcriptionModeKey)
        }
    }
    
    private let localServiceProxy = LocalTranscriptionServiceProxy()

    var isLocalSpeechAvailable: Bool {
        localServiceProxy.isAvailable
    }
    
    init() {
        let savedMode = defaults.string(forKey: transcriptionModeKey) ?? ""
        self.transcriptionMode = TranscriptionMode(rawValue: savedMode) ?? .cloudWithFallback
    }
    
    func saveHotkey(_ hotkey: KeyCombination) {
        if let encoded = try? JSONEncoder().encode(hotkey) {
            defaults.set(encoded, forKey: hotkeyKey)
        }
    }
    
    func loadHotkey() -> KeyCombination? {
        guard let data = defaults.data(forKey: hotkeyKey),
              let hotkey = try? JSONDecoder().decode(KeyCombination.self, from: data) else {
            return nil
        }
        return hotkey
    }
    
    func resetToDefault() {
        defaults.removeObject(forKey: hotkeyKey)
    }
}