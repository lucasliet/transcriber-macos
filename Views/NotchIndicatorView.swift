import SwiftUI
import AppKit

enum NotchState: Equatable {
    case idle
    case recording
    case transcribing
    case success(String)
    case error(String)
}

struct NotchIndicatorView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var geometry: NotchGeometry
    @State private var dotPulse = false
    @State private var showTranscribedText = false

    private let extensionWidth: CGFloat = 75
    private let contentPadding: CGFloat = 28

    private var notchState: NotchState {
        appState.notchState
    }

    private var closedWidth: CGFloat {
        geometry.hasNotch ? geometry.notchWidth + 2 * extensionWidth : 200
    }

    private var isExpanded: Bool {
        if case .success = notchState { return showTranscribedText }
        return false
    }

    private var currentWidth: CGFloat {
        if isExpanded { return max(closedWidth, 400) }
        if case .error = notchState { return max(closedWidth, 340) }
        return closedWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBar
                .frame(width: currentWidth, height: geometry.notchHeight)
                .frame(maxWidth: .infinity)

            if case .success(let text) = notchState, showTranscribedText {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, contentPadding)
                        .padding(.vertical, 14)
                }
                .frame(maxHeight: 80)
            }

            if case .error(let message) = notchState {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: currentWidth)
        .background(.black)
        .clipShape(NotchShape(
            topCornerRadius: isExpanded ? 19 : 6,
            bottomCornerRadius: isExpanded ? 24 : 14
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: showTranscribedText)
        .animation(.easeInOut(duration: 0.2), value: notchState)
        .onChange(of: notchState) { newState in
            switch newState {
            case .recording:
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            case .success:
                dotPulse = false
                withAnimation(.easeOut(duration: 0.25)) {
                    showTranscribedText = true
                }
            default:
                dotPulse = false
                showTranscribedText = false
            }
        }
        .animation(.easeInOut(duration: 1.0), value: dotPulse)
    }

    // MARK: - Status bar (three-zone layout)

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 0) {
            // Left zone: icon + content
            HStack(spacing: 6) {
                leftStatus
                leftContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 20)

            // Center notch spacer
            if geometry.hasNotch {
                Color.clear
                    .frame(width: geometry.notchWidth)
            }

            // Right zone
            rightContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 34)
        }
    }

    // MARK: - Left status icon

    @ViewBuilder
    private var leftStatus: some View {
        if let icon = appState.activeAppIcon {
            switch notchState {
            case .recording:
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            case .transcribing:
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(Color.black.opacity(0.4))
            case .error:
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(.red, lineWidth: 1.5)
                    )
            default:
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        } else {
            switch notchState {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .opacity(dotPulse ? 1.0 : 0.3)
            case .transcribing:
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .error:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: - Left content

    @ViewBuilder
    private var leftContent: some View {
        switch notchState {
        case .recording:
            Text(formatDuration(appState.recordingDuration))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize()
        case .transcribing:
            Text("Transcrevendo")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize()
        case .success:
            Text("Transcrito")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.green)
                .fixedSize()
        case .error:
            Text("Erro")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.red)
                .fixedSize()
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Right content

    @ViewBuilder
    private var rightContent: some View {
        switch notchState {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
                .opacity(dotPulse ? 1.0 : 0.3)
        case .transcribing:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
