import AppKit
import SwiftUI

/// What the notch is showing right now.
///
/// A flattened view of `DictationController.State` plus the transcript: the overlay cares
/// about "is there live text yet", which the controller's state alone doesn't say.
enum NotchState: Equatable {
    case idle
    case recording
    case streaming(String)
    case transcribing
    case success(String)
    case error(String)

    init(state: DictationController.State, transcript: String) {
        switch state {
        case .idle:
            self = .idle
        case .starting:
            self = .recording
        case .listening:
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            self = text.isEmpty ? .recording : .streaming(text)
        case .finishing:
            self = .transcribing
        case .success(let text):
            self = .success(text)
        case .error(let message):
            self = .error(message)
        }
    }
}

/// Live dictation status drawn as an extension of the MacBook's physical notch.
///
/// The layout is three zones — left content, a transparent gap exactly the width of the
/// real notch, right content — so the hardware cutout sits in the middle of the pill
/// instead of covering anything.
struct NotchIndicatorView: View {
    @Bindable var controller: DictationController
    @Bindable var geometry: NotchGeometry

    @State private var dotPulse = false
    @State private var showTranscribedText = false

    private let extensionWidth: CGFloat = 120
    private let contentPadding: CGFloat = 36

    private var notchState: NotchState {
        NotchState(state: controller.state, transcript: controller.transcript)
    }

    private var closedWidth: CGFloat {
        geometry.hasNotch ? geometry.notchWidth + 2 * extensionWidth : 200
    }

    private var isExpanded: Bool {
        switch notchState {
        case .success: showTranscribedText
        case .streaming, .transcribing: true
        default: false
        }
    }

    private var currentWidth: CGFloat {
        if isExpanded { return max(closedWidth, 440) }
        if case .error = notchState { return max(closedWidth, 340) }
        return closedWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBar
                .frame(width: currentWidth, height: geometry.notchHeight)
                .frame(maxWidth: .infinity)

            if case .success(let text) = notchState, showTranscribedText {
                transcriptBody(text, id: "successText")
            }

            if case .streaming(let text) = notchState {
                transcriptBody(text, id: "streamingText")
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
        .onChange(of: notchState) { _, newState in
            switch newState {
            case .recording, .streaming:
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            case .success:
                dotPulse = false
                withAnimation(.easeOut(duration: 0.25)) { showTranscribedText = true }
            default:
                dotPulse = false
                showTranscribedText = false
            }
        }
        .animation(.easeInOut(duration: 1.0), value: dotPulse)
    }

    /// Scrolls itself to the bottom as text arrives, so the newest words stay visible.
    private func transcriptBody(_ text: String, id: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentPadding)
                    .padding(.vertical, 14)
                    .id(id)
            }
            .frame(maxHeight: 80)
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                leftStatus
                leftContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 28)
            // Clear of the notch's own top corner curve, which would clip the content.
            .padding(.top, 20)

            if geometry.hasNotch {
                Color.clear.frame(width: geometry.notchWidth)
            }

            rightContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 28)
                .padding(.top, 20)
        }
    }

    /// The icon of the app the text is going to land in, when we know it.
    @ViewBuilder
    private var leftStatus: some View {
        if let icon = controller.activeAppIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay {
                    switch notchState {
                    case .transcribing:
                        Color.black.opacity(0.4)
                    case .error:
                        RoundedRectangle(cornerRadius: 3).stroke(.red, lineWidth: 1.5)
                    default:
                        Color.clear
                    }
                }
        } else {
            statusGlyph
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch notchState {
        case .recording:
            pulsingDot(.red)
        case .streaming:
            pulsingDot(.blue)
        case .transcribing:
            ProgressView().controlSize(.mini).tint(.white)
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

    @ViewBuilder
    private var leftContent: some View {
        switch notchState {
        case .recording, .streaming:
            HStack(spacing: 4) {
                Text(Self.duration(controller.recordingDuration))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                // A latched recording looks identical to a held one otherwise, and the key
                // to end it is no longer down — the user needs to be told.
                if controller.isLatched {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .fixedSize()
        case .transcribing:
            label("Transcrevendo", .white.opacity(0.7))
        case .success:
            label("Transcrito", .green)
        case .error:
            label("Erro", .red)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        switch notchState {
        case .recording:
            pulsingDot(.red)
        case .streaming:
            pulsingDot(.blue)
        case .transcribing:
            ProgressView().controlSize(.mini).tint(.white)
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

    private func pulsingDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dotPulse ? 1.0 : 0.3)
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .fixedSize()
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
