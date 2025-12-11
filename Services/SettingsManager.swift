import Foundation

class SettingsManager {
    private let hotkeyKey = "savedHotkey"
    private let defaults = UserDefaults.standard
    
    var currentHotkey: KeyCombination {
        loadHotkey() ?? KeyCombination.defaultHotkey
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
