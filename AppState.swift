import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var statusMessage = "Pronto para gravar"
    @Published var showingHotkeySettings = false
    @Published var hotkeyDisplay: String = ""
    
    let hotkeyManager: HotkeyManager
    let audioRecorder: AudioRecorder
    let transcriptionService: TranscriptionService
    let textPaster: TextPaster
    let settingsManager: SettingsManager
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.settingsManager = SettingsManager()
        self.hotkeyManager = HotkeyManager()
        self.audioRecorder = AudioRecorder()
        self.transcriptionService = TranscriptionService()
        self.textPaster = TextPaster()
        
        self.hotkeyDisplay = settingsManager.currentHotkey.displayString
        
        
        setupHotkeyCallbacks()
        hotkeyManager.register(keyCombination: settingsManager.currentHotkey)
        
        // Auto Update Check (runs detached/background)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            UpdateManager.shared.checkForUpdates()
        }
    }
    
    private func setupHotkeyCallbacks() {
        hotkeyManager.onHotkeyDown = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }
        
        hotkeyManager.onHotkeyUp = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingAndTranscribe()
            }
        }
    }
    
    func startRecording() {
        guard !isRecording else {
            return 
        }
        
        do {
            try audioRecorder.startRecording()
            isRecording = true
            statusMessage = "Gravando..."
        } catch {
            let errorMsg = "Erro ao iniciar gravação: \(error.localizedDescription)"
            statusMessage = errorMsg
        }
    }
    
    func stopRecordingAndTranscribe() async {
        guard isRecording else {
            return 
        }
        
        isRecording = false
        statusMessage = "Transcrevendo..."
        
        do {
            let audioURL = try audioRecorder.stopRecording()
            let audioData = try Data(contentsOf: audioURL)
            
            let transcribedText = try await transcriptionService.transcribe(audioData: audioData)
            
            textPaster.pasteText(transcribedText)
            statusMessage = "Texto colado!"
            
            try? FileManager.default.removeItem(at: audioURL)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.statusMessage = "Pronto para gravar"
            }
        } catch {
            let errorMsg = "Erro: \(error.localizedDescription)"
            statusMessage = errorMsg
        }
    }
    
    func updateHotkey(_ keyCombination: KeyCombination) {
        settingsManager.saveHotkey(keyCombination)
        hotkeyManager.unregister()
        hotkeyManager.register(keyCombination: keyCombination)
        hotkeyDisplay = keyCombination.displayString
    }
    
    func checkUpdates() {
        UpdateManager.shared.checkForUpdates(isUserInitiated: true)
    }
}
