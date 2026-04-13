import Foundation
@preconcurrency import AVFoundation
import Speech

@available(macOS 26, *)
class LocalTranscriptionService {
    private let locale: Locale

    init(locale: Locale = Locale(identifier: "pt-BR")) {
        self.locale = locale
    }

    func transcribe(audioAt url: URL) async throws -> String {
        Logger.info("LocalTranscriptionService: Starting local transcription from \(url.path)")

        let (audioSamples, sampleRate) = try loadAudioSamples(from: url)
        Logger.info("LocalTranscriptionService: Loaded \(audioSamples.count) audio samples at \(sampleRate)Hz")

        return try await transcribe(samples: audioSamples, sampleRate: sampleRate)
    }

    func transcribeFromSamples(_ samples: [Float]) async throws -> String {
        Logger.info("LocalTranscriptionService: Starting local transcription from \(samples.count) samples")
        return try await transcribe(samples: samples, sampleRate: 16000)
    }

    private func transcribe(samples: [Float], sampleRate: Double = 44100) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let sourceBuffer = createPCMBuffer(from: samples, sampleRate: sampleRate)
        let buffer = await Self.prepareBuffer(sourceBuffer, for: transcriber)
        Logger.info("LocalTranscriptionService: Audio buffer ready (format: \(buffer.format.description))")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        let resultTask = Task<String, Error> {
            var fullText = ""
            for try await result in transcriber.results {
                if result.isFinal {
                    fullText += String(result.text.characters)
                }
            }
            return fullText
        }

        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await resultTask.value
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.info("LocalTranscriptionService: Successfully transcribed (\(trimmed.count) chars): \"\(trimmed)\"")
        return trimmed
    }

    private func loadAudioSamples(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let audioFile = try AVAudioFile(forReading: url)
        let srcFormat = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw LocalTranscriptionError.audioConversionFailed
        }

        try audioFile.read(into: buffer)

        guard srcFormat.channelCount == 1,
              let channelData = buffer.floatChannelData?[0] else {
            throw LocalTranscriptionError.audioConversionFailed
        }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        return (samples, srcFormat.sampleRate)
    }

    private func createPCMBuffer(from samples: [Float], sampleRate: Double = 16000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].initialize(from: ptr.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private static func prepareBuffer(
        _ sourceBuffer: AVAudioPCMBuffer,
        for transcriber: SpeechTranscriber
    ) async -> AVAudioPCMBuffer {
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            Logger.warning("LocalTranscriptionService: Could not determine target format, using source")
            return sourceBuffer
        }

        guard sourceBuffer.format != targetFormat else {
            return sourceBuffer
        }

        Logger.info("LocalTranscriptionService: Converting from \(sourceBuffer.format.description) to \(targetFormat.description)")

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            Logger.warning("LocalTranscriptionService: Could not create converter, using source")
            return sourceBuffer
        }

        let sampleRateRatio = targetFormat.sampleRate / sourceBuffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(
            (Double(sourceBuffer.frameLength) * sampleRateRatio).rounded(.up)
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: frameCapacity
        ) else {
            return sourceBuffer
        }

        var conversionError: NSError?
        var consumed = false
        converter.convert(to: convertedBuffer, error: &conversionError) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return sourceBuffer
        }

        if conversionError != nil {
            Logger.warning("LocalTranscriptionService: Conversion failed, using source buffer")
            return sourceBuffer
        }

        return convertedBuffer
    }
}

enum LocalTranscriptionError: Error, LocalizedError {
    case unavailable
    case audioConversionFailed
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Reconhecimento de fala local não disponível (requer macOS 26+)"
        case .audioConversionFailed:
            return "Falha na conversão do áudio para formato local"
        case .transcriptionFailed(let message):
            return "Falha na transcrição local: \(message)"
        }
    }
}

class LocalTranscriptionServiceProxy {
    private var _serviceStorage: AnyObject?

    init() {
        if #available(macOS 26, *) {
            _serviceStorage = LocalTranscriptionService()
        }
    }

    var isAvailable: Bool {
        if #available(macOS 26, *) {
            return _serviceStorage != nil
        }
        return false
    }

    func transcribe(audioAt url: URL) async throws -> String {
        if #available(macOS 26, *) {
            guard let service = _serviceStorage as? LocalTranscriptionService else {
                throw LocalTranscriptionError.unavailable
            }
            return try await service.transcribe(audioAt: url)
        } else {
            throw LocalTranscriptionError.unavailable
        }
    }

    func transcribeFromSamples(_ samples: [Float]) async throws -> String {
        if #available(macOS 26, *) {
            guard let service = _serviceStorage as? LocalTranscriptionService else {
                throw LocalTranscriptionError.unavailable
            }
            return try await service.transcribeFromSamples(samples)
        } else {
            throw LocalTranscriptionError.unavailable
        }
    }
}