import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GitHubRelease: Codable {
    let tagName: String
    let assets: [GitHubAsset]
    let htmlUrl: String
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case htmlUrl = "html_url"
    }
}

public struct GitHubAsset: Codable {
    let browserDownloadUrl: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case browserDownloadUrl = "browser_download_url"
        case name
    }
}

public class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()
    
    // Config
    private let repoOwner = "lucasliet"
    private let repoName = "transcriber-macos"
    private let defaultsKeyLastCheck = "LastUpdateCheckDate"
    
    private init() {}
    
    public func checkForUpdates(isUserInitiated: Bool = false) {
        // 1. Check Daily Limit (if not user initiated)
        if !isUserInitiated {
            let lastCheck = UserDefaults.standard.object(forKey: defaultsKeyLastCheck) as? Date ?? Date.distantPast
            if Calendar.current.isDateInToday(lastCheck) {
                print("UpdateManager: Already checked today. Skipping.")
                return
            }
        }
        
        // 2. Fetch Release
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else { return }
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                
                // 3. Compare Versions
                if isNewerVersion(release.tagName) {
                    await MainActor.run {
                        #if os(macOS)
                        self.promptUpdate(release: release)
                        #else
                        print("Nova versão disponível: \(release.tagName) — \(release.htmlUrl)")
                        #endif
                    }
                } else if isUserInitiated {
                     await MainActor.run {
                        #if os(macOS)
                        let alert = NSAlert()
                        alert.messageText = "You're up to date!"
                        alert.informativeText = "Transcriber \(release.tagName) is the latest version."
                        alert.runModal()
                        #else
                        print("You're up to date! \(release.tagName)")
                        #endif
                    }
                }
                
                // Update check date
                if !isUserInitiated {
                    UserDefaults.standard.set(Date(), forKey: defaultsKeyLastCheck)
                }
                
            } catch {
                print("UpdateManager: Check failed: \(error)")
                if isUserInitiated {
                    #if os(macOS)
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Update Check Failed"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                    #endif
                }
            }
        }
    }
    
    private func isNewerVersion(_ tagName: String) -> Bool {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        
        // Simple comparison: assumes strict vX.Y.Z
        // Remove 'v' prefix if present
        let cleanTag = tagName.replacingOccurrences(of: "v", with: "")
        let cleanCurrent = currentVersion.replacingOccurrences(of: "v", with: "")
        
        return cleanTag.compare(cleanCurrent, options: .numeric) == .orderedDescending
    }
    
    #if os(macOS)
    @MainActor
    private func promptUpdate(release: GitHubRelease) {
        let alert = NSAlert()
        alert.messageText = "A new version of Transcriber is available!"
        alert.informativeText = "Version \(release.tagName) is available.\n\nWould you like to update now?"
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            downloadAndInstall(release: release)
        }
    }
    #endif
    
    #if os(macOS)
    private func downloadAndInstall(release: GitHubRelease) {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            print("UpdateManager: No zip asset found.")
            return
        }
        
        print("UpdateManager: Downloading \(asset.browserDownloadUrl)...")
        
        guard let downloadUrl = URL(string: asset.browserDownloadUrl) else { return }
        
        Task {
            do {
                let (tempLocalUrl, _) = try await URLSession.shared.download(from: downloadUrl)
                try installUpdate(from: tempLocalUrl)
            } catch {
                print("UpdateManager: Download failed: \(error)")
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Update Failed"
                    alert.informativeText = "Could not download the update.\n\(error.localizedDescription)"
                    alert.runModal()
                }
            }
        }
    }
    #endif
    
    #if os(macOS)
    private func installUpdate(from tempZipUrl: URL) throws {
        // 1. Prepare Paths
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let destinationZip = tempDir.appendingPathComponent("update.zip")
        try fileManager.moveItem(at: tempZipUrl, to: destinationZip)
        
        // 2. Unzip
        // Using /usr/bin/unzip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", destinationZip.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()
        
        // Find the .app in the unzipped content
        guard let appPath = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "UpdateManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "No .app found in update zip"])
        }
        
        // 3. Create Replacement Script
        let currentAppPath = Bundle.main.bundlePath
        let scriptPath = tempDir.appendingPathComponent("install.sh")
        
        // Helper to escape paths for shell
        let qk = "\"" 
        let safeNewApp = "\(qk)\(appPath.path)\(qk)"
        let safeCurrentApp = "\(qk)\(currentAppPath)\(qk)"
        
        // Check write permission
        let isWritable = fileManager.isWritableFile(atPath: URL(fileURLWithPath: currentAppPath).deletingLastPathComponent().path)
        
        var moveCommand = "rm -rf \(safeCurrentApp) && mv \(safeNewApp) \(safeCurrentApp)"
        
        // If not writable, wrap in osascript with administrator privileges
        if !isWritable {
            // Escape for AppleScript
            let escapedCmd = moveCommand.replacingOccurrences(of: "\"", with: "\\\"")
            moveCommand = "osascript -e \"do shell script \\\"\(escapedCmd)\\\" with administrator privileges\""
        }
        
        let scriptContent = """
        #!/bin/bash
        # Wait for app to close
        sleep 2
        
        echo "Updating Transcriber..."
        \(moveCommand)
        
        # Relaunch
        open \(safeCurrentApp)
        """
        
        try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        
        print("UpdateManager: Launching install script: \(scriptPath.path)")
        
        // 4. Run Script and Exit
        let installProcess = Process()
        installProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        installProcess.arguments = [scriptPath.path]
        try installProcess.run()
        
        NSApplication.shared.terminate(self)
    }
    #endif
}
