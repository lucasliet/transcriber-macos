import AppKit
import Foundation

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case htmlUrl = "html_url"
    }
}

private struct GitHubAsset: Decodable {
    let browserDownloadUrl: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case browserDownloadUrl = "browser_download_url"
        case name
    }
}

/// Self-update from GitHub Releases.
///
/// The release workflow publishes a zipped `.app` on every `v*` tag, and without this
/// nothing ever installs it. Checks run at most once a day in the background; the menu item
/// forces one and reports "you're up to date" so the user knows the check actually ran.
@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    private let owner = "lucasliet"
    private let repository = "transcriber-macos"
    private let lastCheckKey = "LastUpdateCheckDate"

    private var isChecking = false

    private init() {}

    func checkForUpdates(userInitiated: Bool = false) {
        guard !isChecking else { return }

        if !userInitiated {
            let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
            if Calendar.current.isDateInToday(last) {
                Log.app.info("update check already ran today")
                return
            }
        }

        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest") else {
            return
        }

        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

                if !userInitiated {
                    UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                }

                if Self.isNewer(release.tagName) {
                    FileLog.info("update: versão \(release.tagName) disponível")
                    promptUpdate(release)
                } else if userInitiated {
                    inform(
                        title: "Você está atualizado",
                        message: "O Murmur YouTube \(release.tagName) é a versão mais recente."
                    )
                }
            } catch {
                Log.app.error("update check failed: \(error.localizedDescription)")
                FileLog.error("update: verificação falhou — \(error.localizedDescription)")
                if userInitiated {
                    inform(
                        title: "Falha ao verificar atualizações",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    /// Numeric comparison, so `v0.10.0` correctly beats `v0.9.0` — a plain string compare
    /// would not.
    private static func isNewer(_ tag: String) -> Bool {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let candidate = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private func promptUpdate(_ release: GitHubRelease) {
        let alert = NSAlert()
        alert.messageText = "Nova versão do Murmur YouTube disponível"
        alert.informativeText = "A versão \(release.tagName) já está disponível.\n\nQuer atualizar agora?"
        alert.addButton(withTitle: "Atualizar agora")
        alert.addButton(withTitle: "Depois")
        alert.addButton(withTitle: "Ver notas")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            download(release)
        case .alertThirdButtonReturn:
            if let url = URL(string: release.htmlUrl) { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    private func download(_ release: GitHubRelease) {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let url = URL(string: asset.browserDownloadUrl)
        else {
            Log.app.error("release \(release.tagName, privacy: .public) has no .zip asset")
            inform(title: "Atualização indisponível", message: "Esta versão não publicou um .zip.")
            return
        }

        Log.app.info("downloading \(asset.name, privacy: .public)")
        FileLog.info("update: baixando \(asset.name)")

        Task {
            do {
                let (downloaded, _) = try await URLSession.shared.download(from: url)
                try install(from: downloaded)
            } catch {
                Log.app.error("update download failed: \(error.localizedDescription)")
                FileLog.error("update: download falhou — \(error.localizedDescription)")
                inform(
                    title: "Falha na atualização",
                    message: "Não foi possível baixar a atualização.\n\(error.localizedDescription)"
                )
            }
        }
    }

    /// Unzips, then hands the swap to a detached script.
    ///
    /// The running app cannot replace its own bundle while it is executing out of it, so the
    /// script waits for this process to exit, moves the new bundle into place and relaunches.
    private func install(from downloadedZip: URL) throws {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let zip = workDirectory.appendingPathComponent("update.zip")
        try fileManager.moveItem(at: downloadedZip, to: zip)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zip.path, "-d", workDirectory.path]
        try unzip.run()
        unzip.waitUntilExit()

        guard let newApp = try fileManager
            .contentsOfDirectory(at: workDirectory, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else {
            throw UpdateError.noAppInArchive
        }

        let currentApp = Bundle.main.bundlePath
        let parent = URL(fileURLWithPath: currentApp).deletingLastPathComponent().path

        // Quoting matters: "Murmur YouTube.app" has a space in it, and /Applications may
        // not be writable by the current user.
        var swap = "rm -rf \(Self.shellQuote(currentApp)) && mv \(Self.shellQuote(newApp.path)) \(Self.shellQuote(currentApp))"
        if !fileManager.isWritableFile(atPath: parent) {
            let escaped = swap.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            swap = "osascript -e \"do shell script \\\"\(escaped)\\\" with administrator privileges\""
        }

        let script = workDirectory.appendingPathComponent("install.sh")
        try """
        #!/bin/bash
        # Wait for the app to actually exit before touching its bundle.
        sleep 2
        \(swap)
        open \(Self.shellQuote(currentApp))
        """.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        Log.app.info("relaunching to install update")
        FileLog.info("update: instalando e reiniciando")

        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments = [script.path]
        try installer.run()

        NSApp.terminate(nil)
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func inform(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private enum UpdateError: LocalizedError {
    case noAppInArchive

    var errorDescription: String? {
        switch self {
        case .noAppInArchive: "O .zip da atualização não contém um aplicativo."
        }
    }
}
