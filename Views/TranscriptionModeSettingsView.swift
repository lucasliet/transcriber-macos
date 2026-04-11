import SwiftUI

struct TranscriptionModeSettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Modo de Transcrição")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                modeRow(
                    mode: .cloudWithFallback,
                    title: "Nuvem + Local",
                    description: "Usa ElevenLabs (cloud) e, se falhar, usa Apple Speech (local)"
                )

                modeRow(
                    mode: .localOnly,
                    title: "Somente Local",
                    description: localOnlyDescription
                )
            }
            .padding(.horizontal, 8)

            if !settingsManager.isLocalSpeechAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Reconhecimento local requer macOS 26+")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, -8)
            }

            Button("Fechar") {
                onClose()
            }
            .keyboardShortcut(.escape)
        }
        .padding(30)
        .frame(width: 420, height: 280)
    }

    private var localOnlyDescription: String {
        if settingsManager.isLocalSpeechAvailable {
            return "Usa apenas Apple Speech (local, sem internet)"
        } else {
            return "Não disponível (requer macOS 26+)"
        }
    }

    private func modeRow(mode: TranscriptionMode, title: String, description: String) -> some View {
        Button {
            settingsManager.transcriptionMode = mode
        } label: {
            HStack(spacing: 12) {
                Image(systemName: settingsManager.transcriptionMode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(settingsManager.transcriptionMode == mode ? .accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(settingsManager.transcriptionMode == mode ? Color.accentColor.opacity(0.1) : Color.clear)
        )
    }
}