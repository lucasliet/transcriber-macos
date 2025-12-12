import Foundation
import AVFoundation

public enum AudioRecorderError: Error, LocalizedError {
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

public class AudioRecorder: NSObject {
    #if os(Linux)
    private var recordingProcess: Process?
    #else
    private var audioRecorder: AVAudioRecorder?
    #endif
    private var recordingURL: URL?

    public override init() {
        super.init()
        #if !os(Linux)
        requestMicrophonePermission()
        #endif
    }
    
    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                print("Microphone permission denied")
            }
        }
    }
    
    public func startRecording() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "transcriber_\(UUID().uuidString).wav" // Linux prefers wav for arecord default
        let fileURL = tempDir.appendingPathComponent(fileName)
        recordingURL = fileURL
        
        #if os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arecord")
        // -f cd (16bit little endian, 44100Hz, stereo) -t wav -d 0 (duration infinity)
        process.arguments = ["-f", "cd", "-t", "wav", fileURL.path]
        
        try process.run()
        recordingProcess = process
        #else
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
        #endif
    }
    
    public func stopRecording() throws -> URL {
        #if os(Linux)
        guard let process = recordingProcess, let url = recordingURL else {
             throw AudioRecorderError.noRecordingInProgress
        }
        process.terminate()
        recordingProcess = nil
        return url
        #else
        guard let recorder = audioRecorder, let url = recordingURL else {
            throw AudioRecorderError.noRecordingInProgress
        }
        
        recorder.stop()
        audioRecorder = nil
        
        return url
        #endif
    }
    
    var isRecording: Bool {
        #if os(Linux)
        return recordingProcess?.isRunning ?? false
        #else
        return audioRecorder?.isRecording ?? false
        #endif
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
