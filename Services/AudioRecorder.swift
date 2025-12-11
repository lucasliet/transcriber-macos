import Foundation
import AVFoundation

enum AudioRecorderError: Error, LocalizedError {
    case permissionDenied
    case recordingFailed(String)
    case noRecordingInProgress
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Permissão de microfone negada"
        case .recordingFailed(let message):
            return "Falha na gravação: \(message)"
        case .noRecordingInProgress:
            return "Nenhuma gravação em andamento"
        }
    }
}

class AudioRecorder: NSObject {
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    
    override init() {
        super.init()
        requestMicrophonePermission()
    }
    
    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                print("Microphone permission denied")
            }
        }
    }
    
    func startRecording() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "transcriber_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)
        recordingURL = fileURL
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            
            guard audioRecorder?.record() == true else {
                throw AudioRecorderError.recordingFailed("Could not start recording")
            }
        } catch {
            throw AudioRecorderError.recordingFailed(error.localizedDescription)
        }
    }
    
    func stopRecording() throws -> URL {
        guard let recorder = audioRecorder, let url = recordingURL else {
            throw AudioRecorderError.noRecordingInProgress
        }
        
        recorder.stop()
        audioRecorder = nil
        
        return url
    }
    
    var isRecording: Bool {
        audioRecorder?.isRecording ?? false
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording finished unsuccessfully")
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("Recording encode error: \(error.localizedDescription)")
        }
    }
}
