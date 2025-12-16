import Foundation

public class SettingsManager {
    public init() {}
    private let hotkeyKey = "savedHotkey"
    private let defaults = UserDefaults.standard
    
    public var currentHotkey: KeyCombination {
        loadHotkey() ?? KeyCombination.defaultHotkey
    }
    
    public func saveHotkey(_ hotkey: KeyCombination) {
        if let encoded = try? JSONEncoder().encode(hotkey) {
            defaults.set(encoded, forKey: hotkeyKey)
        }
    }
    
    public func loadHotkey() -> KeyCombination? {
        guard let data = defaults.data(forKey: hotkeyKey),
              let hotkey = try? JSONDecoder().decode(KeyCombination.self, from: data) else {
            return nil
        }
        return hotkey
    }
    
    public func resetToDefault() {
        defaults.removeObject(forKey: hotkeyKey)
    }
}
