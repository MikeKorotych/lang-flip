import AppKit
import Combine
import SwiftUI

/// HUD-style "we just changed your text" overlay. Pops up at the
/// bottom-centre of the main screen for 1.5 s every time LangFlip
/// rewrites a word, then fades out. Non-activating panel — doesn't
/// steal focus.
///
/// Off-switch: Settings.showOverlay (default on).
final class FlipOverlay {
    static let shared = FlipOverlay()

    private let state = FlipOverlayState()
    private var window: NSPanel?
    private var hideTimer: Timer?

    /// How long the overlay stays fully visible before fading out.
    private static let visibleDuration: TimeInterval = 1.5

    private init() {}

    /// Show the overlay for a layout flip. `original` is what the user
    /// typed; `converted` is what LangFlip wrote in its place.
    func showFlip(original: String, converted: String) {
        present(.init(original: original, converted: converted, mode: .flip))
    }

    /// Show the overlay for a sticky-shift correction (WOrld → World).
    func showCapsFix(original: String, corrected: String) {
        present(.init(original: original, converted: corrected, mode: .capsFix))
    }

    /// Show the overlay when a flip is rolled back via Backspace.
    func showRollback(restored: String) {
        present(.init(original: restored, converted: restored, mode: .rollback))
    }

    private func present(_ content: OverlayContent) {
        guard Settings.shared.showOverlay else { return }

        DispatchQueue.main.async { [self] in
            ensureWindow()
            state.content = content
            window?.orderFront(nil)
            position(window)
            hideTimer?.invalidate()
            hideTimer = Timer.scheduledTimer(withTimeInterval: Self.visibleDuration, repeats: false) { [weak self] _ in
                self?.hide()
            }
        }
    }

    private func hide() {
        DispatchQueue.main.async { [self] in
            // SwiftUI handles the opacity fade via .transition; the window
            // stays open until the animation finishes (~250ms), then we
            // fully order it out.
            state.content = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.state.content == nil {
                    self?.window?.orderOut(nil)
                }
            }
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let host = NSHostingController(rootView: FlipOverlayView(state: state))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 70),
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
        panel.hasShadow = false  // SwiftUI shadow draws inside the rounded card
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        window = panel
    }

    /// Bottom-centre of the main screen, slightly above the Dock area.
    private func position(_ panel: NSPanel?) {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - State

private final class FlipOverlayState: ObservableObject {
    @Published var content: OverlayContent?
}

private struct OverlayContent: Equatable {
    enum Mode { case flip, capsFix, rollback }

    let original: String
    let converted: String
    let mode: Mode
}

// MARK: - View

private struct FlipOverlayView: View {
    @ObservedObject var state: FlipOverlayState

    var body: some View {
        ZStack {
            if let content = state.content {
                card(for: content)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: state.content)
    }

    @ViewBuilder
    private func card(for content: OverlayContent) -> some View {
        HStack(spacing: 10) {
            switch content.mode {
            case .flip:
                Text(content.original)
                    .strikethrough(color: .secondary)
                    .foregroundColor(.secondary)
                Image(systemName: "arrow.right")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text(content.converted)
                    .fontWeight(.semibold)
            case .capsFix:
                Image(systemName: "textformat")
                    .foregroundColor(.secondary)
                Text(content.original)
                    .strikethrough(color: .secondary)
                    .foregroundColor(.secondary)
                Image(systemName: "arrow.right")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text(content.converted)
                    .fontWeight(.semibold)
            case .rollback:
                Image(systemName: "arrow.uturn.backward")
                    .foregroundColor(.orange)
                Text("Reverted")
                    .foregroundColor(.secondary)
                Text(content.converted)
                    .fontWeight(.semibold)
            }
        }
        .font(.system(size: 14, design: .monospaced))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        )
    }
}
