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
            Logger.warning("startRecording called but already recording")
            return
        }

        Logger.info("Starting recording...")
        isRecording = true
        statusMessage = "Gravando..."

        do {
            try audioRecorder.startRecording()
            Logger.info("Recording started successfully")
        } catch {
            Logger.error("Failed to start recording: \(error.localizedDescription)")
            isRecording = false
            statusMessage = "Erro: \(error.localizedDescription)"
        }
    }
    
    func stopRecordingAndTranscribe() async {
        guard isRecording else {
            Logger.warning("stopRecordingAndTranscribe called but not recording")
            return
        }

        isRecording = false
        statusMessage = "Transcrevendo..."
        Logger.info("Starting transcription flow")

        do {
            Logger.debug("Stopping audio recording...")
            let audioURL = try audioRecorder.stopRecording()
            Logger.info("Recording stopped successfully at: \(audioURL.path)")

            Logger.debug("Loading audio data...")
            let audioData = try Data(contentsOf: audioURL)
            Logger.info("Audio data loaded: \(audioData.count) bytes")

            Logger.debug("Calling transcription service...")
            let transcribedText = try await transcriptionService.transcribe(audioData: audioData)
            Logger.info("Transcription completed: \(transcribedText.count) characters")

            Logger.debug("Calling text paster...")
            textPaster.pasteText(transcribedText)
            Logger.info("Text paste completed")

            statusMessage = "Texto colado!"

            try? FileManager.default.removeItem(at: audioURL)
            Logger.debug("Temporary audio file cleaned up")

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.statusMessage = "Pronto para gravar"
            }
        } catch {
            let errorMsg = "Erro: \(error.localizedDescription)"
            Logger.error("Transcription flow failed: \(error.localizedDescription)")
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
