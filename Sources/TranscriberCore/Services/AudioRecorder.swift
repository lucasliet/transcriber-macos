import Foundation
#if !os(Linux)
import AVFoundation
#endif

public enum AudioRecorderError: Error, LocalizedError {
    case permissionDenied
    case recordingFailed(String)
    case noRecordingInProgress
    case arecordNotFound
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Permissão de microfone negada"
        case .recordingFailed(let message):
            return "Falha na gravação: \(message)"
        case .noRecordingInProgress:
            return "Nenhuma gravação em andamento"
        case .arecordNotFound:
            return "arecord not found. Install with: sudo apt install alsa-utils"
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
    
    #if os(Linux)
    private func findExecutable(_ name: String) -> URL? {
        let paths = ["/usr/bin", "/usr/local/bin", "/bin"]
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
    #endif
    
    #if !os(Linux)
    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                print("Microphone permission denied")
            }
        }
    }
    #endif
    
    public func startRecording() throws {
        let tempDir = FileManager.default.temporaryDirectory
        #if os(Linux)
        let fileName = "transcriber_\(UUID().uuidString).wav"
        #else
        let fileName = "transcriber_\(UUID().uuidString).m4a"
        #endif
        let fileURL = tempDir.appendingPathComponent(fileName)
        recordingURL = fileURL
        
        #if os(Linux)
        guard let arecordURL = findExecutable("arecord") else {
            throw AudioRecorderError.arecordNotFound
        }
        
        let process = Process()
        process.executableURL = arecordURL
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
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        recordingProcess = nil
        
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size > 44 else {
            throw AudioRecorderError.recordingFailed("Invalid or empty WAV file")
        }
        
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
    
    public var isRecording: Bool {
        #if os(Linux)
        return recordingProcess?.isRunning ?? false
        #else
        return audioRecorder?.isRecording ?? false
        #endif
    }
}

#if !os(Linux)
extension AudioRecorder: AVAudioRecorderDelegate {
    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording finished unsuccessfully")
        }
    }
    
    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("Recording encode error: \(error.localizedDescription)")
        }
    }
}
#endif
