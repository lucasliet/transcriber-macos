import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
import OpenCombineDispatch
import OpenCombineFoundation
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

#if os(macOS)
@MainActor
#endif
public class AppState: ObservableObject {
    @Published public var isRecording = false
    @Published public var statusMessage = "Pronto para gravar"
    @Published public var showingHotkeySettings = false
    @Published public var hotkeyDisplay: String = ""
    
    let hotkeyManager: HotkeyManager
    let audioRecorder: AudioRecorder
    let transcriptionService: TranscriptionService
    let textPaster: TextPaster
    public let settingsManager: SettingsManager
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
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
    
    public func startRecording() {
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
    
    public func stopRecordingAndTranscribe() async {
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
    
    public func updateHotkey(_ keyCombination: KeyCombination) {
        settingsManager.saveHotkey(keyCombination)
        hotkeyManager.unregister()
        hotkeyManager.register(keyCombination: keyCombination)
        hotkeyDisplay = keyCombination.displayString
    }
    
    public func checkUpdates() {
        UpdateManager.shared.checkForUpdates(isUserInitiated: true)
    }
}
