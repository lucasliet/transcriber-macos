import AppKit
import SwiftUI

@main
struct MurmurYouTubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window("Murmur YouTube", id: "main") {
            MainWindow(controller: delegate.controller)
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Mostrar arquivo do dicionário") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }

        // Fully qualified: this app has its own `Settings` type, which otherwise shadows
        // SwiftUI's settings scene.
        SwiftUI.Settings {
            SettingsWindow(controller: delegate.controller)
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.state.isBusy ? "waveform.circle.fill" : "waveform")
        }

        Window("Comparação de motores", id: "comparison") {
            ComparisonWindow(controller: delegate.controller)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var hud: HUDPanel?
    private var notch: NotchPanel?
    private var stateObservation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        hud = HUDPanel(controller: controller)
        notch = NotchPanel(controller: controller)

        if !controller.activate() {
            Permissions.promptForAccessibility()
            // The tap can only be created once the user grants Accessibility, and there's
            // no notification for that — poll until it takes.
            retryActivation()
        }

        // Write the dashboard up front so the menu item always opens something, even
        // before the first dictation.
        RunLog.regenerate()

        // Parakeet's models take ~20s to load from disk, and that cost lands on whichever
        // dictation touches them first — so the first hold after every launch would stall
        // with the HUD showing nothing. Warm them in the background instead, but only when
        // they're actually going to be used and are already downloaded.
        let willUseParakeet = Settings.shared.compareMode || Settings.shared.engine == .parakeet
        if willUseParakeet, ParakeetModels.isDownloaded {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }

        // Same idea for ElevenLabs, different cost: solving hCaptcha takes a couple of
        // seconds in a WebView, and the streaming path pays it on every hold because these
        // tokens are single-use. Warming one at launch only helps the batch path, but it
        // also proves the WebView works before the user is waiting on it.
        if Settings.shared.compareMode || Settings.shared.engine.isCloud {
            HCaptchaSolver.shared.prefetch()
        }

        // Every `make install` relaunches the app and drops its windows. Restoring the
        // window when it was open last time keeps it from vanishing on each rebuild.
        if UserDefaults.standard.bool(forKey: "comparisonWindowOpen") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                Self.showComparisonWindow()
            }
        }

        // The release workflow publishes a zipped .app on every tag; without this nothing
        // ever installs it. Deferred a beat so it never competes with launch.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            UpdateManager.shared.checkForUpdates()
        }

        observeState()

        let binding = Settings.shared.hotkeyBinding.displayName
        Log.app.info("Murmur YouTube ready — hold \(binding, privacy: .public) to dictate")
        FileLog.info("app: pronto — atalho \(binding), modo \(Settings.shared.recordingMode.rawValue)")
    }

    /// `murmuryt://clear` and `murmuryt://show`, used by the legacy HTML dashboard and
    /// as a scriptable way to raise the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "murmuryt" {
            switch url.host {
            case "clear":
                RunLog.clear()
                RunStore.shared.reload()
            case "show":
                Self.showComparisonWindow()
            default:
                break
            }
        }
    }

    /// Raises the comparison window without needing SwiftUI's `openWindow` environment
    /// value — usable from the app delegate and from a URL handler.
    static func showComparisonWindow() {
        RunStore.shared.reload()
        if let existing = NSApp.windows.first(where: { $0.title == "Comparação de motores" }) {
            existing.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let isOpen = NSApp.windows.contains { $0.title == "Comparação de motores" && $0.isVisible }
        UserDefaults.standard.set(isOpen, forKey: "comparisonWindowOpen")
        controller.deactivate()
    }

    /// Shows and hides the overlay in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.isActive {
                    self.presentOverlay()
                } else {
                    self.notch?.dismiss()
                    self.hud?.dismiss()
                }
                self.observeState()
            }
        }
    }

    /// The notch overlay needs a physical notch to grow out of. On an external display or a
    /// non-notch Mac it can't render, so the floating HUD stands in — the old app showed
    /// nothing at all in that case.
    private func presentOverlay() {
        if Settings.shared.hudStyle == .notch, notch?.canPresent == true {
            hud?.dismiss()
            notch?.present()
        } else {
            notch?.dismiss()
            hud?.present()
        }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.activate()
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var isPreloadingParakeet = false
    @State private var parakeetOnDisk = ParakeetModels.isDownloaded

    private var parakeetStatus: String {
        if isPreloadingParakeet { return "Carregando modelos do Parakeet…" }
        // Reflects what's actually on disk, not just what this menu instance has done.
        return parakeetOnDisk ? "Modelos do Parakeet instalados ✓" : "Baixar modelos do Parakeet…"
    }

    private func preloadParakeet() {
        guard !isPreloadingParakeet else { return }
        isPreloadingParakeet = true
        Task {
            do {
                _ = try await ParakeetModels.shared.manager()
                parakeetOnDisk = ParakeetModels.isDownloaded
            } catch {
                Log.speech.error("Parakeet preload failed: \(error.localizedDescription)")
            }
            isPreloadingParakeet = false
        }
    }

    var body: some View {
        Text("Segure \(settings.hotkeyBinding.displayName) para ditar")

        Divider()

        Picker("Tecla", selection: Binding(
            get: { settings.pushToTalkKey },
            set: { key in
                settings.pushToTalkKey = key
                // Picking a modifier here means abandoning any custom combination —
                // otherwise the choice would appear to do nothing.
                settings.customHotkey = nil
                controller.reloadHotkey()
            }
        )) {
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .disabled(settings.customHotkey != nil)

        if let custom = settings.customHotkey {
            Button("Atalho personalizado: \(custom.displayString) (remover)") {
                settings.customHotkey = nil
                controller.reloadHotkey()
            }
        }

        Picker("Modo", selection: Binding(
            get: { settings.recordingMode },
            set: { mode in
                settings.recordingMode = mode
                controller.reloadHotkey()
            }
        )) {
            ForEach(RecordingMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }

        Toggle("Modo comparação (todos os motores)", isOn: $settings.compareMode)

        if !settings.compareMode {
            Picker("Motor", selection: $settings.engine) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
        }

        Picker("Indicador", selection: $settings.hudStyle) {
            ForEach(HUDStyle.allCases, id: \.self) { style in
                Text(style.displayName).tag(style)
            }
        }

        Toggle("Limpar texto", isOn: $settings.cleanupEnabled)

        if settings.cleanupEnabled {
            Toggle("Limpeza inteligente (IA no dispositivo)", isOn: $settings.smartCleanup)
                .disabled(!FoundationModelFormatter.isAvailable)
            if let reason = FoundationModelFormatter.unavailableReason {
                Text(reason).font(.caption)
            }
        }

        Toggle("Som", isOn: $settings.soundEnabled)

        Divider()

        Button("Mostrar janela de comparação") {
            RunStore.shared.reload()
            openWindow(id: "comparison")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d")

        // Downloading ~470 MB on the first hold would look like a hang, so offer to do it
        // deliberately instead.
        if settings.engine == .parakeet {
            Button(parakeetStatus) { preloadParakeet() }
                .disabled(isPreloadingParakeet || parakeetOnDisk)
        }

        Button("Verificar atualizações…") {
            UpdateManager.shared.checkForUpdates(userInitiated: true)
        }

        Button("Abrir log") {
            NSWorkspace.shared.open(FileLog.url)
        }

        if !Permissions.hasAccessibility {
            Button("Conceder Acessibilidade…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button("Conceder Microfone…") { Permissions.openMicrophoneSettings() }
        }

        Button("Sair do Murmur YouTube") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
