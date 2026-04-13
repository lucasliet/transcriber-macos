import Foundation
import AVFoundation

class AudioRecordingService: NSObject, @unchecked Sendable {
    static let targetSampleRate: Double = 16000

    private var audioEngine: AVAudioEngine?
    private var sampleBuffer: [Float] = []
    private let bufferLock = NSLock()
    private let processingQueue = DispatchQueue(label: "com.transcriber.audio-processing", qos: .userInteractive)
    private var _isRecording = false
    private var _audioLevel: Float = 0
    private var configChangeObserver: NSObjectProtocol?

    override init() {
        super.init()
        requestMicrophonePermission()
    }

    private func requestMicrophonePermission() {
        Logger.info("Requesting microphone permission...")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                Logger.info("Microphone permission GRANTED")
            } else {
                Logger.warning("Microphone permission DENIED")
            }
        }
    }

    var isRecording: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _isRecording
    }

    var audioLevel: Float {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _audioLevel
    }

    var totalBufferDuration: TimeInterval {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return Double(sampleBuffer.count) / Self.targetSampleRate
    }

    func getCurrentBuffer() -> [Float] {
        bufferLock.lock()
        let copy = sampleBuffer
        bufferLock.unlock()
        return copy
    }

    func getBuffer(fromOffset offset: Int) -> (samples: [Float], newOffset: Int) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard offset < sampleBuffer.count else {
            return ([], sampleBuffer.count)
        }
        let newSamples = Array(sampleBuffer[offset...])
        return (newSamples, sampleBuffer.count)
    }

    func getRecentBuffer(maxDuration: TimeInterval) -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let maxSamples = Int(maxDuration * Self.targetSampleRate)
        if sampleBuffer.count <= maxSamples { return sampleBuffer }
        return Array(sampleBuffer.suffix(maxSamples))
    }

    func startRecording() throws {
        var permissionGranted = false
        if #available(macOS 14.0, *) {
            permissionGranted = AVAudioApplication.shared.recordPermission == .granted
        } else {
            permissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }

        guard permissionGranted else {
            throw AudioRecordingServiceError.permissionDenied
        }

        bufferLock.lock()
        sampleBuffer.removeAll()
        _isRecording = true
        _audioLevel = 0
        bufferLock.unlock()

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            engine.stop()
            bufferLock.lock()
            _isRecording = false
            bufferLock.unlock()
            throw AudioRecordingServiceError.noMicrophoneDetected
        }

        let tapFormat: AVAudioFormat
        if inputFormat.channelCount > 1,
           let mono = AVAudioFormat(
               commonFormat: .pcmFormatFloat32,
               sampleRate: inputFormat.sampleRate,
               channels: 1,
               interleaved: false
           ) {
            tapFormat = mono
        } else {
            tapFormat = inputFormat
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            engine.stop()
            bufferLock.lock()
            _isRecording = false
            bufferLock.unlock()
            throw AudioRecordingServiceError.engineStartFailed("Cannot create target audio format")
        }

        guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
            engine.stop()
            bufferLock.lock()
            _isRecording = false
            bufferLock.unlock()
            throw AudioRecordingServiceError.engineStartFailed("Cannot create audio converter")
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            bufferLock.lock()
            _isRecording = false
            bufferLock.unlock()
            throw AudioRecordingServiceError.engineStartFailed(error.localizedDescription)
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        Logger.info("AudioRecordingService: Recording started (input: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch)")
    }

    func stopRecording() -> [Float] {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // Wait for any pending audio processing to complete before touching buffer
        processingQueue.sync { }

        bufferLock.lock()
        let samples = sampleBuffer
        sampleBuffer.removeAll()
        _isRecording = false
        _audioLevel = 0
        bufferLock.unlock()

        Logger.info("AudioRecordingService: Recording stopped (\(samples.count) samples, \(Double(samples.count) / Self.targetSampleRate)s)")
        return samples
    }

    func generateWavData(from samples: [Float]) -> Data {
        let pcmData = Self.floatToPCM16(samples)
        return Self.createWavHeader(dataSize: UInt32(pcmData.count), sampleRate: UInt32(Self.targetSampleRate)) + pcmData
    }

    func generateWavData() -> Data {
        let samples = getCurrentBuffer()
        return generateWavData(from: samples)
    }

    private func processAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * Self.targetSampleRate / buffer.format.sampleRate
        )
        guard frameCount > 0 else { return }

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCount
        ) else { return }

        var error: NSError?
        var consumed = false

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, convertedBuffer.frameLength > 0 else { return }
        guard let channelData = convertedBuffer.floatChannelData?[0] else { return }

        // Copy samples on the render thread (fast), then dispatch to processing queue
        let newSamples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))

        processingQueue.async { [weak self] in
            self?.processConvertedSamples(newSamples)
        }
    }

    private func processConvertedSamples(_ samples: [Float]) {
        let rms = sqrt(samples.reduce(0.0) { $0 + $1 * $1 } / Float(samples.count))
        let normalizedLevel = min(1.0, rms * 5)

        bufferLock.lock()
        guard _isRecording else {
            bufferLock.unlock()
            return
        }
        sampleBuffer.append(contentsOf: samples)
        _audioLevel = normalizedLevel
        bufferLock.unlock()
    }

    private func handleConfigurationChange() {
        guard isRecording else { return }
        Logger.warning("AudioRecordingService: Configuration changed during recording, restarting engine")

        guard let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        do {
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }

            let tapFormat: AVAudioFormat
            if inputFormat.channelCount > 1,
               let mono = AVAudioFormat(
                   commonFormat: .pcmFormatFloat32,
                   sampleRate: inputFormat.sampleRate,
                   channels: 1,
                   interleaved: false
               ) {
                tapFormat = mono
            } else {
                tapFormat = inputFormat
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.targetSampleRate,
                channels: 1,
                interleaved: false
            ) else { return }

            guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else { return }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
            }

            try engine.start()
            Logger.info("AudioRecordingService: Engine restarted successfully after configuration change")
        } catch {
            Logger.error("AudioRecordingService: Failed to restart engine: \(error.localizedDescription)")
        }
    }

    static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func createWavHeader(dataSize: UInt32, sampleRate: UInt32) -> Data {
        var header = Data(capacity: 44)
        let byteRate = sampleRate * 2
        let blockAlign: UInt32 = 2
        let fileSize = 36 + dataSize

        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // mono
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        return header
    }
}

enum AudioRecordingServiceError: Error, LocalizedError {
    case permissionDenied
    case noMicrophoneDetected
    case engineStartFailed(String)
    case noRecordingInProgress

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Permissão de microfone negada"
        case .noMicrophoneDetected:
            return "Nenhum microfone detectado"
        case .engineStartFailed(let message):
            return "Falha ao iniciar motor de áudio: \(message)"
        case .noRecordingInProgress:
            return "Nenhuma gravação em andamento"
        }
    }
}