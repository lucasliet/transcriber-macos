import Foundation

enum TranscriptionError: Error, LocalizedError {
    case networkError(String)
    case invalidResponse
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Erro de rede: \(message)"
        case .invalidResponse:
            return "Resposta inválida da API"
        case .apiError(let message):
            return "Erro da API: \(message)"
        }
    }
}

class TranscriptionService {
    // private let apiURL = "https://api.elevenlabs.io/v1/speech-to-text?allow_unauthenticated=1"
    private let apiURL = "https://elevenlabs-transcribe.deno.dev/transcribe"
    
    func transcribe(audioData: Data) async throws -> String {
        Logger.info("TranscriptionService: Starting transcription (\(audioData.count) bytes)")

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
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.webm\"\r\n")
        body.append("Content-Type: audio/webm\r\n\r\n")
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
        Logger.debug("TranscriptionService: Sending request to \(apiURL) (\(body.count) bytes)")

        do {
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

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                let responseString = String(data: data, encoding: .utf8) ?? "(binary data)"
                Logger.error("TranscriptionService: Invalid JSON response: \(responseString)")
                throw TranscriptionError.invalidResponse
            }

            Logger.info("TranscriptionService: Successfully transcribed (\(text.count) chars): \"\(text)\"")
            return text

        } catch let error as TranscriptionError {
            Logger.error("TranscriptionService: Transcription error: \(error.localizedDescription)")
            throw error
        } catch {
            Logger.error("TranscriptionService: Network error: \(error.localizedDescription)")
            throw TranscriptionError.networkError(error.localizedDescription)
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
