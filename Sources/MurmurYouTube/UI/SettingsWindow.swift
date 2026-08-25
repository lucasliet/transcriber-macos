import SwiftUI

/// Settings — binding, recording mode, engine, overlay and cleanup. Opens on ⌘, via the
/// standard `Settings` scene, so the system wires up the menu item and the shortcut.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.wide) {
                    hotkeyPanel
                    recordingModePanel
                    enginePanel
                    overlayPanel
                    cleanupPanel
                }
                .padding(DS.Space.panel)
            }
        }
        .frame(width: 560, height: 720)
    }

    // MARK: - Hotkey

    private var hotkeyPanel: some View {
        panel(label: "Atalho") {
            HStack(spacing: DS.Space.snug) {
                ForEach(PushToTalkKey.allCases, id: \.self) { key in
                    choice(
                        title: key.displayName,
                        isSelected: settings.customHotkey == nil && settings.pushToTalkKey == key
                    ) {
                        settings.pushToTalkKey = key
                        settings.customHotkey = nil
                        controller.reloadHotkey()
                    }
                }
            }

            HotkeyRecorder(combination: Binding(
                get: { settings.customHotkey },
                set: { combination in
                    settings.customHotkey = combination
                    controller.reloadHotkey()
                }
            ))

            note("Segure esta tecla em qualquer lugar para ditar. O botão Gravar da janela "
                + "funciona independentemente do que estiver em foco. Uma combinação "
                + "personalizada (⌥⌘T, por exemplo) substitui a tecla modificadora.")
        }
    }

    // MARK: - Recording mode

    private var recordingModePanel: some View {
        panel(label: "Modo de gravação") {
            HStack(spacing: DS.Space.snug) {
                ForEach(RecordingMode.allCases, id: \.self) { mode in
                    choice(title: mode.displayName, isSelected: settings.recordingMode == mode) {
                        settings.recordingMode = mode
                        controller.reloadHotkey()
                    }
                }
            }
            note(settings.recordingMode.blurb)
        }
    }

    // MARK: - Engine

    private var enginePanel: some View {
        panel(label: "Modelo") {
            HStack(spacing: DS.Space.snug) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { engine in
                    choice(title: engine.shortName, isSelected: settings.engine == engine) {
                        settings.engine = engine
                    }
                }
            }
            note(settings.engine.blurb)
        }
    }

    // MARK: - Overlay

    private var overlayPanel: some View {
        panel(label: "Indicador") {
            HStack(spacing: DS.Space.snug) {
                ForEach(HUDStyle.allCases, id: \.self) { style in
                    choice(title: style.displayName, isSelected: settings.hudStyle == style) {
                        settings.hudStyle = style
                    }
                }
            }
            note("O indicador no notch cresce a partir do recorte físico do MacBook e mostra "
                + "o ícone do app que vai receber o texto. Em telas sem notch o painel "
                + "flutuante é usado automaticamente.")
        }
    }

    // MARK: - Cleanup

    private var cleanupPanel: some View {
        panel(label: "Limpeza") {
            Toggle(isOn: $settings.cleanupEnabled) {
                Silkscreen(text: "Limpar transcrições")
            }
            .toggleStyle(.switch)
            note("Remove hesitações, corrige espaçamento e pontuação. As correções do "
                + "dicionário são aplicadas de qualquer forma.")
        }
    }

    // MARK: - Building blocks

    private func choice(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        TransportKey(title: title, isEngaged: isSelected, engagedColor: DS.Color.ink, action: action)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(DS.Color.selection)
                }
            }
    }

    private func panel<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Silkscreen(text: label, large: true)
            content()
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrushedPanel())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
