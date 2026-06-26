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
    private var pendingRefresh: DispatchWorkItem?
    private var currentLiftOffset: CGFloat = 0
    private var dockInsetCache: [CGDirectDisplayID: CGFloat] = [:]

    private init() {}

    // MARK: Lifecycle

    func startIfEnabled() {
        guard Settings.shared.showDictationIsland else { return }
        DispatchQueue.main.async { [self] in
            ensurePanel()
            refreshPlacement(animated: false)
            panel?.orderFront(nil)
            // Display geometry can still be settling at launch (launch-at-login
            // especially), and `panel.screen` only becomes valid once the panel
            // is on screen. Re-place on the next runloop tick so we land at the
            // bottom-centre even if the first pass saw stale/placeholder metrics
            // or the wrong screen.
            scheduleRefresh(animated: false, settle: 0.05)
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

        let host = NSHostingController(rootView: DictationIslandContainer(state: state))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: IslandMetrics.panelFullSize),
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
            self, selector: #selector(dictationStateChanged),
            name: .langFlipTTSStateChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(recorderChanged),
            name: .langFlipVoiceRecorderChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(dictationCancelled),
            name: .langFlipDictationCancelled, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(transcriptionFailed),
            name: .langFlipDictationTranscriptionFailed, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self, selector: #selector(activeContextChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspaceCenter.addObserver(
            self, selector: #selector(activeContextChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

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
        let detW = (state.phase == .idle && !state.showsToast
                    ? max(base, IslandMetrics.micWidth) : base) + 20
        let detH = IslandMetrics.pillSlotHeight + 16
        // The panel frame is anchored at the fullscreen (physical-bottom)
        // resting spot; the pill is lifted up by `currentLiftOffset` for normal
        // Spaces, so the detection footprint must follow that lift.
        let rect = CGRect(x: panel.frame.midX - detW / 2,
                          y: panel.frame.minY + pad - 8 + currentLiftOffset,
                          width: detW, height: detH)
        let inside = rect.contains(mouse)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if state.phase == .idle && !state.showsToast, state.hovering != inside {
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
                // A new recording (e.g. via hotkey) supersedes any lingering
                // "Transcript cancelled" toast — clear it so the island shows the
                // recording controls, not a stale toast with a live Undo.
                if state.showsToast { dismissToast() }
                state.phase = .recording
                startLevelTimer()
            } else if CloudSpeechSynthesizer.shared.isBuffering || AITextProcessing.shared.isActive {
                // Spinner: TTS buffering OR AI text processing (fix / transform / translate).
                state.phase = .speaking
                stopLevelTimer()
                state.audioLevel.reset()
            } else if SpeechReader.shared.isSpeaking {
                state.phase = .ttsPlayback
                state.ttsPlaybackPaused = false
                stopLevelTimer()
                state.audioLevel.reset()
            } else if SpeechReader.shared.isPaused {
                state.phase = .ttsPlayback
                state.ttsPlaybackPaused = true
                stopLevelTimer()
                state.audioLevel.reset()
            } else {
                state.phase = .idle
                state.ttsPlaybackPaused = false
                stopLevelTimer()
                state.audioLevel.reset()
            }
            // The pill resized; recompute click-through against the cursor even
            // if it didn't move, so the new ✕/✓ aren't dead under a still cursor.
            updateHover()
        }
    }

    @objc private func recorderChanged() {
        guard state.phase == .recording else { return }
        DispatchQueue.main.async { [self] in
            state.audioLevel.set(VoiceRecorder.shared.normalizedAveragePower)
        }
    }

    @objc private func dictationCancelled() {
        DispatchQueue.main.async { [self] in
            state.showFailedToast = false
            state.showCancelledToast = true
            state.toastToken &+= 1   // re-trigger the lifetime bar even if the toast is already up
            toastTimer?.invalidate()
            toastTimer = Timer.scheduledTimer(withTimeInterval: IslandMetrics.toastDuration, repeats: false) { [weak self] _ in
                self?.dismissToast()
            }
            updateHover()
        }
    }

    @objc private func transcriptionFailed() {
        DispatchQueue.main.async { [self] in
            state.showCancelledToast = false
            state.showFailedToast = true
            state.toastToken &+= 1
            toastTimer?.invalidate()
            toastTimer = Timer.scheduledTimer(withTimeInterval: IslandMetrics.toastDuration, repeats: false) { [weak self] _ in
                self?.dismissToast()
            }
            updateHover()
        }
    }

    func dismissToast() {
        toastTimer?.invalidate()
        toastTimer = nil
        state.showCancelledToast = false
        state.showFailedToast = false
        updateHover()
    }

    @objc private func screenChanged() {
        DispatchQueue.main.async { [weak self] in self?.scheduleRefresh(animated: true, settle: 0.2) }
    }

    @objc private func activeContextChanged() {
        // React promptly so the lift animation rides alongside macOS' own
        // Space/Dock transition, then re-check once it settles to correct a
        // cold Dock-inset cache (a no-op in the steady state).
        DispatchQueue.main.async { [weak self] in
            self?.refreshPlacement(animated: true)
            self?.scheduleRefresh(animated: true, settle: 0.45)
        }
    }

    private func startLevelTimer() {
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.state.phase == .recording else { return }
            self.state.audioLevel.set(VoiceRecorder.shared.normalizedAveragePower)
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    /// Coalesced placement pass. The panel frame is only ever hard-set (it moves
    /// only when the active screen changes); the vertical Dock clearance is a
    /// SwiftUI lift animation, so it never blends with macOS' Space transition.
    private func scheduleRefresh(animated: Bool, settle: TimeInterval) {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPlacement(animated: animated) }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    private func refreshPlacement(animated: Bool) {
        guard let panel else { return }
        let placement = placementForCurrentContext(panel: panel)
        setPanelFrame(panelFrame(on: placement.screen), for: panel)
        setLiftOffset(liftTarget(for: placement), animated: animated)
    }

    /// Panel frame anchored with its bottom at the *physical* screen bottom (the
    /// fullscreen resting position). Tall enough that the pill can be lifted
    /// clear of the Dock from inside, without the window itself moving.
    private func panelFrame(on screen: NSScreen) -> NSRect {
        let size = IslandMetrics.panelFullSize
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.minY + IslandMetrics.bottomInset - IslandMetrics.pad - IslandMetrics.idleHeight
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// How far to lift the pill above its fullscreen anchor: 0 in a fullscreen
    /// Space, the Dock height in a normal desktop Space.
    private func liftTarget(for placement: (screen: NSScreen, isFullscreen: Bool)) -> CGFloat {
        let fullscreen = placement.isFullscreen || isFullscreenSpace(on: placement.screen)
        return fullscreen ? 0 : dockInset(for: placement.screen)
    }

    /// Dock clearance for a screen, cached per display. During a Space switch
    /// `visibleFrame` can momentarily still report the old chrome; reading the
    /// cached value avoids animating to a wrong intermediate target (which would
    /// itself look like a step).
    private func dockInset(for screen: NSScreen) -> CGFloat {
        let live = max(0, screen.visibleFrame.minY - screen.frame.minY)
        let id = screen.displayID
        if live > 1 { dockInsetCache[id] = live }
        return live > 1 ? live : (dockInsetCache[id] ?? live)
    }

    private func setPanelFrame(_ frame: NSRect, for panel: NSPanel) {
        guard !panel.frame.equalTo(frame) else { return }
        panel.setFrame(frame, display: true)
    }

    private func setLiftOffset(_ value: CGFloat, animated: Bool) {
        currentLiftOffset = value
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) { state.liftOffset = value }
        } else {
            state.liftOffset = value
        }
        updateHover()
    }

    private func placementForCurrentContext(panel: NSPanel) -> (screen: NSScreen, isFullscreen: Bool) {
        if let fullscreenFrame = AppContext.frontmostFullscreenWindowFrame(),
           let screen = screen(containing: fullscreenFrame) {
            return (screen, true)
        }

        if let windowFrame = AppContext.frontmostWindowFrame(),
           let screen = screen(containing: windowFrame) {
            let fullscreen = AppContext.frontmostWindowIsFullscreen() ?? isFullscreen(windowFrame, on: screen)
            return (screen, fullscreen)
        }

        // Fallback remains deterministic for accessory-app launch: prefer the
        // panel's current screen once visible, then the menu-bar screen.
        let screen = panel.screen ?? NSScreen.screens.first ?? NSScreen.main ?? NSScreen()
        return (screen, false)
    }

    private func screen(containing windowFrame: CGRect) -> NSScreen? {
        let center = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func isFullscreen(_ windowFrame: CGRect, on screen: NSScreen) -> Bool {
        let tolerance: CGFloat = 1
        return abs(screen.frame.width - windowFrame.width) < tolerance
            && abs(screen.frame.height - windowFrame.height) < tolerance
    }

    private func isFullscreenSpace(on screen: NSScreen) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let tolerance: CGFloat = 2
        return windows.contains { window in
            guard (window[kCGWindowOwnerName as String] as? String) == "Dock",
                  (window[kCGWindowName as String] as? String) == "Fullscreen Backdrop",
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat
            else { return false }

            return abs(width - screen.frame.width) <= tolerance
                && abs(height - screen.frame.height) <= tolerance
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - State

final class DictationIslandState: ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing, speaking, ttsPlayback }

    @Published var phase: Phase = .idle
    @Published var hovering = false
    @Published var showCancelledToast = false
    @Published var showFailedToast = false
    @Published var ttsPlaybackPaused = false
    @Published var toastToken = 0   // bumped on each cancel to (re)start the lifetime bar
    @Published var liftOffset: CGFloat = 0   // pill rise above the fullscreen anchor (Dock clearance)

    let audioLevel = DictationIslandAudioLevelState()

    var showsToast: Bool { showCancelledToast || showFailedToast }
    var isExpandedIdle: Bool { phase == .idle && hovering && !showsToast }
}

final class DictationIslandAudioLevelState: ObservableObject {
    @Published private(set) var value: Double = 0

    func set(_ nextValue: Double) {
        let clamped = min(1, max(0, nextValue))
        guard abs(clamped - value) >= 0.015 else { return }
        value = clamped
    }

    func reset() {
        guard value != 0 else { return }
        value = 0
    }
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
    static let transcribingWidth: CGFloat = recordingWidth  // match recording so the pill doesn't jump width on state change
    static let ttsPlaybackWidth: CGFloat = 60
    static let toastWidth: CGFloat = 224        // snug: toast text + action, minimal gap

    static let tooltipWidth: CGFloat = 188
    static let tooltipHeight: CGFloat = 26
    static let tooltipGap: CGFloat = 7

    /// How long transient action toasts live before they auto-dismiss.
    static let toastDuration: TimeInterval = 4

    /// Current pill content size (width drives the in-place animation).
    static func contentSize(for state: DictationIslandState) -> CGSize {
        if state.showsToast { return CGSize(width: toastWidth, height: pillHeight) }
        switch state.phase {
        case .idle:
            return state.hovering
                ? CGSize(width: micWidth, height: pillHeight)
                : CGSize(width: idleWidth, height: idleHeight)
        case .recording:    return CGSize(width: recordingWidth, height: pillHeight)
        case .transcribing: return CGSize(width: transcribingWidth, height: pillHeight)
        // TTS buffering: collapse to a circle holding a spinner.
        case .speaking:     return CGSize(width: pillHeight, height: pillHeight)
        case .ttsPlayback:  return CGSize(width: ttsPlaybackWidth, height: pillHeight)
        }
    }

    /// Fixed panel large enough for every state (incl. the wider tooltip), so we
    /// never resize the window.
    static var panelSize: CGSize {
        let maxContent = max(micWidth, recordingWidth, transcribingWidth, ttsPlaybackWidth, toastWidth, tooltipWidth)
        return CGSize(width: maxContent + pad * 2,
                      height: tooltipHeight + tooltipGap + pillSlotHeight + pad * 2)
    }

    /// Extra vertical room above the resting pill so it can be lifted clear of
    /// the Dock from inside a stationary panel. Generous enough for a large /
    /// magnified Dock.
    static let spaceTravel: CGFloat = 160

    /// The actual NSPanel size: the content area plus the lift travel room.
    static var panelFullSize: CGSize {
        CGSize(width: panelSize.width, height: panelSize.height + spaceTravel)
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

/// Stationary outer view filling the whole (tall) panel. The island is pinned
/// to the bottom and lifted up by `liftOffset` to clear the Dock in a normal
/// Space. Because the NSPanel frame never moves on a Space switch, this vertical
/// travel is a pure SwiftUI animation and never collides with macOS' own
/// Space/Dock transition. The lift is animated by the controller via
/// `withAnimation`, so the first placement can be applied without a slide.
private struct DictationIslandContainer: View {
    @ObservedObject var state: DictationIslandState

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            DictationIslandView(state: state)
                .offset(y: -state.liftOffset)
        }
        .frame(width: IslandMetrics.panelFullSize.width,
               height: IslandMetrics.panelFullSize.height)
    }
}

struct DictationIslandView: View {
    @ObservedObject var state: DictationIslandState

    @State private var toastProgress: CGFloat = 1   // 1 → 0 over the toast lifetime
    @State private var recShown = false             // drives the in-place staggered cascade of controls
    @State private var pillPop: CGFloat = 1         // transient "breath" scale on record-start

    private var pillWidth: CGFloat { IslandMetrics.contentSize(for: state).width }
    private var pillHeight: CGFloat { IslandMetrics.contentSize(for: state).height }
    private var animationKey: IslandAnimationKey {
        IslandAnimationKey(
            phase: state.phase,
            hovering: state.hovering,
            showCancelledToast: state.showCancelledToast,
            showFailedToast: state.showFailedToast
        )
    }

    // Pill grow/shrink — a touch longer with a soft overshoot so it springs in
    // place rather than snapping. (Grows from the centre; the panel never moves.)
    private var pillSpring: Animation { .spring(response: 0.44, dampingFraction: 0.70) }

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
        .animation(pillSpring, value: animationKey)
        // Lifetime bar fills left→right; re-armed on every cancel (token bump),
        // so a fresh cancel while a toast is still up restarts it cleanly.
        .onChange(of: state.toastToken) { _ in
            toastProgress = 0
            withAnimation(.linear(duration: IslandMetrics.toastDuration)) { toastProgress = 1 }
        }
        // Breath: a quick scale-up + springy settle the instant recording starts,
        // like an inhale before listening.
        .onChange(of: state.phase) { newPhase in
            guard newPhase == .recording else { return }
            withAnimation(.easeOut(duration: 0.12)) { pillPop = 1.05 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { pillPop = 1 }
            }
        }
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
                    .opacity(state.showsToast ? 1 : 0)
            }
            // Transcribing label as a persistent, centred overlay: its scale +
            // opacity are driven straight from the phase, so on finish it shrinks
            // into the pill's centre and fades (no transition, no reflow drift).
            .overlay {
                transcribingContent
                    .fixedSize()
                    .scaleEffect(state.phase == .transcribing ? 1 : 0.3, anchor: .center)
                    .opacity(state.phase == .transcribing ? 1 : 0)
                    .animation(pillSpring, value: state.phase)
                    .allowsHitTesting(false)
            }
            // TTS buffering spinner — same persistent-overlay trick so it scales
            // in/out from the pill's centre (no off-centre pop on enter/exit).
            .overlay {
                speakingContent
                    .scaleEffect(state.phase == .speaking ? 1 : 0.3, anchor: .center)
                    .opacity(state.phase == .speaking ? 1 : 0)
                    .animation(pillSpring, value: state.phase)
                    .allowsHitTesting(false)
            }
            // TTS playback controls use the same persistent-overlay pattern as
            // the spinner/toasts. Keeping them mounted prevents SwiftUI from
            // inserting the HStack from the panel edge while the capsule width
            // is animating; clipping reveals them from the island centre.
            .overlay {
                ZStack {
                    playbackContent
                        .frame(width: IslandMetrics.ttsPlaybackWidth, height: IslandMetrics.pillHeight)
                        .scaleEffect(state.phase == .ttsPlayback ? 1 : 0.35, anchor: .center)
                        .opacity(state.phase == .ttsPlayback ? 1 : 0)
                        .animation(pillSpring, value: state.phase)
                }
                .frame(width: pillWidth, height: pillHeight)
                .clipShape(Capsule())
                .allowsHitTesting(state.phase == .ttsPlayback)
            }
            // "Transcript cancelled" toast — persistent overlay so on dismiss it
            // shrinks into the centre + fades (not slides out). Fixed width keeps
            // its spread layout stable; hit-testing is on only while it's shown so
            // the Undo button stays tappable.
            .overlay {
                toastContent
                    .frame(width: IslandMetrics.toastWidth)
                    .scaleEffect(state.showsToast ? 1 : 0.3, anchor: .center)
                    .opacity(state.showsToast ? 1 : 0)
                    .animation(pillSpring, value: state.showsToast)
                    .allowsHitTesting(state.showsToast)
            }
            .scaleEffect(pillPop, anchor: .center)
            .contentShape(Capsule())
            .onTapGesture {
                if state.phase == .idle && !state.showsToast {
                    VoiceDictationController.shared.toggleRecording()
                }
            }
    }

    @ViewBuilder
    private var innerContent: some View {
        if state.showsToast {
            // Toast lives in a persistent overlay (see `pill`) so it shrinks into
            // the pill's centre on dismiss instead of sliding out down-right as
            // the pill collapses.
            EmptyView()
        } else {
            switch state.phase {
            case .idle:
                // Mic fades by opacity only — no movement.
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(IslandColor.text)
                    .opacity(state.hovering ? 1 : 0)
            case .recording:    recordingContent
            // Transcribing content lives in a persistent overlay (see `pill`) so
            // it can scale straight into the centre on exit instead of being
            // reflowed by the collapsing frame.
            case .transcribing: EmptyView()
            // Speaking spinner lives in a persistent overlay (see `pill`) so it
            // scales in/out from the pill's centre instead of popping off-centre.
            case .speaking:     EmptyView()
            // Playback controls live in a persistent overlay (see `pill`) so
            // they reveal/collapse in the capsule centre, not from panel edges.
            case .ttsPlayback:  EmptyView()
            }
        }
    }

    /// TTS buffering: a small circular spinner spinning in place inside the
    /// circle pill — the "preparing audio" indicator for read-aloud.
    private var speakingContent: some View {
        IslandSpinner(size: 16)
    }

    private var playbackContent: some View {
        HStack(spacing: 6) {
            circleButton(system: state.ttsPlaybackPaused ? "play.fill" : "pause.fill",
                         fg: .black,
                         bg: IslandColor.confirm) {
                _ = SpeechReader.shared.togglePlayback()
            }
            .animation(pillSpring, value: state.ttsPlaybackPaused)
            circleButton(system: "stop.fill", fg: IslandColor.text, bg: IslandColor.cancel) {
                SpeechReader.shared.stop()
            }
        }
        .padding(.horizontal, 5)
    }

    private var recordingContent: some View {
        // Pill expands first (pillSpring); the controls then pop in IN PLACE,
        // cascaded ✕ → wave → ✓ (StaggerIn animates scale/opacity, so they don't
        // slide in from anywhere — they grow where they sit).
        HStack(spacing: 7) {
            circleButton(system: "xmark", fg: IslandColor.text, bg: IslandColor.cancel) {
                VoiceDictationController.shared.cancel()
            }
            .modifier(StaggerIn(shown: recShown, delay: 0.06))
            LiveWaveBars(audioLevel: state.audioLevel)
                .frame(maxWidth: .infinity)
                .modifier(StaggerIn(shown: recShown, delay: 0.14))
            circleButton(system: "checkmark", fg: .black, bg: IslandColor.confirm) {
                VoiceDictationController.shared.stopAndTranscribe()
            }
            .modifier(StaggerIn(shown: recShown, delay: 0.22))
        }
        .padding(.horizontal, 5)
        .onAppear { recShown = true }
        .onDisappear { recShown = false }
    }

    private var transcribingContent: some View {
        HStack(spacing: 8) {
            // Custom spinner everywhere now (the system one glitched on scale-in
            // for TTS; trying the custom one in all states to confirm it's clean).
            IslandSpinner(size: 14)
            Text("Transcribing…")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(IslandColor.text.opacity(0.4))
                .modifier(ShimmerText())
        }
        .padding(.horizontal, 12)
    }

    private var toastContent: some View {
        HStack(spacing: 8) {
            Text(state.showFailedToast ? "Transcription failed" : "Transcript cancelled")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(IslandColor.text)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 2)
            Button {
                if state.showFailedToast {
                    VoiceDictationController.shared.retryFailedTranscription()
                } else {
                    VoiceDictationController.shared.undoCancel()
                }
                DictationIslandController.shared.dismissToast()
            } label: {
                Text(state.showFailedToast ? "Retry" : "Undo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(IslandColor.confirm))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 28)
        .padding(.trailing, 11)
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
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(fg)
                .frame(width: 22, height: 22)
                .background(Circle().fill(bg))
        }
        .buttonStyle(.plain)
    }
}

private struct IslandAnimationKey: Equatable {
    let phase: DictationIslandState.Phase
    let hovering: Bool
    let showCancelledToast: Bool
    let showFailedToast: Bool
}

extension IslandMetrics {
    static func showsTooltipExpanded(_ state: DictationIslandState) -> Bool { state.isExpandedIdle }
}

private struct LiveWaveBars: View {
    @ObservedObject var audioLevel: DictationIslandAudioLevelState

    var body: some View {
        WaveBars(level: audioLevel.value)
            .transaction { $0.animation = nil }
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
    private let introDuration: TimeInterval = 0.35

    @State private var appearedAt: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let intro = introFactor(now: timeline.date)
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule().fill(IslandColor.text)
                        .frame(width: barWidth, height: height(i, t, intro))
                }
            }
        }
        .onAppear { appearedAt = Date() }
    }

    /// 0 → 1 over `introDuration` after the bars appear (easeOutCubic): the bars
    /// swell up from a flat line into the live response — "the mic woke up".
    private func introFactor(now: Date) -> Double {
        guard let appearedAt else { return 0 }
        let p = min(1, max(0, now.timeIntervalSince(appearedAt) / introDuration))
        return 1 - pow(1 - p, 3)
    }

    private func height(_ i: Int, _ t: TimeInterval, _ intro: Double) -> CGFloat {
        let boosted = min(1.0, max(0.18, level * 2.6))
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(i) - center) / center
        let envelope = 1.0 - distance * 0.45
        let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 0.8)
        let amp = boosted * envelope * (0.45 + 0.55 * wobble) * intro
        return minHeight + CGFloat(amp) * (maxHeight - minHeight)
    }
}

// MARK: - Stagger-in

/// In-place cascade entrance: each element pops from shrunk + transparent to
/// full size with a springy overshoot. The per-element `delay` makes the
/// recording controls arrive in sequence (✕ → wave → ✓) without sliding.
private struct StaggerIn: ViewModifier {
    let shown: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.4, anchor: .center)
            .opacity(shown ? 1 : 0)
            .animation(.spring(response: 0.40, dampingFraction: 0.56).delay(delay), value: shown)
    }
}

// MARK: - Spinner

/// A faithful copy of the macOS system spinner (`NSProgressIndicator.spinning`):
/// a ring of tapered "spokes" whose brightness fades from a leading head around
/// the circle, advancing in discrete steps. Unlike the real one, its motion is
/// derived from a `TimelineView` clock every frame, so it never restarts when
/// the hosting view re-renders or is scaled in (that reset caused the TTS
/// spinner to stutter for ~1s on appear). Used where the system spinner glitches
/// (TTS buffering); the real `ProgressView` is kept elsewhere.
private struct IslandSpinner: View {
    var size: CGFloat = 16
    var spokeCount: Int = 8    // the system indicator uses 8 spokes
    var period: Double = 1.0   // one revolution per second, like the system one

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // Discrete head position (the system indicator steps spoke-by-spoke).
            let head = Int((t / period * Double(spokeCount)).rounded(.down)) % spokeCount
            ZStack {
                ForEach(0..<spokeCount, id: \.self) { i in
                    let behind = Double((head - i + spokeCount) % spokeCount)
                    // Dimmer than full white — the system spokes are a soft grey
                    // (head ~0.55 → tail ~0.12), not bright.
                    let opacity = 0.12 + 0.43 * (1.0 - behind / Double(spokeCount))
                    Capsule()
                        .fill(IslandColor.text)
                        .frame(width: size * 0.12, height: size * 0.30)
                        .offset(y: -size * 0.33)
                        .rotationEffect(.degrees(Double(i) / Double(spokeCount) * 360.0))
                        .opacity(opacity)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Shimmer

/// A loading shimmer: a bright band sweeps left→right across the content,
/// masked to its shape. Pair with a dimmed base colour so the sweep reads as a
/// highlight passing over the text (the "Transcribing…" label uses this).
private struct ShimmerText: ViewModifier {
    @State private var x: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                let w = geo.size.width
                let band = max(24, w * 0.5)
                LinearGradient(
                    colors: [.clear, IslandColor.text, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band, height: geo.size.height)
                .position(x: x, y: geo.size.height / 2)
                .blendMode(.plusLighter)
                .onAppear {
                    x = -band
                    withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                        x = w + band
                    }
                }
            }
            .mask(content)
            .allowsHitTesting(false)
        )
    }
}
