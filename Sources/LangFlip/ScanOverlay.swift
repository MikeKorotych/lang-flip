import AppKit
import SwiftUI

/// Floating "scanning" overlay shown WHILE the screenshot-to-text (OCR) feature
/// is processing. Unlike `FlipOverlay` (a one-shot ~1 s confirmation), this has
/// an explicit lifecycle: `begin()` fades the scan-text icon in and lets it
/// levitate (a gentle bob + breathe) for as long as the AI is working, then
/// `finish()` fades it back out. Every `begin()` should be matched by a
/// `finish()`; a safety timer hides it if a `finish()` is ever dropped.
final class ScanOverlay {
    static let shared = ScanOverlay()

    private let state = ScanOverlayState()
    private var window: NSPanel?
    private var safetyTimer: Timer?

    private static let fadeOutDuration: TimeInterval = 0.32
    private static let safetyTimeout: TimeInterval = 25
    private static let bottomInset: CGFloat = 28
    /// Panel side. The SwiftUI root is pinned to exactly this so the hosting
    /// view never shrinks to fit content and clip the tile at the top of its bob.
    static let panelSize: CGFloat = 220

    private init() {}

    /// Show the overlay and start levitating. Call when OCR processing starts.
    func begin() {
        DispatchQueue.main.async { [self] in
            ensureWindow()
            position(window)
            state.start()
            window?.orderFront(nil)
            armSafetyTimer()
        }
    }

    /// Fade the overlay out. Call when OCR processing finishes (success or fail).
    func finish() {
        DispatchQueue.main.async { [self] in
            safetyTimer?.invalidate()
            safetyTimer = nil
            guard state.visible else { return }
            state.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutDuration + 0.05) { [weak self] in
                guard let self else { return }
                if !self.state.visible { self.window?.orderOut(nil) }
            }
        }
    }

    private func armSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: Self.safetyTimeout, repeats: false) { [weak self] _ in
            self?.finish()
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let host = NSHostingController(rootView: ScanOverlayView(state: state))
        // Generous panel so the bob, sway, tilt, breathe and soft shadow all
        // have room — the window clips anything past its content rect, which is
        // what was cropping the icon at the top of the bob.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize),
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
        guard let panel else { return }
        let screen = screenForOverlay()
        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.minY + Self.bottomInset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenForOverlay() -> NSScreen {
        if let windowFrame = AppContext.frontmostWindowFrame() {
            let center = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
            ?? NSScreen()
    }

    /// The dedicated scan-text glyph. Loaded from the app bundle's Resources
    /// (installed `.app`) first, then the SPM module bundle (dev runs from
    /// `.build`), falling back to the app icon until the asset is added.
    static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "scan-text-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.module.url(forResource: "scan-text-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppIcon") ?? NSApp.applicationIconImage ?? NSImage()
    }()

    /// The magnifying-glass glyph that "searches" over the tile during OCR.
    /// Same load path as `icon`, falling back to the SF Symbol if absent.
    static let magnifier: NSImage = {
        if let url = Bundle.main.url(forResource: "search-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.module.url(forResource: "search-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage()
    }()
}

// MARK: - State

private final class ScanOverlayState: ObservableObject {
    /// Bumped on each `begin()` so the view (re)plays its intro + levitation.
    @Published var token: Int = 0
    /// True between `begin()` and `finish()`; flipping to false plays the outro.
    @Published var visible: Bool = false

    func start() {
        visible = true
        token &+= 1
    }

    func stop() {
        visible = false
    }
}

// MARK: - View

private struct ScanOverlayView: View {
    @ObservedObject var state: ScanOverlayState

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.55
    @State private var bob: CGFloat = 0
    @State private var sway: CGFloat = 0
    @State private var tilt: Double = 0
    @State private var breathe: CGFloat = 1
    @State private var shadowRadius: CGFloat = 9
    @State private var magX: CGFloat = 0
    @State private var magY: CGFloat = 0
    @State private var magScale: CGFloat = 1

    private static let tileSize: CGFloat = 92

    var body: some View {
        ZStack {
            tile
            magnifier
        }
        .opacity(opacity)
        .frame(width: ScanOverlay.panelSize, height: ScanOverlay.panelSize)
        .onChange(of: state.token) { _ in playIn() }
        .onChange(of: state.visible) { isVisible in
            if !isVisible { playOut() }
        }
        .onAppear { if state.visible { playIn() } }
    }

    /// The scan-text tile, gently levitating.
    private var tile: some View {
        Image(nsImage: ScanOverlay.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: Self.tileSize, height: Self.tileSize)
            .scaleEffect(scale * breathe)
            .rotationEffect(.degrees(tilt))
            .offset(x: sway, y: bob)
            .shadow(color: .black.opacity(0.28), radius: shadowRadius, x: 0, y: 9)
    }

    /// A magnifying glass that wanders over the tile, "searching" for text.
    /// Mirrored horizontally (`-magScale` on x) so the handle sits bottom-right,
    /// per the source art. It follows the tile's float (`sway`/`bob`) plus its
    /// own search offset so it always stays over the icon.
    private var magnifier: some View {
        Image(nsImage: ScanOverlay.magnifier)
            .resizable()
            .interpolation(.high)
            .frame(width: 58, height: 58)
            .scaleEffect(x: -magScale, y: magScale)
            .offset(x: sway + magX, y: bob + magY)
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4)
    }

    private func playIn() {
        // Hard reset (no animation) to a small, tilted, transparent start.
        opacity = 0
        scale = 0.55
        bob = 0
        sway = 0
        tilt = -8
        breathe = 1
        shadowRadius = 9
        magX = -18
        magY = -10
        magScale = 1

        // Entrance — a springy pop that overshoots and settles, plus a quick
        // fade. The overshoot is what gives it life instead of a flat dissolve.
        withAnimation(.easeOut(duration: 0.26)) {
            opacity = 1
        }
        withAnimation(.interpolatingSpring(stiffness: 230, damping: 12, initialVelocity: 6)) {
            scale = 1
            tilt = 0
        }

        // Idle levitation — several loops with deliberately different, non-
        // multiple periods (1.4 / 1.75 / 2.05 / 2.5 / 1.55 s) so the combined
        // motion never lands in the same pose twice and reads as alive rather
        // than a smooth metronome. Each starts after the entrance settles.
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true).delay(0.34)) {
            bob = -15
        }
        withAnimation(.easeInOut(duration: 2.05).repeatForever(autoreverses: true).delay(0.34)) {
            sway = 6
        }
        withAnimation(.easeInOut(duration: 1.75).repeatForever(autoreverses: true).delay(0.34)) {
            tilt = 4
        }
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true).delay(0.34)) {
            breathe = 1.05
        }
        withAnimation(.easeInOut(duration: 1.55).repeatForever(autoreverses: true).delay(0.34)) {
            shadowRadius = 19
        }
        // Magnifier search — x and y wander on deliberately different periods
        // (1.3 / 1.9 s) so the glass traces a wandering path over the tile
        // instead of a straight line; a gentle zoom pulse reads as "inspecting".
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true).delay(0.3)) {
            magX = 18
        }
        withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true).delay(0.3)) {
            magY = 12
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(0.3)) {
            magScale = 1.12
        }
    }

    private func playOut() {
        // Fade out + a small drop. The idle loops keep running underneath but
        // are invisible once opacity hits 0; the next intro resets everything.
        withAnimation(.easeIn(duration: 0.3)) {
            opacity = 0
            scale = 0.88
            bob = 6
        }
    }
}
