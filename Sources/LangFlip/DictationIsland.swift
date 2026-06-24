import AppKit
import Combine
import SwiftUI

/// Always-visible floating "island" at the bottom-center of the screen, in the
/// spirit of Wispr Flow. It morphs smoothly between states, every transition
/// growing out of (and collapsing back into) the resting pill's centre:
///   • idle        — a small dark capsule, barely there.
///   • idle+hover  — expands to a mic button with a "Dictate <shortcut>" tooltip.
///   • recording   — ✕ (cancel) · live sound waves · ✓ (stop & insert).
///   • transcribing— a small progress label.
///   • cancelled   — a "Transcript cancelled / Undo" toast.
///
/// The panel is anchored by the *pill centre* (a fixed screen point), so it
/// expands symmetrically rather than sliding in from a screen edge. It resizes
/// to fit the current state so it never blocks a large dead zone.
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
        let pillH = IslandMetrics.contentSize(for: state).height
        // Anchor by the pill centre: a fixed screen point near the bottom. The
        // pill sits `pad + pillH/2` above the panel's bottom edge, so we place
        // the panel so that point lands on `restingCenterY` regardless of state.
        let restingCenterY = screen.visibleFrame.minY + IslandMetrics.bottomInset + IslandMetrics.restingPillHeight / 2
        let x = screen.frame.midX - size.width / 2
        let y = restingCenterY - IslandMetrics.pad - pillH / 2
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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

    var isExpandedIdle: Bool { phase == .idle && hovering && !showCancelledToast }
}

// MARK: - Metrics (shared by panel sizing + SwiftUI layout)

enum IslandMetrics {
    static let bottomInset: CGFloat = 14
    static let pad: CGFloat = 16
    /// The notional pill height used to fix the resting centre point.
    static let restingPillHeight: CGFloat = 30

    static let pillHeight: CGFloat = 30
    static let idleWidth: CGFloat = 46
    static let idleHeight: CGFloat = 12
    static let micWidth: CGFloat = 104
    static let recordingWidth: CGFloat = 216
    static let transcribingWidth: CGFloat = 168
    static let toastWidth: CGFloat = 232

    static let tooltipWidth: CGFloat = 188
    static let tooltipHeight: CGFloat = 26
    static let tooltipGap: CGFloat = 7

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

    static func showsTooltip(for state: DictationIslandState) -> Bool {
        state.isExpandedIdle
    }

    static func panelSize(for state: DictationIslandState) -> CGSize {
        let content = contentSize(for: state)
        let tooltipBand = showsTooltip(for: state) ? (tooltipHeight + tooltipGap) : 0
        // Width must fit the (wider) tooltip so "Dictate <shortcut>" isn't clipped.
        let width = max(content.width, showsTooltip(for: state) ? tooltipWidth : 0)
        return CGSize(width: width + pad * 2,
                      height: content.height + tooltipBand + pad * 2)
    }
}

// MARK: - View

private enum IslandColor {
    // Near-black surface, per design feedback.
    static let surface = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let surfaceTop = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white
    static let accent = Color(red: 0.80, green: 0.64, blue: 0.97) // soft violet
    static let cancel = Color.white.opacity(0.16)
    static let confirm = Color.white
}

struct DictationIslandView: View {
    @ObservedObject var state: DictationIslandState

    /// One key whose change drives the in-view crossfade; matches the panel's
    /// own 0.18s easeOut so AppKit + SwiftUI move together.
    private var stateKey: String {
        "\(state.phase)-\(state.hovering)-\(state.showCancelledToast)"
    }
    private var anim: Animation { .easeOut(duration: 0.18) }

    var body: some View {
        VStack(spacing: IslandMetrics.tooltipGap) {
            if IslandMetrics.showsTooltip(for: state) {
                tooltip.transition(.opacity)
            }
            pill
        }
        .padding(IslandMetrics.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(anim, value: stateKey)
        .onHover { state.hovering = $0 }
    }

    // The capsule fills the panel width (which the controller animates), so the
    // pill grows from its centre as a single source of truth — no SwiftUI
    // width animation fighting the panel's.
    private var pill: some View {
        ZStack {
            innerContent
        }
        .frame(maxWidth: .infinity)
        .frame(height: IslandMetrics.contentSize(for: state).height)
        .background(capsuleBackground)
        .contentShape(Capsule())
        .onTapGesture {
            // Whole-pill tap starts dictation only in the idle states; the
            // recording/toast states have their own ✕/✓/Undo targets.
            if state.phase == .idle && !state.showCancelledToast {
                VoiceDictationController.shared.toggleRecording()
            }
        }
    }

    @ViewBuilder
    private var innerContent: some View {
        if state.showCancelledToast {
            toastContent
        } else {
            switch state.phase {
            case .idle:
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(IslandColor.text)
                    .opacity(state.hovering ? 1 : 0)
                    .scaleEffect(state.hovering ? 1 : 0.6)
            case .recording:
                recordingContent
            case .transcribing:
                transcribingContent
            }
        }
    }

    private var recordingContent: some View {
        HStack(spacing: 8) {
            circleButton(system: "xmark", fg: IslandColor.text, bg: IslandColor.cancel) {
                VoiceDictationController.shared.cancel()
            }
            WaveBars(level: state.level)
                .frame(maxWidth: .infinity)
            circleButton(system: "checkmark", fg: .black, bg: IslandColor.confirm) {
                VoiceDictationController.shared.stopAndTranscribe()
            }
        }
        .padding(.horizontal, 6)
    }

    private var transcribingContent: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(IslandColor.text)
            Text("Transcribing…")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(IslandColor.text)
        }
        .padding(.horizontal, 12)
    }

    private var toastContent: some View {
        HStack(spacing: 10) {
            Text("Transcript cancelled")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(IslandColor.text)
            Spacer(minLength: 4)
            Button {
                VoiceDictationController.shared.undoCancel()
                DictationIslandController.shared.dismissToast()
            } label: {
                Text("Undo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background(Capsule().fill(IslandColor.confirm))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }

    private var tooltip: some View {
        HStack(spacing: 6) {
            Text("Dictate")
                .foregroundColor(IslandColor.text)
            Text(Settings.shared.dictationHandsFreeShortcut.displayName)
                .foregroundColor(IslandColor.accent)
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: IslandMetrics.tooltipHeight)
        .background(capsuleBackground)
    }

    private var capsuleBackground: some View {
        Capsule()
            .fill(
                LinearGradient(colors: [IslandColor.surfaceTop, IslandColor.surface],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(Capsule().stroke(IslandColor.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 9, y: 3)
    }

    private func circleButton(system: String, fg: Color, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(fg)
                .frame(width: 24, height: 24)
                .background(Circle().fill(bg))
        }
        .buttonStyle(.plain)
    }
}

/// Live audio-level bars, animated continuously while recording. Tuned for a
/// strong, lively response to the mic.
private struct WaveBars: View {
    let level: Double

    private let barCount = 13
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3
    private let maxHeight: CGFloat = 24
    private let minHeight: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(IslandColor.text)
                        .frame(width: barWidth, height: height(i, t))
                }
            }
        }
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        // Boost the (often small) normalized level so quiet speech still moves
        // the bars a lot; keep a lively idle shimmer when near-silent.
        let boosted = min(1.0, max(0.18, level * 2.6))
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(i) - center) / center        // 0 centre … 1 edge
        let envelope = 1.0 - distance * 0.45
        let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 0.8)
        let amp = boosted * envelope * (0.45 + 0.55 * wobble)
        return minHeight + CGFloat(amp) * (maxHeight - minHeight)
    }
}
