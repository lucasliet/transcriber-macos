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
    @Published var partialText: String = ""

    let hotkeyManager: HotkeyManager
    let audioRecordingService: AudioRecordingService
    let transcriptionService: TranscriptionService
    let textPaster: TextPaster
    let settingsManager: SettingsManager
    let notchPanel = NotchIndicatorPanel()

    private let streamingService = StreamingTranscriptionService()
    private var cancellables = Set<AnyCancellable>()
    private var notchResetTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var streamingTask: Task<Void, Never>?
    private var isStreamingConnected = false
    private var hcaptchaToken: String?
    private var lastSentAudioOffset = 0

    init() {
        self.settingsManager = SettingsManager()
        self.hotkeyManager = HotkeyManager()
        self.audioRecordingService = AudioRecordingService()
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

        HCaptchaService.shared.preFetch()

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
        partialText = ""
        isStreamingConnected = false
        hcaptchaToken = nil
        lastSentAudioOffset = 0
        captureActiveAppIcon()
        startRecordingTimer()

        do {
            try audioRecordingService.startRecording()
            Logger.info("Recording started successfully")
        } catch {
            Logger.error("Failed to start recording: \(error.localizedDescription)")
            isRecording = false
            notchState = .error(error.localizedDescription)
            statusMessage = "Erro: \(error.localizedDescription)"
            return
        }

        streamingTask = Task { [weak self] in
            guard let self else { return }

            // Step 1: Resolve a FRESH hCaptcha token (cached tokens may be single-use)
            Logger.info("Streaming: Resolving fresh hCaptcha token...")
            do {
                let token = try await HCaptchaService.shared.getFreshToken()
                self.hcaptchaToken = token
                Logger.info("Streaming: hCaptcha token obtained")
            } catch {
                Logger.warning("Streaming: hCaptcha failed (\(error.localizedDescription)), will use batch fallback")
                self.isStreamingConnected = false
                return
            }

            // Step 2: Connect WebSocket
            guard !Task.isCancelled, self.isRecording else { return }
            do {
                try await self.streamingService.connect(hcaptchaToken: self.hcaptchaToken!)
                self.isStreamingConnected = true
                Logger.info("Streaming: WebSocket connected")
            } catch {
                Logger.warning("Streaming: WebSocket connection failed (\(error.localizedDescription)), will use batch fallback")
                self.isStreamingConnected = false
                return
            }

            // Step 3: Send audio chunks while recording (incremental, only new samples)
            while !Task.isCancelled, self.isRecording {
                let (newSamples, newOffset) = self.audioRecordingService.getBuffer(fromOffset: self.lastSentAudioOffset)
                self.lastSentAudioOffset = newOffset
                let bufferDuration = Double(newSamples.count) / 16000.0

                if bufferDuration > 0.5 {
                    do {
                        try await self.streamingService.sendChunk(samples: newSamples)
                        let partial = self.streamingService.partialText
                        if !partial.isEmpty {
                            self.partialText = partial
                            self.notchState = .streaming(partial)
                            Logger.info("Streaming: Partial text updated (\(partial.count) chars)")
                        }
                    } catch {
                        Logger.warning("Streaming: Send chunk failed (\(error.localizedDescription))")
                        self.isStreamingConnected = false
                        return
                    }
                }

                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stopRecordingAndTranscribe() async {
        guard isRecording else {
            Logger.warning("stopRecordingAndTranscribe called but not recording")
            return
        }

        Logger.info("Stopping recording and transcribing...")

        // Mark recording as stopped FIRST so streamingTask loop exits
        isRecording = false
        stopRecordingTimer()

        // Step 1: If streaming is connected, commit and get final text BEFORE stopping audio
        var transcribedText = ""
        if isStreamingConnected {
            Logger.info("Streaming: Sending commit and waiting for final transcript...")
            notchState = .transcribing
            statusMessage = "Finalizando transcrição..."

            // Drain the processing queue so every pending sample is in the buffer
            audioRecordingService.drainProcessingQueue()

            // Send one last chunk with only the new audio since last send
            let (finalSamples, _) = audioRecordingService.getBuffer(fromOffset: lastSentAudioOffset)
            let finalDuration = Double(finalSamples.count) / 16000.0
            Logger.info("Streaming: Final chunk \(finalDuration)s (\(finalSamples.count) samples)")
            if finalDuration > 0.05 {
                try? await streamingService.sendChunk(samples: finalSamples)
                // Give the server time to process the last audio before committing
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }

            do {
                transcribedText = try await streamingService.commitAndFinalize()
                Logger.info("Streaming: Final transcript received (\(transcribedText.count) chars)")
            } catch {
                Logger.warning("Streaming: Commit failed (\(error.localizedDescription)), will use batch fallback")
                transcribedText = ""
            }

            streamingService.disconnect()
            isStreamingConnected = false
        }

        // Step 2: Now stop the streaming task and audio recording
        streamingTask?.cancel()
        streamingTask = nil

        let samples = audioRecordingService.stopRecording()
        Logger.info("Recording stopped (\(samples.count) samples)")

        // Step 3: If streaming didn't produce text, fall back to batch (single request)
        if transcribedText.isEmpty {
            Logger.info("Falling back to batch transcription")
            notchState = .transcribing
            statusMessage = "Transcrevendo..."

            do {
                transcribedText = try await transcriptionService.transcribeBatch(samples: samples, mode: settingsManager.transcriptionMode)
            } catch {
                Logger.error("Batch transcription failed: \(error.localizedDescription)")
                notchState = .error(error.localizedDescription)
                statusMessage = "Erro: \(error.localizedDescription)"
                scheduleNotchReset()
                return
            }
        }

        Logger.info("Transcription completed: \(transcribedText.count) characters")

        textPaster.pasteText(transcribedText)
        Logger.info("Text paste completed")

        notchState = .success(transcribedText)
        statusMessage = "Texto colado!"
        scheduleNotchReset()
    }

    private func scheduleNotchReset() {
        notchResetTask?.cancel()
        notchResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notchState = .idle
            self?.statusMessage = "Pronto para gravar"
            self?.partialText = ""
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

    private func captureActiveAppIcon() {
        if let app = NSWorkspace.shared.frontmostApplication,
           let url = app.bundleURL {
            activeAppIcon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            activeAppIcon = nil
        }
    }
}