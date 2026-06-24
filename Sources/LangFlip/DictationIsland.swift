import AppKit
import Combine
import SwiftUI

/// Always-visible floating "island" at the bottom-center of the screen, in the
/// spirit of Wispr Flow. States, every transition growing out of / collapsing
/// back into the resting pill's centre:
///   • idle        — a small dark capsule.
///   • idle+hover  — the capsule grows in place into a ~round mic button, with a
///                   "Dictate <shortcut>" tooltip above it.
///   • recording   — ✕ (cancel) · live sound waves · ✓ (stop & insert).
///   • transcribing— a small progress label.
///   • cancelled   — a "Transcript cancelled / Undo" toast.
///
/// The NSPanel is a FIXED size/position (never animated), so SwiftUI animates
/// the pill purely in place from its centre — no sliding from a screen edge.
/// A global mouse monitor makes the panel click-through everywhere except over
/// the pill, so the always-on window never blocks a dead zone.
final class DictationIslandController {
    static let shared = DictationIslandController()

    let state = DictationIslandState()
    private var panel: NSPanel?
    private var levelTimer: Timer?
    private var toastTimer: Timer?
    private var mouseMonitors: [Any] = []

    private init() {}

    // MARK: Lifecycle

    func startIfEnabled() {
        guard Settings.shared.showDictationIsland else { return }
        DispatchQueue.main.async { [self] in
            ensurePanel()
            positionPanel()
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
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: IslandMetrics.panelSize),
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
        panel.ignoresMouseEvents = true   // pass-through by default; on over the pill
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

        // Drive hover + click-through from the global mouse position (the panel
        // is interactive only while the cursor is over the pill).
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.updateHover() }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) {
            mouseMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            self?.updateHover(); return e
        }) {
            mouseMonitors.append(l)
        }
    }

    private func updateHover() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation                 // screen coords, bottom-left
        let pad = IslandMetrics.pad
        // Detection footprint: current pill width (so ✕/✓ stay clickable while
        // recording), but at least the mic size when idle to avoid flicker.
        let base = IslandMetrics.contentSize(for: state).width
        let detW = (state.phase == .idle && !state.showCancelledToast
                    ? max(base, IslandMetrics.micWidth) : base) + 20
        let detH = IslandMetrics.pillSlotHeight + 16
        let rect = CGRect(x: panel.frame.midX - detW / 2,
                          y: panel.frame.minY + pad - 8,
                          width: detW, height: detH)
        let inside = rect.contains(mouse)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if state.phase == .idle && !state.showCancelledToast, state.hovering != inside {
            state.hovering = inside
        }
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
            toastTimer = Timer.scheduledTimer(withTimeInterval: IslandMetrics.toastDuration, repeats: false) { [weak self] _ in
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
        positionPanel()
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

    /// Fixed placement: bottom-centre of the screen. Never animated.
    private func positionPanel() {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let size = IslandMetrics.panelSize
        let x = screen.frame.midX - size.width / 2
        // The pill slot sits `pad` above the panel bottom; place the panel so
        // the pill rests `bottomInset` above the Dock.
        let y = screen.visibleFrame.minY + IslandMetrics.bottomInset - IslandMetrics.pad
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
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

// MARK: - Metrics

enum IslandMetrics {
    static let bottomInset: CGFloat = 14
    static let pad: CGFloat = 16
    static let pillHeight: CGFloat = 32
    static let pillSlotHeight: CGFloat = 32     // reserved vertical slot (pill centred in it)

    static let idleWidth: CGFloat = 40
    static let idleHeight: CGFloat = 12
    static let micWidth: CGFloat = 34           // ~round mic button
    static let recordingWidth: CGFloat = 156    // compact: little slack around the waves
    static let transcribingWidth: CGFloat = 164
    static let toastWidth: CGFloat = 228        // snug: "Transcript cancelled" + Undo, minimal gap

    static let tooltipWidth: CGFloat = 188
    static let tooltipHeight: CGFloat = 26
    static let tooltipGap: CGFloat = 7

    /// How long the "Transcript cancelled" toast lives before it auto-dismisses.
    static let toastDuration: TimeInterval = 4

    /// Current pill content size (width drives the in-place animation).
    static func contentSize(for state: DictationIslandState) -> CGSize {
        if state.showCancelledToast { return CGSize(width: toastWidth, height: pillHeight) }
        switch state.phase {
        case .idle:
            return state.hovering
                ? CGSize(width: micWidth, height: pillHeight)
                : CGSize(width: idleWidth, height: idleHeight)
        case .recording:    return CGSize(width: recordingWidth, height: pillHeight)
        case .transcribing: return CGSize(width: transcribingWidth, height: pillHeight)
        }
    }

    /// Fixed panel large enough for every state (incl. the wider tooltip), so we
    /// never resize the window.
    static var panelSize: CGSize {
        let maxContent = max(micWidth, recordingWidth, transcribingWidth, toastWidth, tooltipWidth)
        return CGSize(width: maxContent + pad * 2,
                      height: tooltipHeight + tooltipGap + pillSlotHeight + pad * 2)
    }
}

// MARK: - View

private enum IslandColor {
    static let surface = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let surfaceTop = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white
    static let accent = Color(red: 0.80, green: 0.64, blue: 0.97)
    static let cancel = Color.white.opacity(0.16)
    static let confirm = Color.white
}

struct DictationIslandView: View {
    @ObservedObject var state: DictationIslandState

    @State private var toastProgress: CGFloat = 1   // 1 → 0 over the toast lifetime

    private var pillWidth: CGFloat { IslandMetrics.contentSize(for: state).width }
    private var pillHeight: CGFloat { IslandMetrics.contentSize(for: state).height }
    private var stateKey: String { "\(state.phase)-\(state.hovering)-\(state.showCancelledToast)" }
    private var anim: Animation { .spring(response: 0.30, dampingFraction: 0.82) }

    var body: some View {
        // Fixed-size root so NSHostingController never resizes the window; the
        // pill animates purely in place within this constant frame.
        ZStack(alignment: .bottom) {
            Color.clear
            VStack(spacing: IslandMetrics.tooltipGap) {
                tooltipSlot
                pill
                    .frame(height: IslandMetrics.pillSlotHeight)   // fixed slot; pill centred → grows symmetrically
            }
            .padding(.bottom, IslandMetrics.pad)
        }
        .frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height)
        .animation(anim, value: stateKey)
    }

    // Reserve the tooltip band always so the pill never shifts when it appears.
    private var tooltipSlot: some View {
        ZStack {
            if IslandMetrics.showsTooltipExpanded(state) {
                tooltip
                    // Fade + straight-down movement only (no horizontal drift).
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(height: IslandMetrics.tooltipHeight)
    }

    private var pill: some View {
        ZStack { innerContent }
            .frame(width: pillWidth, height: pillHeight)
            .background(capsuleBackground)
            // Toast lifetime bar — sits right on the capsule's bottom border,
            // filling left→right. Inset past the rounded corners so it stays
            // flush with the bottom edge.
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(IslandColor.text.opacity(0.45))
                    .frame(height: 2.5)
                    .scaleEffect(x: toastProgress, anchor: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 0)
                    .opacity(state.showCancelledToast ? 1 : 0)
            }
            .contentShape(Capsule())
            .onTapGesture {
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
                // Mic fades by opacity only — no movement.
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(IslandColor.text)
                    .opacity(state.hovering ? 1 : 0)
            case .recording:    recordingContent
            case .transcribing: transcribingContent
            }
        }
    }

    private var recordingContent: some View {
        HStack(spacing: 7) {
            circleButton(system: "xmark", fg: IslandColor.text, bg: IslandColor.cancel) {
                VoiceDictationController.shared.cancel()
            }
            WaveBars(level: state.level)
                .frame(maxWidth: .infinity)
            circleButton(system: "checkmark", fg: .black, bg: IslandColor.confirm) {
                VoiceDictationController.shared.stopAndTranscribe()
            }
        }
        .padding(.horizontal, 5)
    }

    private var transcribingContent: some View {
        HStack(spacing: 8) {
            ProgressView().progressViewStyle(.circular).controlSize(.small).tint(IslandColor.text)
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
                .lineLimit(1)
                .fixedSize()
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
        .onAppear {
            // Lifetime bar fills left→right over the toast's life.
            toastProgress = 0
            withAnimation(.linear(duration: IslandMetrics.toastDuration)) { toastProgress = 1 }
        }
    }

    private var tooltip: some View {
        HStack(spacing: 6) {
            Text("Dictate").foregroundColor(IslandColor.text)
            Text(Settings.shared.dictationHandsFreeShortcut.displayName).foregroundColor(IslandColor.accent)
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
            .fill(LinearGradient(colors: [IslandColor.surfaceTop, IslandColor.surface],
                                 startPoint: .top, endPoint: .bottom))
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

extension IslandMetrics {
    static func showsTooltipExpanded(_ state: DictationIslandState) -> Bool { state.isExpandedIdle }
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
                    Capsule().fill(IslandColor.text)
                        .frame(width: barWidth, height: height(i, t))
                }
            }
        }
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let boosted = min(1.0, max(0.18, level * 2.6))
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(i) - center) / center
        let envelope = 1.0 - distance * 0.45
        let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 0.8)
        let amp = boosted * envelope * (0.45 + 0.55 * wobble)
        return minHeight + CGFloat(amp) * (maxHeight - minHeight)
    }
}
