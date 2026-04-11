import Foundation

enum TranscriptionMode: String, CaseIterable {
    case cloudWithFallback = "cloudWithFallback"
    case localOnly = "localOnly"

    var displayName: String {
        switch self {
        case .cloudWithFallback: return "Nuvem + Local"
        case .localOnly: return "Somente Local"
        }
    }
}

enum TranscriptionError: Error, LocalizedError {
    case networkError(String)
    case invalidResponse
    case apiError(String)
    case localFallbackUnavailable
    case localTranscriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Erro de rede: \(message)"
        case .invalidResponse:
            return "Resposta inválida da API"
        case .apiError(let message):
            return "Erro da API: \(message)"
        case .localFallbackUnavailable:
            return "Reconhecimento de fala local não disponível (requer macOS 26+)"
        case .localTranscriptionFailed(let message):
            return "Falha na transcrição local: \(message)"
        }
    }
}

class TranscriptionService {
    private let cloudURLs = [
        "https://elevenlabs-transcribe.lucasliet.deno.net/transcribe",
        "https://api.elevenlabs.io/v1/speech-to-text?allow_unauthenticated=1"
    ]
    private let localService = LocalTranscriptionServiceProxy()

    func transcribe(audioData: Data, audioURL: URL, mode: TranscriptionMode) async throws -> String {
        switch mode {
        case .localOnly:
            return try await transcribeLocally(audioURL: audioURL)
        case .cloudWithFallback:
            return try await transcribeCloudWithFallback(audioData: audioData, audioURL: audioURL)
        }
    }

    private func transcribeCloudWithFallback(audioData: Data, audioURL: URL) async throws -> String {
        do {
            return try await transcribeCloud(audioData: audioData)
        } catch {
            Logger.warning("TranscriptionService: Cloud transcription failed: \(error.localizedDescription)")
            Logger.info("TranscriptionService: Attempting local fallback...")
            do {
                let result = try await transcribeLocally(audioURL: audioURL)
                Logger.info("TranscriptionService: Local fallback succeeded")
                return result
            } catch let localError {
                Logger.error("TranscriptionService: Local fallback also failed: \(localError.localizedDescription)")
                throw error
            }
        }
    }

    private func transcribeCloud(audioData: Data) async throws -> String {
        var lastError: Error?

        for apiURL in cloudURLs {
            do {
                return try await transcribeCloud(audioData: audioData, apiURL: apiURL)
            } catch {
                Logger.warning("TranscriptionService: \(apiURL) failed: \(error.localizedDescription)")
                lastError = error
            }
        }

        throw lastError!
    }

    private func transcribeCloud(audioData: Data, apiURL: String) async throws -> String {
        Logger.info("TranscriptionService: Trying cloud transcription (\(audioData.count) bytes) -> \(apiURL)")

        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:136.0) Gecko/20100101 Firefox/136.0", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("pt-BR", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://elevenlabs.io/", forHTTPHeaderField: "Referer")
        request.setValue("https://elevenlabs.io", forHTTPHeaderField: "Origin")

        var body = Data()

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n")
        body.append("scribe_v1\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"tag_audio_events\"\r\n\r\n")
        body.append("true\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"diarize\"\r\n\r\n")
        body.append("true\r\n")

        body.append("--\(boundary)--\r\n")

        request.httpBody = body
        Logger.debug("TranscriptionService: Sending request (\(body.count) bytes)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.error("TranscriptionService: Invalid response type")
            throw TranscriptionError.invalidResponse
        }

        Logger.info("TranscriptionService: Received response with status \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.error("TranscriptionService: API error [\(httpResponse.statusCode)]: \(errorMessage)")
            throw TranscriptionError.apiError("Status \(httpResponse.statusCode): \(errorMessage)")
        }

        let responseString = String(data: data, encoding: .utf8) ?? "(binary data)"
        Logger.debug("TranscriptionService: Raw JSON response: \(responseString)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            Logger.error("TranscriptionService: Invalid JSON response: \(responseString)")
            throw TranscriptionError.invalidResponse
        }

        Logger.info("TranscriptionService: Successfully transcribed (\(text.count) chars): \"\(text)\"")
        return text
    }

    private func transcribeLocally(audioURL: URL) async throws -> String {
        guard localService.isAvailable else {
            throw TranscriptionError.localFallbackUnavailable
        }
        do {
            return try await localService.transcribe(audioAt: audioURL)
        } catch let error as LocalTranscriptionError {
            throw TranscriptionError.localTranscriptionFailed(error.localizedDescription)
        }
    }
}

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}