# ElevenLabs without an API key

This app talks to ElevenLabs Scribe with **no API key and no account**. That is the whole
point of the integration and it is the part most likely to be broken by a careless edit, so
this document describes exactly how it works, why each piece exists, and what fails first.

Two independent paths reach ElevenLabs. They are tried in order and degrade into each
other, so a single utterance can silently traverse all of them:

```
hold key ─► streaming (WebSocket, anonymous + hCaptcha)   ── live text in the HUD
              │ fails / empty
              ▼
            batch (multipart POST)
              │  1. Deno proxy      https://elevenlabs-transcribe.lucasliet.deno.net/transcribe
              │  2. ElevenLabs      (commented out — uncomment to bypass the proxy)
              │ fails
              ▼
            local (Apple Speech, on-device)
```

All three live in `Sources/MurmurYouTube/Transcription/ElevenLabsEngine.swift`, behind the
same `TranscriptionEngine` protocol every other engine implements — `DictationController`
cannot tell which path produced the text. `HCaptchaSolver.swift` next to it obtains the
credential.

---

## 1. Streaming — `wss://api.elevenlabs.io/v1/speech-to-text/realtime/anonymous`

The realtime endpoint has an anonymous tier. It is not open: it demands a valid hCaptcha
token, passed **in the query string**, and rejects the connection with an `auth_error`
frame otherwise.

```
wss://api.elevenlabs.io/v1/speech-to-text/realtime/anonymous
    ?model_id=scribe_v2_realtime
    &audio_format=pcm_16000
    &hcaptcha_token=<jwt>
```

**The URL is built by string concatenation, deliberately.** `URLComponents` /
`URLQueryItem` percent-encode characters that appear in the hCaptcha JWT, and the server
rejects the re-encoded token. Never "clean this up" into `URLComponents`.

### Handshake

The first frame the server sends is the verdict:

| `message_type` | meaning |
|---|---|
| `session_started` | connected; audio may flow |
| `auth_error` | the hCaptcha token was rejected — fall through to batch |

### Protocol

Client frames are JSON text:

```json
{ "message_type": "input_audio_chunk", "audio_base_64": "<PCM16LE>", "sample_rate": 16000 }
{ "message_type": "commit" }
```

Server frames worth handling:

| `message_type` | handling |
|---|---|
| `partial_transcript` | interim text — replaces the interim slot, shown live |
| `committed_transcript` (also `…_with_timestamps`) | append to the finals list |
| `auth_error` | log and disconnect |

Audio is **PCM 16-bit little-endian, 16 kHz, mono**, base64-encoded. Chunks are sent about
every 1.5 s and only the samples not yet sent are included — the buffer is read by offset,
never re-sent from the start, or the transcript duplicates itself.

### The commit dance (the fragile part)

After `commit`, the server frequently emits a first `committed_transcript` that does **not
include the final chunk of audio**, then revises it. So the client does not take the first
final it sees. It polls every 200 ms and only accepts the transcript once its length has
stopped changing for two consecutive polls (~400 ms), with a 10 s ceiling. On timeout it
falls back to whatever partial text exists; only a completely empty result throws.

Equally load-bearing on the caller's side: before committing, the audio processing queue is
drained, one last chunk of the remaining samples is sent, and the code waits 500 ms so the
server has actually processed that tail. Skipping any of these truncates the last word.

---

## 2. hCaptcha — how the token is obtained

There is no API key, so the token *is* the credential.

- Site key `8e58fe8c-1a48-4f94-88ae-8e90b586a192` — ElevenLabs' own public site key.
- Solved by loading a tiny HTML page with the invisible hCaptcha widget inside an offscreen
  `WKWebView`, whose `baseURL` is set to `https://elevenlabs.io` so the origin matches the
  site key. The JS callback posts the token back over a `WKScriptMessageHandler`.
- The host `NSWindow` sits at `(-10000, -10000)`, is borderless, transparent, and ignores
  mouse events. It is created once and **never destroyed** — only its `contentView` is
  released after each solve. Destroying and recreating the window intermittently wedged the
  WebKit process.
- 20 s timeout; concurrent callers queue on a single in-flight resolution rather than each
  spawning their own WebView.
- Tokens are cached for 10 minutes and pre-fetched at launch — but **the streaming path
  always requests a fresh one** (`getFreshToken()`), because these tokens behave as
  single-use and a cached one gets rejected at the WebSocket handshake.

Handlers are removed and loading stopped before the WebView is released, so a late JS
callback cannot fire into a dead continuation.

---

## 3. Batch — multipart POST

Used when streaming never connected or came back empty. One WAV, one request, first
endpoint in `ElevenLabsEndpoint.batch` that answers wins:

1. `https://elevenlabs-transcribe.lucasliet.deno.net/transcribe` — a Deno Deploy proxy
   that holds whatever credentials are needed server-side. **Active.**
2. `https://api.elevenlabs.io/v1/speech-to-text?allow_unauthenticated=1` — ElevenLabs
   direct, the unauthenticated escape hatch. **Commented out**; uncomment the line to add
   it as a second attempt. It works, but it is rate-limited and it is the one that cares
   about the headers below.

`multipart/form-data` fields:

| field | value |
|---|---|
| `file` | `audio.wav`, `audio/wav`, 16 kHz mono PCM16 with a hand-written 44-byte WAV header |
| `model_id` | `scribe_v1` |
| `tag_audio_events` | `true` |
| `diarize` | `true` |

Headers matter as much as the body — the unauthenticated endpoint is browser-shaped, so the
request carries a Firefox `User-Agent`, `Accept: */*`, `Accept-Language: pt-BR`, and both
`Origin: https://elevenlabs.io` and `Referer: https://elevenlabs.io/`. Strip those and the
direct endpoint starts refusing.

The response is JSON; only `text` is read. Anything other than HTTP 200 throws with the
body attached, and the next endpoint in the list is tried.

---

## 4. Local fallback

When the whole cloud cascade fails, the captured audio is replayed into `AppleSpeechEngine`
— the same on-device engine the Apple option in Settings uses. Two conditions guard it:

- It is only attempted when Apple's `preferredInputFormat()` is the 16 kHz mono PCM16 the
  capture already produced. `SpeechAnalyzer` treats a format mismatch as a hard
  precondition failure — it does not throw, it kills the process — so a mismatch means
  *no* fallback rather than a converted one.
- If the local path also fails, the **cloud** error is what surfaces. The user cares why
  the network attempt failed, not that a fallback they didn't ask for also didn't work.

Picking Apple or Parakeet in Settings bypasses all of this: those engines never touch the
network at all.

---

## 5. Audio format contract

Everything above assumes one format, requested once via `preferredInputFormat()` and reused
by every path:

- **16 kHz, mono, PCM signed 16-bit little-endian.**
- `AudioCapture` taps the mic at the device's native rate in float32 and converts to that
  format with an `AVAudioConverter` before the engine ever sees a buffer.
- `ElevenLabsEngine` copies each buffer's `int16ChannelData` straight out as bytes. The
  streaming path base64-encodes them as-is; the batch path prepends the 44-byte RIFF
  header written by `wav(pcm:)`.
- The whole utterance is retained in `recorded` regardless of which path is live, because
  the batch and local fallbacks both need audio that streaming has already consumed.

Change the sample rate and both remote paths break silently rather than loudly:
`audio_format=pcm_16000` is pinned in the WebSocket URL, and the WAV header would simply
declare a rate the audio isn't in.

---

## 6. Failure modes, in the order you will meet them

| Symptom | Cause |
|---|---|
| WS closes immediately with `auth_error` | hCaptcha token reused, expired, or percent-encoded |
| Streaming never connects, batch always used | WebView blocked, no network at load time, or the 20 s solve timed out |
| Last word missing | tail chunk not sent, or the transcript accepted before it stabilized |
| Text duplicated | chunks re-sent from offset 0 instead of the last sent offset |
| Direct endpoint 4xx, proxy fine | browser-shaped headers dropped, or anonymous rate limit |
| No local fallback after a network outage | Apple's preferred format wasn't 16 kHz mono PCM16 |
| Empty transcript, no error | silence, or a sample-rate mismatch feeding the model noise |
