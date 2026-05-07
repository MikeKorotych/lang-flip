import AppKit
import SwiftUI

/// Cute, near-invisible visual confirmation that LangFlip just rewrote
/// some text. The app icon pops up at the bottom-centre of the screen,
/// bounces, and does a full 360° flip on the Y axis before fading out.
/// Total wall-clock about 1 second.
///
/// Off by default — the icon-style overlay is more of a delight than a
/// utility, and continuous flipping while typing in the wrong layout
/// could be distracting. Opt in via Preferences > Behavior.
final class FlipOverlay {
    static let shared = FlipOverlay()

    private let state = FlipOverlayState()
    private var window: NSPanel?
    private var hideTimer: Timer?

    /// Wall-clock budget: spring intro ≈ 0.55 s, linger 0.25 s, fade 0.25 s.
    private static let lingerAfterAnimation: TimeInterval = 0.5
    private static let fadeOutDuration: TimeInterval = 0.25

    private init() {}

    /// Trigger the overlay. The animation kicks off automatically inside
    /// the SwiftUI view as soon as the window appears, so callers don't
    /// have to manage frames or timing.
    func show() {
        guard Settings.shared.showOverlay else { return }

        DispatchQueue.main.async { [self] in
            ensureWindow()
            position(window)
            state.bumpToken()
            window?.orderFront(nil)
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.lingerAfterAnimation, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func hide() {
        DispatchQueue.main.async { [self] in
            state.requestFadeOut()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutDuration + 0.05) { [weak self] in
                guard let self else { return }
                if self.state.shouldRemainHidden {
                    self.window?.orderOut(nil)
                }
            }
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let host = NSHostingController(rootView: FlipOverlayView(state: state))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        window = panel
    }

    private func position(_ panel: NSPanel?) {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 100
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - State

private final class FlipOverlayState: ObservableObject {
    /// Bumped every time we want to (re)play the animation. The view
    /// observes this and resets its internal animation phase to "intro".
    @Published var animationToken: Int = 0
    @Published var shouldRemainHidden: Bool = true

    func bumpToken() {
        shouldRemainHidden = false
        animationToken &+= 1
    }

    func requestFadeOut() {
        shouldRemainHidden = true
    }
}

// MARK: - View

private struct FlipOverlayView: View {
    @ObservedObject var state: FlipOverlayState

    @State private var scale: CGFloat = 0.4
    @State private var rotation: Double = 0
    @State private var yOffset: CGFloat = 12
    @State private var opacity: Double = 0

    var body: some View {
        Image(nsImage: appIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: 80, height: 80)
            .scaleEffect(scale)
            .offset(y: yOffset)
            .rotation3DEffect(.degrees(rotation), axis: (x: 0, y: 1, z: 0))
            .opacity(opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: state.animationToken) { _ in playIntro() }
            .onChange(of: state.shouldRemainHidden) { hidden in
                if hidden { playOutro() }
            }
            .onAppear { playIntro() }
    }

    private var appIcon: NSImage {
        NSImage(named: "AppIcon") ?? NSApp.applicationIconImage ?? NSImage()
    }

    private func playIntro() {
        // Reset to a slightly-low, small, mid-rotation start state.
        scale = 0.4
        rotation = 0
        yOffset = 12
        opacity = 0

        // Spring up, full flip on Y.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) {
            scale = 1.0
            rotation = 360
            yOffset = 0
            opacity = 1
        }
    }

    private func playOutro() {
        withAnimation(.easeOut(duration: 0.25)) {
            opacity = 0
            scale = 0.85
            yOffset = 6
        }
    }
}
