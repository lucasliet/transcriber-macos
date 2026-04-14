import Foundation
import WebKit
import AppKit

@MainActor
class HCaptchaService: NSObject {
    static let shared = HCaptchaService()

    private static let sitekey = "8e58fe8c-1a48-4f94-88ae-8e90b586a192"
    private static let tokenTTL: TimeInterval = 600 // 10 minutes
    private static let refreshBeforeExpiry: TimeInterval = 120
    private static let resolutionTimeout: TimeInterval = 20.0

    private var cachedToken: String?
    private var tokenExpiry: Date?
    private var hostWindow: NSWindow?
    private var activeContinuation: CheckedContinuation<String, Error>?
    private var isResolving = false
    private var waiters: [CheckedContinuation<String, Error>] = []

    private override init() {
        super.init()
    }

    private func ensureWindow() -> NSWindow {
        if let window = hostWindow {
            return window
        }

        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
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
        self.hostWindow = window

        Logger.info("HCaptchaService: Created persistent host window")
        return window
    }

    func getToken() async throws -> String {
        if let token = cachedToken, let expiry = tokenExpiry, Date() < expiry {
            Logger.info("HCaptchaService: Using cached token (expires in \(Int(expiry.timeIntervalSinceNow))s)")
            return token
        }

        return try await resolveFreshToken()
    }

    func getFreshToken() async throws -> String {
        // Always resolve a new token, ignoring cache.
        // hCaptcha tokens may be single-use - cached tokens can be rejected.
        cachedToken = nil
        tokenExpiry = nil
        return try await resolveFreshToken()
    }

    private func resolveFreshToken() async throws -> String {
        if isResolving {
            Logger.info("HCaptchaService: Token resolution in progress, adding to waiters (\(waiters.count) waiting)")
            return try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        }

        isResolving = true

        let result: Result<String, Error>
        do {
            let token = try await resolveTokenWithTimeout()
            result = .success(token)
        } catch {
            result = .failure(error)
        }

        isResolving = false

        let currentWaiters = waiters
        waiters.removeAll()

        switch result {
        case .success(let token):
            cachedToken = token
            tokenExpiry = Date().addingTimeInterval(Self.tokenTTL)
            Logger.info("HCaptchaService: Token resolved successfully, resuming \(currentWaiters.count) waiters")
            for waiter in currentWaiters {
                waiter.resume(returning: token)
            }
            return token
        case .failure(let error):
            cachedToken = nil
            tokenExpiry = nil
            Logger.error("HCaptchaService: Token resolution failed: \(error.localizedDescription), failing \(currentWaiters.count) waiters")
            for waiter in currentWaiters {
                waiter.resume(throwing: error)
            }
            throw error
        }
    }

    func preFetch() {
        let shouldFetch = cachedToken == nil || tokenExpiry == nil || Date() > tokenExpiry!.addingTimeInterval(-Self.refreshBeforeExpiry)
        guard shouldFetch, !isResolving else { return }

        Logger.info("HCaptchaService: Pre-fetching token...")
        Task {
            try? await getToken()
        }
    }

    private func resolveTokenWithTimeout() async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.resolveToken()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(Self.resolutionTimeout))
                throw HCaptchaError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func resolveToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.activeContinuation = continuation

            let window = ensureWindow()

            let config = WKWebViewConfiguration()
            let contentController = WKUserContentController()
            contentController.add(self, name: "hcaptcha")
            config.userContentController = contentController
            config.websiteDataStore = .nonPersistent()

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:136.0) Gecko/20100101 Firefox/136.0"
            webView.navigationDelegate = self

            // Set as window content - this retains the webView
            window.contentView = webView
            window.makeKeyAndOrderFront(nil)
            window.orderOut(nil) // Immediately hide - was visible only briefly for hCaptcha

            Logger.info("HCaptchaService: WebView loaded in host window, loading hCaptcha...")

            let html = Self.buildHTML()
            webView.loadHTMLString(html, baseURL: URL(string: "https://elevenlabs.io"))
        }
    }

    private static func buildHTML() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <script src="https://js.hcaptcha.com/1/api.js" async defer></script>
        </head>
        <body>
            <div class="h-captcha" data-sitekey="\(sitekey)" data-callback="onToken" data-size="invisible"></div>
            <script>
                function onToken(token) {
                    window.webkit.messageHandlers.hcaptcha.postMessage(token);
                }
                function tryExecute() {
                    if (typeof hcaptcha !== 'undefined' && hcaptcha.execute) {
                        hcaptcha.execute().then(function() {}).catch(function(err) {
                            window.webkit.messageHandlers.hcaptcha.postMessage('ERROR:' + err);
                        });
                    } else {
                        window.webkit.messageHandlers.hcaptcha.postMessage('ERROR:hcaptcha not loaded');
                    }
                }
                if (document.readyState === 'complete') {
                    setTimeout(tryExecute, 500);
                } else {
                    window.addEventListener('load', function() {
                        setTimeout(tryExecute, 500);
                    });
                }
            </script>
        </body>
        </html>
        """
    }
}

extension HCaptchaService: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "hcaptcha", let body = message.body as? String, !body.isEmpty else {
            Logger.warning("HCaptchaService: Received invalid message from WebView")
            return
        }

        if body.hasPrefix("ERROR:") {
            let errorMsg = String(body.dropFirst(6))
            Logger.error("HCaptchaService: JS error: \(errorMsg)")
            // Don't destroy window, just release contentView
            clearWindowContent()
            if let continuation = activeContinuation {
                activeContinuation = nil
                continuation.resume(throwing: HCaptchaError.webViewError(errorMsg))
            }
            return
        }

        let token = body
        Logger.info("HCaptchaService: Received token from WebView (\(token.prefix(20))...)")

        // Release the WebView content but keep the window alive
        clearWindowContent()

        if let continuation = activeContinuation {
            activeContinuation = nil
            continuation.resume(returning: token)
        }
    }
}

extension HCaptchaService: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Logger.info("HCaptchaService: Page loaded, hCaptcha should execute soon")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Logger.error("HCaptchaService: Navigation failed: \(error.localizedDescription)")
        handleWebViewError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Logger.error("HCaptchaService: Provisional navigation failed: \(error.localizedDescription)")
        handleWebViewError(error)
    }

    private func handleWebViewError(_ error: Error) {
        clearWindowContent()

        if let continuation = activeContinuation {
            activeContinuation = nil
            continuation.resume(throwing: HCaptchaError.webViewError(error.localizedDescription))
        }
    }
}

extension HCaptchaService {
    private func clearWindowContent() {
        // Remove message handlers first to prevent callbacks after release
        if let webView = hostWindow?.contentView as? WKWebView {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
        }
        // Setting contentView to nil releases the WKWebView
        // but the NSWindow stays alive (never destroyed)
        hostWindow?.contentView = nil
    }
}

enum HCaptchaError: Error, LocalizedError {
    case serviceDeallocated
    case webViewError(String)
    case timeout
    case tokenResolutionFailed

    var errorDescription: String? {
        switch self {
        case .serviceDeallocated:
            return "Serviço hCaptcha desalocado"
        case .webViewError(let message):
            return "Erro no WebView: \(message)"
        case .timeout:
            return "Timeout ao resolver hCaptcha"
        case .tokenResolutionFailed:
            return "Falha ao resolver token hCaptcha"
        }
    }
}