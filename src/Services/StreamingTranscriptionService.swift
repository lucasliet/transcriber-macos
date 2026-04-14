import Foundation

actor TranscriptCollector {
    private var finals: [String] = []
    private var interim = ""

    func addFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, finals.last != trimmed {
            finals.append(trimmed)
        }
        interim = ""
    }

    func setInterim(_ text: String) {
        interim = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func currentText() -> String {
        var parts = finals
        if !interim.isEmpty {
            parts.append(interim)
        }
        return parts.joined(separator: " ")
    }

    func finalizedText() -> String {
        let final = finals.joined(separator: " ")
        if !final.isEmpty {
            return final
        }
        return currentText()
    }

    func reset() {
        finals.removeAll()
        interim = ""
    }
}

@MainActor
class StreamingTranscriptionService {
    private var webSocketTask: URLSessionWebSocketTask?
    private let collector = TranscriptCollector()
    private var _isConnected = false
    private var _partialText: String = ""
    private var receiveTask: Task<Void, Never>?
    private var lastSentSampleCount: Int = 0

    var isConnected: Bool {
        _isConnected
    }

    var partialText: String {
        _partialText
    }

    func connect(hcaptchaToken: String) async throws {
        disconnect()

        // Build URL manually to avoid URLComponents percent-encoding the JWT token.
        // URLQueryItem can encode characters that break the hCaptcha JWT.
        let urlString = "wss://api.elevenlabs.io/v1/speech-to-text/realtime/anonymous?model_id=scribe_v2_realtime&audio_format=pcm_16000&hcaptcha_token=\(hcaptchaToken)"

        guard let url = URL(string: urlString) else {
            throw StreamingTranscriptionError.invalidURL
        }

        Logger.info("StreamingTranscriptionService: Connecting with token prefix: \(hcaptchaToken.prefix(30))...")

        let request = URLRequest(url: url)
        let wsTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask = wsTask
        wsTask.resume()

        await collector.reset()
        lastSentSampleCount = 0

        let message = try await wsTask.receive()
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messageType = json["message_type"] as? String else {
                throw StreamingTranscriptionError.invalidResponse
            }

            if messageType == "auth_error" {
                let error = json["error"] as? String ?? "Unknown auth error"
                throw StreamingTranscriptionError.authError(error)
            }

            if messageType != "session_started" {
                throw StreamingTranscriptionError.invalidResponse
            }

            Logger.info("StreamingTranscriptionService: Session started (session_id: \(json["session_id"] as? String ?? "unknown"))")
        case .data:
            throw StreamingTranscriptionError.invalidResponse
        @unknown default:
            throw StreamingTranscriptionError.invalidResponse
        }

        _isConnected = true
        _partialText = ""

        startReceiving()
    }

    func sendChunk(samples: [Float]) async throws {
        guard let wsTask = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }

        let pcmData = AudioRecordingService.floatToPCM16(samples)
        guard !pcmData.isEmpty else { return }

        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcmData.base64EncodedString(),
            "sample_rate": 16000,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        guard let jsonText = String(data: jsonData, encoding: .utf8) else {
            throw StreamingTranscriptionError.encodingError
        }

        try await wsTask.send(.string(jsonText))
        lastSentSampleCount = samples.count
    }

    func commitAndFinalize(timeout: TimeInterval = 10.0) async throws -> String {
        guard let wsTask = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }

        let commitPayload: [String: Any] = ["message_type": "commit"]
        let commitData = try JSONSerialization.data(withJSONObject: commitPayload)
        guard let commitText = String(data: commitData, encoding: .utf8) else {
            throw StreamingTranscriptionError.encodingError
        }

        try await wsTask.send(.string(commitText))
        Logger.info("StreamingTranscriptionService: Commit sent, waiting for final transcript...")

        let deadline = Date().addingTimeInterval(timeout)
        var lastFinalLength = -1
        var stableCount = 0

        while Date() < deadline {
            let currentPartial = await collector.currentText()
            let currentFinals = await collector.finalizedText()

            if !currentFinals.isEmpty {
                _partialText = currentFinals

                // Wait for the transcript to stabilize — the server may send
                // an initial committed_transcript that doesn't include the last
                // audio chunk, then follow up with an updated one. Continue
                // receiving until the final text stops changing for 2 polls
                // (400ms) to ensure we capture the complete transcription.
                if currentFinals.count == lastFinalLength {
                    stableCount += 1
                } else {
                    stableCount = 0
                    lastFinalLength = currentFinals.count
                }

                if stableCount >= 2 {
                    Logger.info("StreamingTranscriptionService: Final transcript stabilized (\(currentFinals.count) chars)")
                    disconnect()
                    return currentFinals.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if !currentPartial.isEmpty {
                _partialText = currentPartial
            }

            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        let finalText = await collector.currentText()
        if !finalText.isEmpty {
            Logger.info("StreamingTranscriptionService: Timeout, using partial text (\(finalText.count) chars)")
            disconnect()
            return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        Logger.warning("StreamingTranscriptionService: No transcript received after commit")
        disconnect()
        throw StreamingTranscriptionError.noTranscript
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil

        if let wsTask = webSocketTask {
            wsTask.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil
        }

        _isConnected = false

        Logger.info("StreamingTranscriptionService: Disconnected")
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self, let wsTask = self.webSocketTask else { return }

            while !Task.isCancelled {
                do {
                    let message = try await wsTask.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        Logger.warning("StreamingTranscriptionService: Receive error: \(error.localizedDescription)")
                    }
                    break
                }
            }

            await MainActor.run {
                self._isConnected = false
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let rawText: String
        switch message {
        case .string(let text):
            rawText = text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else { return }
            rawText = text
        @unknown default:
            return
        }

        guard let data = rawText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String else {
            return
        }

        switch messageType {
        case "partial_transcript":
            let text = json["text"] as? String ?? ""
            await collector.setInterim(text)
            let current = await collector.currentText()
            _partialText = current
        case "committed_transcript", "committed_transcript_with_timestamps":
            let text = json["text"] as? String ?? ""
            await collector.addFinal(text)
            let current = await collector.currentText()
            _partialText = current
        case "auth_error":
            let error = json["error"] as? String ?? "Unknown auth error"
            Logger.error("StreamingTranscriptionService: Auth error: \(error)")
            disconnect()
        default:
            if messageType.localizedCaseInsensitiveContains("error") {
                let error = json["error"] as? String ?? rawText
                Logger.error("StreamingTranscriptionService: Error: \(error)")
            }
        }
    }

    static func stabilizeText(confirmed: String, new: String) -> String {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty else { return new }
        guard !new.isEmpty else { return confirmed }

        if new.hasPrefix(confirmed) { return new }

        let confirmedChars = Array(confirmed.unicodeScalars)
        let newChars = Array(new.unicodeScalars)
        var matchEnd = 0
        for i in 0..<min(confirmedChars.count, newChars.count) {
            if confirmedChars[i] == newChars[i] {
                matchEnd = i + 1
            } else {
                break
            }
        }

        if matchEnd > confirmed.count / 2 {
            let newContent = String(new.unicodeScalars.dropFirst(matchEnd))
            return confirmed + newContent
        }

        let minOverlap = min(20, confirmedChars.count / 4)
        let maxShift = min(confirmedChars.count - minOverlap, 150)
        if maxShift > 0 {
            for dropCount in 1...maxShift {
                let suffix = String(confirmed.unicodeScalars.dropFirst(dropCount))
                if new.hasPrefix(suffix) {
                    let newTail = String(new.unicodeScalars.dropFirst(confirmed.unicodeScalars.count - dropCount))
                    return newTail.isEmpty ? confirmed : confirmed + newTail
                }
            }
        }

        return new
    }
}

enum StreamingTranscriptionError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case authError(String)
    case invalidResponse
    case encodingError
    case noTranscript
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "URL inválida para WebSocket"
        case .notConnected:
            return "WebSocket não conectado"
        case .authError(let message):
            return "Erro de autenticação: \(message)"
        case .invalidResponse:
            return "Resposta inválida do servidor"
        case .encodingError:
            return "Erro ao codificar dados de áudio"
        case .noTranscript:
            return "Nenhuma transcrição recebida"
        case .timeout:
            return "Timeout na transcrição"
        }
    }
}