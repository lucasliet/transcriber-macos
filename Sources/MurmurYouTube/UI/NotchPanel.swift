import AppKit
import Observation
import SwiftUI

/// Measurements of the physical notch on whichever screen the overlay is using.
@MainActor
@Observable
final class NotchGeometry {
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 38
    var hasNotch = false

    /// `safeAreaInsets.top` is non-zero only on a display with a real cutout, and the two
    /// `auxiliaryTop*Area` rects are the usable menu-bar strips either side of it — so the
    /// gap between them is the notch itself. There is no direct API for its width.
    func update(for screen: NSScreen) {
        hasNotch = screen.safeAreaInsets.top > 0
        if hasNotch,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right + 4
        } else {
            notchWidth = 0
        }
        notchHeight = hasNotch ? screen.safeAreaInsets.top : 32
    }
}

/// Hosts `NotchIndicatorView` in a borderless panel pinned to the top of the screen.
///
/// Like `HUDPanel`, this must never become key: taking focus would pull it away from the
/// text field the transcript is about to be injected into.
@MainActor
final class NotchPanel: NSPanel {
    private static let panelWidth: CGFloat = 500
    private static let panelHeight: CGFloat = 500

    private let geometry = NotchGeometry()

    /// True when this display actually has a notch to grow out of. `AppDelegate` uses it to
    /// fall back to the floating HUD on an external monitor or a non-notch Mac, rather than
    /// showing nothing at all the way the old app did.
    var canPresent: Bool {
        geometry.update(for: Self.resolveScreen())
        return geometry.hasNotch
    }

    init(controller: DictationController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // Above the menu bar — the overlay has to sit on top of the bar it grows out of.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: NotchIndicatorView(controller: controller, geometry: geometry))
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        let screen = Self.resolveScreen()
        geometry.update(for: screen)
        guard geometry.hasNotch else {
            dismiss()
            return
        }

        let frame = screen.frame
        setFrame(
            NSRect(
                x: frame.midX - Self.panelWidth / 2,
                y: frame.origin.y + frame.height - Self.panelHeight,
                width: Self.panelWidth,
                height: Self.panelHeight
            ),
            display: true
        )
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }

    /// Prefer a screen that actually has a notch — on a clamshell-plus-external setup the
    /// built-in display is usually not `NSScreen.main`.
    private static func resolveScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
