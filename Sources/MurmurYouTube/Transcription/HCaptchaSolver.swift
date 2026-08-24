import AppKit
import Foundation
import WebKit

/// Solves ElevenLabs' hCaptcha challenge so the anonymous speech-to-text tier can be used
/// without an API key.
///
/// There is no account and no key in this app — the hCaptcha token *is* the credential the
/// realtime endpoint checks. It is obtained by loading the invisible widget in an offscreen
/// `WKWebView` whose `baseURL` is `https://elevenlabs.io`, so the origin matches the site
/// key ElevenLabs' own site uses.
/// Constants live outside the class on purpose: a `static let` on a `@MainActor` type is
/// itself main-actor-isolated, and the timeout below is read from a task that isn't.
private enum HCaptcha {
    /// ElevenLabs' public site key, as served by their web client.
    static let siteKey = "8e58fe8c-1a48-4f94-88ae-8e90b586a192"
    static let tokenTTL: TimeInterval = 600
    static let refreshBeforeExpiry: TimeInterval = 120
    static let solveTimeout: TimeInterval = 20
}

@MainActor
final class HCaptchaSolver: NSObject {
    static let shared = HCaptchaSolver()

    private var cachedToken: String?
    private var tokenExpiry: Date?

    /// Created once and never destroyed — only its `contentView` is released between
    /// solves. Tearing the window down and rebuilding it intermittently wedged WebKit.
    private var hostWindow: NSWindow?
    private var activeContinuation: CheckedContinuation<String, Error>?
    private var isSolving = false
    private var waiters: [CheckedContinuation<String, Error>] = []

    private override init() {
        super.init()
    }

    /// A token, cached if one is still valid.
    func token() async throws -> String {
        if let cachedToken, let tokenExpiry, Date() < tokenExpiry {
            Log.speech.info("hCaptcha · reusing cached token")
            return cachedToken
        }
        return try await solveOnce()
    }

    /// Always solves anew.
    ///
    /// The WebSocket handshake rejects a token it has already seen, so the streaming path
    /// must never reuse one — the cache exists for the batch path only.
    func freshToken() async throws -> String {
        cachedToken = nil
        tokenExpiry = nil
        return try await solveOnce()
    }

    /// Warms the cache at launch so the first hold doesn't pay the ~2 s solve.
    func prefetch() {
        let stale = cachedToken == nil
            || tokenExpiry == nil
            || Date() > tokenExpiry!.addingTimeInterval(-HCaptcha.refreshBeforeExpiry)
        guard stale, !isSolving else { return }

        Task { _ = try? await token() }
    }

    // MARK: - Solving

    /// Coalesces concurrent callers onto a single in-flight solve rather than spawning a
    /// WebView each.
    private func solveOnce() async throws -> String {
        if isSolving {
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        isSolving = true
        let result: Result<String, Error>
        do {
            result = .success(try await solveWithTimeout())
        } catch {
            result = .failure(error)
        }
        isSolving = false

        let pending = waiters
        waiters.removeAll()

        switch result {
        case .success(let token):
            cachedToken = token
            tokenExpiry = Date().addingTimeInterval(HCaptcha.tokenTTL)
            for waiter in pending { waiter.resume(returning: token) }
            return token
        case .failure(let error):
            cachedToken = nil
            tokenExpiry = nil
            Log.speech.error("hCaptcha · solve failed: \(error.localizedDescription)")
            for waiter in pending { waiter.resume(throwing: error) }
            throw error
        }
    }

    private func solveWithTimeout() async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in try await self.solve() }
            group.addTask {
                try await Task.sleep(for: .seconds(HCaptcha.solveTimeout))
                throw HCaptchaError.timeout
            }
            let token = try await group.next()!
            group.cancelAll()
            return token
        }
    }

    private func solve() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            activeContinuation = continuation

            let configuration = WKWebViewConfiguration()
            let controller = WKUserContentController()
            controller.add(self, name: "hcaptcha")
            configuration.userContentController = controller
            configuration.websiteDataStore = .nonPersistent()

            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                configuration: configuration
            )
            webView.customUserAgent = ElevenLabsEndpoint.userAgent
            webView.navigationDelegate = self

            let window = ensureWindow()
            window.contentView = webView

            webView.loadHTMLString(Self.html, baseURL: URL(string: "https://elevenlabs.io"))
        }
    }

    /// Offscreen, borderless, click-through, and never brought to front — the widget is
    /// invisible, so there is nothing for the user to see or interact with.
    private func ensureWindow() -> NSWindow {
        if let hostWindow { return hostWindow }

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hostWindow = window
        return window
    }

    /// Releases the WebView while keeping the window alive. Handlers go first so a late JS
    /// callback can't fire into a continuation that has already been resumed.
    private func releaseWebView() {
        if let webView = hostWindow?.contentView as? WKWebView {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
        }
        hostWindow?.contentView = nil
    }

    private func finish(with result: Result<String, Error>) {
        releaseWebView()
        guard let continuation = activeContinuation else { return }
        activeContinuation = nil
        continuation.resume(with: result)
    }

    private static let html = """
        <!DOCTYPE html>
        <html>
        <head><script src="https://js.hcaptcha.com/1/api.js" async defer></script></head>
        <body>
            <div class="h-captcha" data-sitekey="\(HCaptcha.siteKey)" data-callback="onToken" data-size="invisible"></div>
            <script>
                function onToken(token) {
                    window.webkit.messageHandlers.hcaptcha.postMessage(token);
                }
                function tryExecute() {
                    if (typeof hcaptcha !== 'undefined' && hcaptcha.execute) {
                        hcaptcha.execute().catch(function (err) {
                            window.webkit.messageHandlers.hcaptcha.postMessage('ERROR:' + err);
                        });
                    } else {
                        window.webkit.messageHandlers.hcaptcha.postMessage('ERROR:hcaptcha not loaded');
                    }
                }
                if (document.readyState === 'complete') {
                    setTimeout(tryExecute, 500);
                } else {
                    window.addEventListener('load', function () { setTimeout(tryExecute, 500); });
                }
            </script>
        </body>
        </html>
        """
}

extension HCaptchaSolver: WKScriptMessageHandler {
    /// `assumeIsolated`, deliberately — the exception AGENTS.md allows for a callback that
    /// genuinely runs on the main thread, same as the event tap in `HotkeyMonitor`.
    ///
    /// A `Task { @MainActor }` is not an option here: `WKScriptMessage` is main-actor
    /// isolated in the SDK, so its properties cannot be read from a nonisolated context to
    /// hand across, and the message itself is not `Sendable` so it cannot be captured.
    /// Resuming synchronously is also better behaviour — the continuation completes before
    /// the WebView is torn down rather than a hop later.
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            let body = message.body as? String ?? ""
            guard message.name == "hcaptcha", !body.isEmpty else { return }

            if body.hasPrefix("ERROR:") {
                finish(with: .failure(HCaptchaError.webView(String(body.dropFirst(6)))))
                return
            }
            Log.speech.info("hCaptcha · token obtained")
            finish(with: .success(body))
        }
    }
}

extension HCaptchaSolver: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(error)
    }

    /// Navigation callbacks are main-thread too; see the note on the message handler.
    private nonisolated func fail(_ error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(with: .failure(HCaptchaError.webView(message))) }
    }
}

enum HCaptchaError: LocalizedError {
    case webView(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .webView(let detail): "hCaptcha failed to load: \(detail)"
        case .timeout: "Timed out solving the hCaptcha challenge."
        }
    }
}
