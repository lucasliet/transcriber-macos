import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var statusMessage = "Pronto para gravar"
    @Published var showingHotkeySettings = false
    @Published var hotkeyDisplay: String = ""
    @Published var transcriptionModeDisplayName: String = ""
    @Published var notchState: NotchState = .idle
    @Published var recordingDuration: TimeInterval = 0
    @Published var activeAppIcon: NSImage?

    let hotkeyManager: HotkeyManager
    let audioRecorder: AudioRecorder
    let transcriptionService: TranscriptionService
    let textPaster: TextPaster
    let settingsManager: SettingsManager
    let notchPanel = NotchIndicatorPanel()

    private var cancellables = Set<AnyCancellable>()
    private var notchResetTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?

    init() {
        self.settingsManager = SettingsManager()
        self.hotkeyManager = HotkeyManager()
        self.audioRecorder = AudioRecorder()
        self.transcriptionService = TranscriptionService()
        self.textPaster = TextPaster()
        
        self.hotkeyDisplay = settingsManager.currentHotkey.displayString
        self.transcriptionModeDisplayName = settingsManager.transcriptionMode.displayName
        
        setupHotkeyCallbacks()
        hotkeyManager.register(keyCombination: settingsManager.currentHotkey)
        
        settingsManager.$transcriptionMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.transcriptionModeDisplayName = mode.displayName
            }
            .store(in: &cancellables)

        notchPanel.configure(appState: self)
        
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
        notchState = .recording
        captureActiveAppIcon()
        startRecordingTimer()

        do {
            try audioRecorder.startRecording()
            Logger.info("Recording started successfully")
        } catch {
            Logger.error("Failed to start recording: \(error.localizedDescription)")
            isRecording = false
            notchState = .error(error.localizedDescription)
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
        notchState = .transcribing
        stopRecordingTimer()
        Logger.info("Starting transcription flow")

        do {
            Logger.debug("Stopping audio recording...")
            let audioURL = try audioRecorder.stopRecording()
            Logger.info("Recording stopped successfully at: \(audioURL.path)")

            Logger.debug("Loading audio data...")
            let audioData = try Data(contentsOf: audioURL)
            Logger.info("Audio data loaded: \(audioData.count) bytes")

            Logger.debug("Calling transcription service with mode: \(settingsManager.transcriptionMode.rawValue)...")
            let transcribedText = try await transcriptionService.transcribe(
                audioData: audioData,
                audioURL: audioURL,
                mode: settingsManager.transcriptionMode
            )
            Logger.info("Transcription completed: \(transcribedText.count) characters")

            Logger.debug("Calling text paster...")
            textPaster.pasteText(transcribedText)
            Logger.info("Text paste completed")

            notchState = .success(transcribedText)
            statusMessage = "Texto colado!"

            try? FileManager.default.removeItem(at: audioURL)
            Logger.debug("Temporary audio file cleaned up")

            notchResetTask?.cancel()
            notchResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.notchState = .idle
                self?.statusMessage = "Pronto para gravar"
            }
        } catch {
            let errorMsg = error.localizedDescription
            Logger.error("Transcription flow failed: \(errorMsg)")
            notchState = .error(errorMsg)
            statusMessage = "Erro: \(errorMsg)"

            notchResetTask?.cancel()
            notchResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.notchState = .idle
                self?.statusMessage = "Pronto para gravar"
            }
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

    // MARK: - Recording Timer

    private func startRecordingTimer() {
        recordingDuration = 0
        recordingStartTime = Date()
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
    }

    // MARK: - Active App Icon

    private func captureActiveAppIcon() {
        if let app = NSWorkspace.shared.frontmostApplication,
           let url = app.bundleURL {
            activeAppIcon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            activeAppIcon = nil
        }
    }
}