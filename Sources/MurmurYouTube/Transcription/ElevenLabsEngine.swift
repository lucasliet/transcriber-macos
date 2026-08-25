import AVFoundation
import Foundation

/// Every ElevenLabs endpoint this app talks to, and the browser-shaped headers the
/// unauthenticated tier expects.
enum ElevenLabsEndpoint {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:136.0) Gecko/20100101 Firefox/136.0"

    /// The anonymous realtime socket. Requires a freshly solved hCaptcha token.
    ///
    /// Built by string concatenation on purpose. `URLComponents` / `URLQueryItem`
    /// percent-encode characters that occur in the hCaptcha JWT, and the server rejects the
    /// re-encoded token with `auth_error`. Do not "clean this up".
    static func realtime(hcaptchaToken: String) -> URL? {
        URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime/anonymous"
            + "?model_id=scribe_v2_realtime"
            + "&audio_format=pcm_16000"
            + "&hcaptcha_token=\(hcaptchaToken)")
    }

    /// Batch endpoints, tried in order.
    ///
    /// The Deno Deploy proxy comes first: it is ours, it holds whatever credentials the
    /// call needs server-side, and it is not subject to ElevenLabs' anonymous throttling.
    /// The commented-out direct endpoint is the escape hatch — uncomment it to bypass the
    /// proxy and hit ElevenLabs' own unauthenticated route, which works but is rate-limited
    /// and depends on the browser-shaped headers below being sent verbatim.
    static let batch = [
        "https://elevenlabs-transcribe.lucasliet.deno.net/transcribe",
        // "https://api.elevenlabs.io/v1/speech-to-text?allow_unauthenticated=1",
    ]
}

/// ElevenLabs Scribe, with **no API key and no account**.
///
/// Three paths, tried in order, so one hold can silently traverse all of them:
///
/// 1. **Streaming** over the anonymous realtime WebSocket, authenticated with an hCaptcha
///    token solved in an offscreen WebView. This is the only path that produces live text.
/// 2. **Batch** — one multipart POST of the whole utterance as a WAV, used when the socket
///    never connected or came back empty.
/// 3. **Local** — Apple's on-device transcriber, replaying the captured audio, used when
///    the network is gone entirely.
///
/// The cloud error is what surfaces if every path fails: the user cares why the network
/// attempt failed, not that a fallback they didn't ask for also didn't work.
actor ElevenLabsEngine: TranscriptionEngine {
    /// 16 kHz mono PCM16 — pinned by `audio_format=pcm_16000` in the socket URL and by the
    /// WAV header the batch path writes. Changing it breaks both paths silently.
    private static let sampleRate = 16_000.0
    /// Bytes of PCM16 worth ~0.5 s. Chunks smaller than this are held back rather than
    /// paying a base64 frame each.
    private static let flushThreshold = Int(sampleRate)  // 8000 samples × 2 bytes
    private static let commitTimeout: TimeInterval = 10

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    /// Everything captured this utterance, kept for the batch and local fallbacks.
    private var recorded = Data()
    /// Captured but not yet sent over the socket.
    private var pending = Data()

    /// Committed segments, in order. `interim` is the current unfinished one, shown but
    /// never stored — the next revision replaces it cleanly.
    private var finals: [String] = []
    private var interim = ""

    private var isStreaming = false

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        recorded.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        finals.removeAll()
        interim = ""
        isStreaming = false

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        // A failure here is not fatal: capture continues and `finish()` transcribes the
        // whole utterance in one batch request instead. No live text, same transcript.
        do {
            try await openSocket()
            isStreaming = true
        } catch {
            Log.speech.info("ElevenLabs · streaming unavailable (\(error.localizedDescription)) — batch on release")
        }

        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        guard let data = Self.pcm16(from: chunk.buffer), !data.isEmpty else { return }

        recorded.append(data)
        guard isStreaming else { return }

        pending.append(data)
        guard pending.count >= Self.flushThreshold else { return }
        await flush()
    }

    func finish() async {
        defer {
            closeSocket()
            continuation?.finish()
            continuation = nil
        }

        if isStreaming, let text = await commitAndAwaitFinal(), !text.isEmpty {
            continuation?.yield(TranscriptionChunk(text: text, isFinal: true))
            return
        }

        closeSocket()

        let audio = recorded
        guard audio.count > Int(Self.sampleRate) / 10 else { return }  // under ~50 ms is silence

        do {
            let text = try await Self.transcribeBatch(pcm: audio)
            continuation?.yield(TranscriptionChunk(text: text, isFinal: true))
        } catch {
            Log.speech.error("ElevenLabs · batch failed: \(error.localizedDescription)")
            if let local = await Self.transcribeLocally(pcm: audio) {
                Log.speech.info("ElevenLabs · local fallback produced \(local.count) chars")
                continuation?.yield(TranscriptionChunk(text: local, isFinal: true))
            } else {
                continuation?.finish(throwing: error)
            }
        }
    }

    // MARK: - Streaming

    private func openSocket() async throws {
        // Always a *fresh* token. These behave as single-use — a cached one is rejected at
        // the handshake, which is why the cache in `HCaptchaSolver` serves the batch path only.
        let token = try await HCaptchaSolver.shared.freshToken()

        guard let url = ElevenLabsEndpoint.realtime(hcaptchaToken: token) else {
            throw ElevenLabsError.badURL
        }

        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        socket.resume()

        // Leave nothing half-open behind: every throw below must drop the socket, or
        // `feed` would keep a dead task around and `finish` would try to commit to it.
        func reject(_ error: ElevenLabsError) -> ElevenLabsError {
            socket.cancel(with: .normalClosure, reason: nil)
            self.socket = nil
            return error
        }

        // The server's first frame is the verdict on the token.
        guard case .string(let text) = try await socket.receive(),
              let json = Self.json(text)
        else {
            throw reject(.badResponse)
        }

        switch json["message_type"] as? String {
        case "session_started":
            Log.speech.info("ElevenLabs · realtime session started")
        case "auth_error":
            throw reject(.auth(json["error"] as? String ?? "rejected"))
        default:
            throw reject(.badResponse)
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            guard let message = try? await socket.receive() else { break }

            let raw: String
            switch message {
            case .string(let text): raw = text
            case .data(let data): raw = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }

            guard let json = Self.json(raw) else { continue }
            let text = json["text"] as? String ?? ""

            switch json["message_type"] as? String {
            case "partial_transcript":
                interim = text.trimmingCharacters(in: .whitespacesAndNewlines)
                emit()
            case "committed_transcript", "committed_transcript_with_timestamps":
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, finals.last != trimmed { finals.append(trimmed) }
                interim = ""
                emit()
            case "auth_error":
                Log.speech.error("ElevenLabs · auth error mid-session: \(json["error"] as? String ?? "")")
                isStreaming = false
                return
            case let type? where type.localizedCaseInsensitiveContains("error"):
                Log.speech.error("ElevenLabs · \(raw, privacy: .public)")
            default:
                continue
            }
        }
    }

    private func flush() async {
        guard let socket, !pending.isEmpty else { return }

        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pending.base64EncodedString(),
            "sample_rate": Int(Self.sampleRate),
        ]
        pending.removeAll(keepingCapacity: true)

        guard let frame = Self.frame(payload) else { return }
        do {
            try await socket.send(.string(frame))
        } catch {
            Log.speech.error("ElevenLabs · send failed: \(error.localizedDescription)")
            isStreaming = false
        }
    }

    /// Commits the utterance and waits for the transcript to settle.
    ///
    /// - Returns: the final transcript, or nil if the socket produced nothing — in which
    ///   case the caller falls through to the batch path.
    private func commitAndAwaitFinal() async -> String? {
        guard let socket else { return nil }

        // Send the tail before committing, then give the server time to actually process
        // it. Skipping either truncates the last word of every utterance.
        await flush()
        try? await Task.sleep(for: .milliseconds(500))

        guard let commit = Self.frame(["message_type": "commit"]) else { return nil }
        try? await socket.send(.string(commit))

        // The first `committed_transcript` frequently omits the final chunk of audio and is
        // then revised. So don't take the first final that arrives — wait for the text to
        // stop changing for two consecutive polls (~400 ms).
        let deadline = Date().addingTimeInterval(Self.commitTimeout)
        var lastLength = -1
        var stablePolls = 0

        while Date() < deadline {
            let committed = finals.joined(separator: " ")
            if !committed.isEmpty {
                if committed.count == lastLength {
                    stablePolls += 1
                } else {
                    stablePolls = 0
                    lastLength = committed.count
                }
                if stablePolls >= 2 {
                    return committed.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Timed out: whatever is on screen beats nothing.
        let partial = snapshot()
        Log.speech.info("ElevenLabs · commit timed out, using \(partial.count) chars of partial text")
        return partial.isEmpty ? nil : partial
    }

    private func closeSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isStreaming = false
    }

    // MARK: - Transcript assembly

    private func snapshot() -> String {
        (finals + (interim.isEmpty ? [] : [interim]))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emit() {
        continuation?.yield(TranscriptionChunk(text: snapshot(), isFinal: false))
    }

    // MARK: - Batch

    /// One multipart POST per endpoint, first success wins.
    private static func transcribeBatch(pcm: Data) async throws -> String {
        var lastError: Error = ElevenLabsError.badResponse

        for endpoint in ElevenLabsEndpoint.batch {
            do {
                return try await post(wav: wav(pcm: pcm), to: endpoint)
            } catch {
                Log.speech.error("ElevenLabs · \(endpoint, privacy: .public) failed: \(error.localizedDescription)")
                lastError = error
            }
        }

        throw lastError
    }

    private static func post(wav: Data, to endpoint: String) async throws -> String {
        guard let url = URL(string: endpoint) else { throw ElevenLabsError.badURL }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // The unauthenticated route is browser-shaped: it inspects these and starts
        // refusing when they're missing. The proxy ignores them, so they're sent to both.
        request.setValue(ElevenLabsEndpoint.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("pt-BR", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://elevenlabs.io/", forHTTPHeaderField: "Referer")
        request.setValue("https://elevenlabs.io", forHTTPHeaderField: "Origin")

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.append("\r\n")
        for (name, value) in [("model_id", "scribe_v1"), ("tag_audio_events", "true"), ("diarize", "true")] {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ElevenLabsError.badResponse }
        guard http.statusCode == 200 else {
            throw ElevenLabsError.api(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else {
            throw ElevenLabsError.badResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Local fallback

    /// Replays the captured audio through Apple's on-device engine.
    ///
    /// Only attempted when Apple wants the same format we captured in. `SpeechAnalyzer`
    /// treats a format mismatch as a hard precondition failure — it doesn't throw, it kills
    /// the process — so a mismatch means no fallback rather than a converted one.
    private static func transcribeLocally(pcm: Data) async -> String? {
        let engine = AppleSpeechEngine()
        guard let format = await engine.preferredInputFormat(),
              format.commonFormat == .pcmFormatInt16,
              format.sampleRate == sampleRate,
              format.channelCount == 1,
              let buffer = buffer(pcm: pcm, format: format)
        else {
            Log.speech.error("ElevenLabs · local fallback skipped (incompatible audio format)")
            return nil
        }

        do {
            let stream = try await engine.start()
            let collector = Task { () -> String in
                var latest = ""
                for try await chunk in stream { latest = chunk.text }
                return latest
            }
            await engine.feed(AudioChunk(buffer: buffer))
            await engine.finish()

            let text = try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            Log.speech.error("ElevenLabs · local fallback failed: \(error.localizedDescription)")
            await engine.finish()
            return nil
        }
    }

    // MARK: - Audio plumbing

    private static func pcm16(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let samples = buffer.int16ChannelData, buffer.frameLength > 0 else { return nil }
        return Data(bytes: samples[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    private static func buffer(pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.int16ChannelData
        else { return nil }

        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            channel[0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        return buffer
    }

    /// The 44-byte RIFF header the batch endpoint expects in front of the raw PCM.
    private static func wav(pcm: Data) -> Data {
        let rate = UInt32(sampleRate)
        let dataSize = UInt32(pcm.count)
        var header = Data()

        header.append("RIFF")
        header.append(littleEndian: 36 + dataSize)
        header.append("WAVE")
        header.append("fmt ")
        header.append(littleEndian: UInt32(16))       // PCM chunk size
        header.append(littleEndian: UInt16(1))        // PCM, uncompressed
        header.append(littleEndian: UInt16(1))        // mono
        header.append(littleEndian: rate)
        header.append(littleEndian: rate * 2)         // byte rate: rate × channels × 2
        header.append(littleEndian: UInt16(2))        // block align
        header.append(littleEndian: UInt16(16))       // bits per sample
        header.append("data")
        header.append(littleEndian: dataSize)

        return header + pcm
    }

    // MARK: - JSON

    private static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func frame(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

enum ElevenLabsError: LocalizedError {
    case badURL
    case badResponse
    case auth(String)
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL: "Couldn't build the ElevenLabs request URL."
        case .badResponse: "ElevenLabs returned something this app can't read."
        case .auth(let detail): "ElevenLabs rejected the anonymous session: \(detail)"
        case .api(let status, let body): "ElevenLabs returned HTTP \(status): \(body)"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }

    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        // Qualified: inside an extension on Data the bare name resolves to Data's own
        // instance method `withUnsafeBytes(_:)`, not the global `withUnsafeBytes(of:_:)`.
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
