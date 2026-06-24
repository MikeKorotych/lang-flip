import AppKit
import Combine
import SwiftUI

/// Always-visible floating "island" at the bottom-center of the screen, in the
/// spirit of Wispr Flow. It morphs smoothly between states:
///   • idle        — a thin capsule, barely there.
///   • idle+hover  — expands to a mic button with a "Dictate <shortcut>" tooltip.
///   • recording   — ✕ (cancel) · live sound waves · ✓ (stop & insert).
///   • transcribing— waves settle into a progress shimmer.
///   • cancelled   — a "Transcript cancelled / Undo" toast (added separately).
///
/// The panel resizes to fit the current state (so it never blocks clicks in a
/// large dead zone), staying anchored to the bottom-center; the SwiftUI content
/// cross-fades between states.
final class DictationIslandController {
    static let shared = DictationIslandController()

    let state = DictationIslandState()
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var levelTimer: Timer?
    private var toastTimer: Timer?

    private init() {}

    // MARK: Lifecycle

    func startIfEnabled() {
        guard Settings.shared.showDictationIsland else { return }
        DispatchQueue.main.async { [self] in
            ensurePanel()
            applyTargetFrame(animated: false)
            panel?.orderFront(nil)
        }
    }

    func setEnabled(_ on: Bool) {
        DispatchQueue.main.async { [self] in
            if on {
                startIfEnabled()
            } else {
                panel?.orderOut(nil)
            }
        }
    }

    // MARK: Panel

    private func ensurePanel() {
        guard panel == nil else { return }

        let host = NSHostingController(rootView: DictationIslandView(state: state))
        let size = IslandMetrics.panelSize(for: state)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel

        // Observe state from the dictation controller + recorder so the island
        // reflects reality without owning the dictation logic.
        NotificationCenter.default.addObserver(
            self, selector: #selector(dictationStateChanged),
            name: .langFlipDictationStateChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(recorderChanged),
            name: .langFlipVoiceRecorderChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(dictationCancelled),
            name: .langFlipDictationCancelled, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Resize / reposition the panel whenever the visible state changes.
        state.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async { self?.applyTargetFrame(animated: true) }
            }
            .store(in: &cancellables)
    }

    @objc private func dictationStateChanged() {
        let ctrl = VoiceDictationController.shared
        DispatchQueue.main.async { [self] in
            if ctrl.isTranscribing {
                state.phase = .transcribing
                stopLevelTimer()
            } else if ctrl.isRecording {
                state.phase = .recording
                startLevelTimer()
            } else {
                state.phase = .idle
                stopLevelTimer()
                state.level = 0
            }
        }
    }

    @objc private func recorderChanged() {
        guard state.phase == .recording else { return }
        DispatchQueue.main.async { [self] in
            state.level = VoiceRecorder.shared.normalizedAveragePower
        }
    }

    @objc private func dictationCancelled() {
        DispatchQueue.main.async { [self] in
            state.showCancelledToast = true
            toastTimer?.invalidate()
            toastTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                self?.dismissToast()
            }
        }
    }

    func dismissToast() {
        toastTimer?.invalidate()
        toastTimer = nil
        state.showCancelledToast = false
    }

    @objc private func screenChanged() {
        applyTargetFrame(animated: false)
    }

    /// While recording, keep the level fresh even between recorder
    /// notifications so the waves never freeze.
    private func startLevelTimer() {
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.state.phase == .recording else { return }
            self.state.level = VoiceRecorder.shared.normalizedAveragePower
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func applyTargetFrame(animated: Bool) {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let size = IslandMetrics.panelSize(for: state)
        let x = screen.frame.midX - size.width / 2
        // Bottom-anchored: the pill sits a fixed distance above the Dock; the
        // panel grows upward (tooltip) without moving the pill.
        let y = screen.visibleFrame.minY + IslandMetrics.bottomInset
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

// MARK: - State

final class DictationIslandState: ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing }

    @Published var phase: Phase = .idle
    @Published var hovering = false
    @Published var level: Double = 0
    @Published var showCancelledToast = false

    /// Whether the expanded (mic) chrome should be shown: on hover while idle.
    var isExpandedIdle: Bool { phase == .idle && hovering && !showCancelledToast }
}

// MARK: - Metrics (shared by the panel sizing + the SwiftUI layout)

enum IslandMetrics {
    static let bottomInset: CGFloat = 16
    /// Transparent padding around the pill so the drop shadow isn't clipped
    /// and the hover/tooltip area has room.
    static let pad: CGFloat = 18

    static let pillHeight: CGFloat = 34
    static let idleWidth: CGFloat = 56
    static let idleHeight: CGFloat = 14
    static let micWidth: CGFloat = 120
    static let recordingWidth: CGFloat = 244
    static let transcribingWidth: CGFloat = 188
    static let toastWidth: CGFloat = 248

    static let tooltipHeight: CGFloat = 28
    static let tooltipGap: CGFloat = 8

    /// Content (pill) size for the current state, excluding padding.
    static func contentSize(for state: DictationIslandState) -> CGSize {
        if state.showCancelledToast {
            return CGSize(width: toastWidth, height: pillHeight)
        }
        switch state.phase {
        case .idle:
            return state.hovering
                ? CGSize(width: micWidth, height: pillHeight)
                : CGSize(width: idleWidth, height: idleHeight)
        case .recording:
            return CGSize(width: recordingWidth, height: pillHeight)
        case .transcribing:
            return CGSize(width: transcribingWidth, height: pillHeight)
        }
    }

    /// Whether a tooltip is shown above the pill (mic hover while idle).
    static func showsTooltip(for state: DictationIslandState) -> Bool {
        state.isExpandedIdle
    }

    /// Full panel size = content + padding (+ tooltip band when shown).
    static func panelSize(for state: DictationIslandState) -> CGSize {
        let content = contentSize(for: state)
        let tooltipBand = showsTooltip(for: state) ? (tooltipHeight + tooltipGap) : 0
        return CGSize(width: content.width + pad * 2,
                      height: content.height + tooltipBand + pad * 2)
    }
}

// MARK: - View

private enum IslandColor {
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let surfaceTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let stroke = Color.white.opacity(0.10)
    static let text = Color.white
    static let textDim = Color.white.opacity(0.55)
    static let accent = Color(red: 0.79, green: 0.62, blue: 0.96) // soft violet, like the refs
    static let cancel = Color.white.opacity(0.16)
    static let confirm = Color.white
}

struct DictationIslandView: View {
    @ObservedObject var state: DictationIslandState

    private var anim: Animation { .spring(response: 0.34, dampingFraction: 0.82) }

    var body: some View {
        VStack(spacing: IslandMetrics.tooltipGap) {
            if IslandMetrics.showsTooltip(for: state) {
                tooltip
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            pill
        }
        .padding(IslandMetrics.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(anim, value: state.phase)
        .animation(anim, value: state.hovering)
        .animation(anim, value: state.showCancelledToast)
        .onHover { state.hovering = $0 }
    }

    // MARK: Pill (state machine)

    @ViewBuilder
    private var pill: some View {
        if state.showCancelledToast {
            toastPill
        } else {
            switch state.phase {
            case .idle:        idlePill
            case .recording:   recordingPill
            case .transcribing: transcribingPill
            }
        }
    }

    private var idlePill: some View {
        ZStack {
            // Mic appears on hover; the bare capsule is the resting state.
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(IslandColor.text)
                .opacity(state.hovering ? 1 : 0)
                .scaleEffect(state.hovering ? 1 : 0.6)
        }
        .frame(width: state.hovering ? IslandMetrics.micWidth : IslandMetrics.idleWidth,
               height: state.hovering ? IslandMetrics.pillHeight : IslandMetrics.idleHeight)
        .background(capsuleBackground)
        .contentShape(Capsule())
        .onTapGesture { VoiceDictationController.shared.toggleRecording() }
    }

    private var recordingPill: some View {
        HStack(spacing: 10) {
            circleButton(system: "xmark", fg: IslandColor.text, bg: IslandColor.cancel) {
                VoiceDictationController.shared.cancel()
            }
            WaveBars(level: state.level, animating: true)
                .frame(maxWidth: .infinity)
            circleButton(system: "checkmark", fg: .black, bg: IslandColor.confirm) {
                VoiceDictationController.shared.stopAndTranscribe()
            }
        }
        .padding(.horizontal, 8)
        .frame(width: IslandMetrics.recordingWidth, height: IslandMetrics.pillHeight)
        .background(capsuleBackground)
    }

    private var transcribingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(IslandColor.text)
            Text("Transcribing…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(IslandColor.text)
        }
        .padding(.horizontal, 14)
        .frame(width: IslandMetrics.transcribingWidth, height: IslandMetrics.pillHeight)
        .background(capsuleBackground)
    }

    private var toastPill: some View {
        HStack(spacing: 10) {
            Text("Transcript cancelled")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(IslandColor.text)
            Spacer(minLength: 4)
            Button {
                VoiceDictationController.shared.undoCancel()
                DictationIslandController.shared.dismissToast()
            } label: {
                Text("Undo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(IslandColor.confirm))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(width: IslandMetrics.toastWidth, height: IslandMetrics.pillHeight)
        .background(capsuleBackground)
    }

    private var tooltip: some View {
        HStack(spacing: 6) {
            Text("Dictate")
                .foregroundColor(IslandColor.text)
            Text(Settings.shared.dictationHandsFreeShortcut.displayName)
                .foregroundColor(IslandColor.accent)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: IslandMetrics.tooltipHeight)
        .background(capsuleBackground)
    }

    // MARK: Building blocks

    private var capsuleBackground: some View {
        Capsule()
            .fill(
                LinearGradient(colors: [IslandColor.surfaceTop, IslandColor.surface],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(Capsule().stroke(IslandColor.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    private func circleButton(system: String, fg: Color, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(fg)
                .frame(width: 26, height: 26)
                .background(Circle().fill(bg))
        }
        .buttonStyle(.plain)
    }
}

/// Live audio-level bars, animated continuously while recording.
private struct WaveBars: View {
    let level: Double
    let animating: Bool

    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3
    private let maxHeight: CGFloat = 22
    private let minHeight: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(IslandColor.text.opacity(0.9))
                        .frame(width: barWidth, height: height(i, t))
                }
            }
        }
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        // Center bars react most; combine the live mic level with a per-bar
        // travelling sine so the waveform looks alive even at a steady level.
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(i) - center) / center           // 0 center … 1 edge
        let envelope = 1.0 - distance * 0.55
        let wobble = 0.45 + 0.55 * abs(sin(t * 6 + Double(i) * 0.7))
        let amp = max(0.06, level) * envelope * (animating ? wobble : 0.3)
        return minHeight + CGFloat(amp) * (maxHeight - minHeight)
    }
}
