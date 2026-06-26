import AppKit
import SwiftUI

/// Welcome / permissions wizard shown on first launch (and on any launch where a
/// required permission is still missing). Walks through Microphone (dictation)
/// then Accessibility + Input Monitoring (layout flip / hotkeys) one at a time —
/// the last two are mandatory for the event tap, so without them flips and
/// hotkeys are silently dead. The LangFlip tab keeps the same permission rows for
/// managing them later.
final class OnboardingWindowController: NSObject {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    /// Closure fired after the user clicks Continue with all
    /// permissions granted. AppDelegate uses this to start the event
    /// tap and bring up the menubar — they were deliberately deferred
    /// so the system's "would like to control this computer" alert
    /// doesn't fire while the user is still on the onboarding screen.
    private var onComplete: (() -> Void)?

    func show(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
        if window == nil {
            let view = OnboardingView(onContinue: { [weak self] in
                self?.markDoneAndClose(openPreferences: false)
            }, onOpenPreferences: { [weak self] in
                self?.markDoneAndClose(openPreferences: true)
            })
            let host = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: host)
            win.title = "Sayful"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 600, height: 680))
            win.isReleasedWhenClosed = false
            win.center()
            // Keep the window above other apps so when the user comes back
            // from System Settings they immediately see it. Without this
            // it's easy to lose under whatever happened to be focused
            // while they were toggling switches.
            win.level = .floating
            window = win
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Called from the OnboardingView when permission state advances.
    /// Brings the window forward so the user sees the new state without
    /// having to Cmd+Tab back from System Settings.
    func bringToFront() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Input Monitoring sometimes becomes operational only after the app is
    /// relaunched. Keep this user-facing instead of leaving onboarding stuck on
    /// an already-enabled permission row.
    func restartApp() {
        let bundlePath = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$1\"", "restart-sayful", bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func markDoneAndClose(openPreferences: Bool) {
        Settings.shared.onboardingDone = true
        Settings.shared.returnToOnboardingAfterScreenRecording = false
        window?.close()
        NSApp.setActivationPolicy(.accessory)
        let cb = onComplete
        onComplete = nil
        cb?()
        if openPreferences {
            DispatchQueue.main.async {
                MainWindowController.shared.show(section: .settings)
            }
        }
    }
}

/// Shown once all permissions are granted — a light "you're ready" panel with
/// the optional extended-dictionary install and the core hotkeys to try first.
/// No local-AI setup here: AI features (grammar, translate, screenshot text,
/// read aloud) use whatever provider is configured in Settings.
private struct SetupChecklist: View {
    private enum RunState: Equatable {
        case idle
        case running(String)
        case success(String)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    let onOpenPreferences: () -> Void

    @State private var dictionaryStats = DictionaryManager.stats()
    @State private var dictionaryState: RunState = .idle
    @State private var dictionaryProgress: Double?

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're ready")
                .font(.headline)

            Text("Press your dictation hotkey in any app and start talking — Sayful types it at your cursor.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            checklistRow(
                done: hasExtendedDictionaries,
                icon: "text.book.closed",
                title: "Install extended dictionaries",
                detail: hasExtendedDictionaries ? "Extended EN/UK/RU dictionaries are active." : "Improves auto-flip coverage for real typing. Installs automatically in the background.",
                state: dictionaryState,
                progress: dictionaryProgress
            ) {
                Button {
                    installDictionaries()
                } label: {
                    Text(dictionaryState.isRunning ? "Installing..." : "Install")
                        .frame(width: 92)
                }
                .disabled(dictionaryState.isRunning || hasExtendedDictionaries)
                .focusable(false)
            }

            checklistRow(
                done: true,
                icon: "keyboard",
                title: "Core hotkeys to try first",
                detail: "These are the main gestures.",
                state: .idle
            ) {
                EmptyView()
            }
            hotkeySummary()

            HStack {
                Spacer()
                Button("Open Settings", action: onOpenPreferences)
                    .focusable(false)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private var hasExtendedDictionaries: Bool {
        dictionaryStats.values.contains { $0.installedCount > 0 }
    }

    @ViewBuilder
    private func checklistRow<Action: View>(
        done: Bool,
        icon: String,
        title: String,
        detail: String,
        state: RunState,
        progress: Double? = nil,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .font(.title3)
                .foregroundColor(done ? .green : .accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(statusDetail(defaultDetail: detail, state: state))
                    .font(.caption)
                    .foregroundColor(statusColor(for: state))
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                }
            }

            Spacer(minLength: 10)

            action()
                .controlSize(.small)
        }
    }

    private func statusDetail(defaultDetail: String, state: RunState) -> String {
        switch state {
        case .idle:
            return defaultDetail
        case .running(let message):
            return message
        case .success(let message):
            return message
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }

    private func statusColor(for state: RunState) -> Color {
        switch state {
        case .success:
            return .green
        case .failed:
            return .orange
        default:
            return .secondary
        }
    }

    private func hotkeySummary() -> some View {
        // Names track the user's configured languages (Dictionary tab) rather
        // than hard-coding UK/RU, and frame Triple as the *secondary* language.
        let primaryName = Settings.shared.primaryLanguage.displayName
        let secondaryDetail = Settings.shared.secondaryLanguage
            .map { "Same, but to your secondary language (\($0.displayName))." }
            ?? "Same, but to your secondary language — pick one in Dictionary."
        return VStack(alignment: .leading, spacing: 5) {
            hotkeyLine("Single Shift", "Fix selected text, or the last sentence when nothing is selected.")
            hotkeyLine("Double Shift", "Flip selected text or the last wrong-layout words to your primary language (\(primaryName)).")
            hotkeyLine("Triple Shift", secondaryDetail)
            hotkeyLine("Shift + Space", "Translate selected text into the current keyboard layout language.")
            hotkeyLine("Shift + ⌘ + S", "Copy text from a selected screenshot area.")
        }
        .padding(.leading, 34)
    }

    private func hotkeyLine(_ hotkey: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(hotkey)
                .font(.caption.weight(.semibold))
                .foregroundColor(.primary)
                .frame(width: 92, alignment: .leading)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refresh() {
        dictionaryStats = DictionaryManager.stats()
    }

    private func clearButtonFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func installDictionaries() {
        clearButtonFocus()
        dictionaryProgress = 0
        dictionaryState = .running("Downloading word lists...")
        DictionaryManager.installExtendedFrequencyPack { completed, total in
            dictionaryProgress = Double(completed) / Double(total)
            dictionaryState = .running("Downloaded \(completed) of \(total) word lists...")
        } completion: { result in
            DispatchQueue.main.async {
                dictionaryProgress = nil
                switch result {
                case .success:
                    dictionaryStats = DictionaryManager.stats()
                    dictionaryState = .success("Extended dictionaries installed.")
                case .failure(let error):
                    dictionaryState = .failed(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - SwiftUI

private struct OnboardingView: View {
    let onContinue: () -> Void
    let onOpenPreferences: () -> Void

    @State private var status: PermissionStatus = .current()
    @ObservedObject private var auth = SupabaseBackendAuth.shared
    @State private var signingIn = false
    /// "Maybe later" on the sign-in step — lets the optional cloud sign-in be
    /// skipped without blocking the rest of onboarding.
    @State private var skippedSignIn = false
    /// Driven by polling — when it changes from "missing" to "granted",
    /// the view auto-advances to the next step and the window pops
    /// forward.
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// Onboarding asks for the three permissions the core features need:
    /// Microphone (dictation) + Accessibility & Input Monitoring (layout flip /
    /// hotkeys). Without the latter two the event tap can't run, so flips and
    /// hotkeys are silently dead — they belong in first-run, not buried in a tab.
    private let steps: [Step] = [.microphone, .accessibility, .inputMonitoring]

    private func isGranted(_ step: Step) -> Bool {
        switch step {
        case .microphone:      return status.microphone
        case .accessibility:   return status.accessibility
        case .inputMonitoring: return status.inputMonitoring
        }
    }

    /// The first not-yet-granted step is the active one; nil when all granted.
    private var currentStep: Step? {
        steps.first { !isGranted($0) }
    }

    /// True once every shown step is granted — drives the "All set" state.
    private var allStepsGranted: Bool { currentStep == nil }
    private var needsKeyboardRestart: Bool {
        status.accessibility && status.inputMonitoring && !status.eventTapReady
    }

    /// Optional cloud sign-in, shown after the permissions are granted. Skippable
    /// ("Maybe later") and also available later from the title-bar profile menu.
    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("Sign in to Sayful Cloud").font(.headline)
                Text("(recommended)").font(.caption).foregroundColor(.secondary)
            }
            Text("Turns on AI features — grammar fix, translate, transforms, and cloud dictation — with no API key. Includes a free weekly quota.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: signIn) {
                    Text(signingIn ? "Signing in…" : "Sign in with Google")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(signingIn)
                Spacer()
            }
            HStack {
                Spacer()
                Button("Maybe later") { skippedSignIn = true }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.08))
                )
        )
    }

    private func signIn() {
        signingIn = true
        Task { @MainActor in
            defer { signingIn = false }
            do {
                _ = try await auth.signIn()
                // Wire AI to the backend so the user is set up end-to-end; on
                // success auth.isSignedIn flips → the "You're ready" panel shows.
                Settings.shared.aiMode = .backend
            } catch {
                // Optional — failures stay quiet; user can retry or "Maybe later".
            }
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            Divider().padding(.vertical, 2)

            // Each step renders as completed (granted), active (the first
            // ungranted one), or upcoming (a later ungranted one).
            VStack(spacing: 10) {
                ForEach(steps, id: \.self) { step in
                    if isGranted(step) {
                        completedStep(step)
                    } else if step == currentStep {
                        activeStep(step)
                    } else {
                        upcomingStep(step)
                    }
                }
                if allStepsGranted {
                    if needsKeyboardRestart {
                        restartStep
                    // After the mandatory permissions: offer Sayful Cloud sign-in
                    // (optional) before the "you're ready" panel.
                    } else if auth.isSignedIn || skippedSignIn {
                        SetupChecklist(onOpenPreferences: onOpenPreferences)
                    } else {
                        signInStep
                    }
                }
            }

            Divider().padding(.vertical, 2)

            footer
        }
        .padding(24)
        .frame(width: 512)
        .onReceive(timer) { _ in
            let next = PermissionStatus.current()
            guard next != status else { return }
            let wasIncomplete = !allStepsGranted
            status = next
            // Pop the window forward when something just changed, so the
            // user immediately sees the next instruction after toggling
            // a switch in System Settings.
            if wasIncomplete {
                OnboardingWindowController.shared.bringToFront()
            }
        }
    }

    // MARK: Header / footer

    @ViewBuilder
    private var header: some View {
        if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 96, height: 96)
        }
        VStack(spacing: 4) {
            Text(needsKeyboardRestart ? "Almost done" : (allStepsGranted ? "All set!" : "Welcome to Sayful"))
                .font(.system(size: 20, weight: .semibold))
            Text(headerSubtitle)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerSubtitle: String {
        let remaining = steps.filter { !isGranted($0) }.count
        if needsKeyboardRestart {
            return "Sayful needs a quick restart to finish enabling hotkeys."
        }
        switch remaining {
        case 0:  return "Sayful is ready. Speak in any app and it types for you."
        case 1:  return "One quick step and you're ready."
        default: return "\(remaining) quick steps and you're ready."
        }
    }

    @ViewBuilder
    private var footer: some View {
        if needsKeyboardRestart {
            HStack {
                Button(action: { OnboardingWindowController.shared.restartApp() }) {
                    Text("Restart Sayful")
                        .frame(minWidth: 150)
                }
                .keyboardShortcut(.return)
                .controlSize(.large)
            }
        } else if allStepsGranted {
            HStack(spacing: 10) {
                Button(action: onContinue) {
                    Text("Continue")
                        .frame(minWidth: 120)
                }
                .keyboardShortcut(.return)
                .controlSize(.large)

                Button(action: onOpenPreferences) {
                    Text("Open Settings")
                        .frame(minWidth: 140)
                }
                .controlSize(.large)
            }
        } else {
            // Plain helper text while the user is mid-flow. Tells them
            // explicitly to come back, since otherwise it's easy to assume
            // System Settings is where the app lives now.
            Text("After granting each permission, this window updates automatically. You don't have to come back manually.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }

    // MARK: Step rendering

    private var restartStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("Finish setup")
                    .font(.headline)
            }
            Text("Input Monitoring is enabled. macOS needs Sayful to reopen before the hotkeys can start working.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: { OnboardingWindowController.shared.restartApp() }) {
                    Text("Restart Sayful")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.08))
                )
        )
    }

    private enum Step: Hashable {
        case microphone, accessibility, inputMonitoring

        var title: String {
            switch self {
            case .microphone:      return "Microphone"
            case .accessibility:   return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var rationale: String {
            switch self {
            case .microphone:
                return "Lets Sayful hear you for dictation."
            case .accessibility:
                return "Lets Sayful flip the keyboard layout, fix text, and insert corrections."
            case .inputMonitoring:
                return "Lets Sayful see its hotkeys (double-Shift flip, dictation) while you type in any app."
            }
        }

        var instruction: LocalizedStringKey {
            switch self {
            case .microphone:
                return "Click below and allow microphone access so you can dictate."
            case .accessibility:
                return "Click below, find **Sayful** in the list and toggle it on."
            case .inputMonitoring:
                return "Click below, press **+** if Sayful is missing, add **/Applications/Sayful.app**, then toggle it on."
            }
        }

        var actionTitle: String {
            self == .microphone ? "Allow Microphone" : "Open System Settings"
        }

        var stepNumber: Int {
            switch self {
            case .microphone:      return 1
            case .accessibility:   return 2
            case .inputMonitoring: return 3
            }
        }

        func openSettings() {
            switch self {
            case .microphone:
                // First call surfaces the system consent dialog; the pane is a
                // fallback for when the user has already answered once.
                PermissionStatus.requestMicrophone()
                PermissionStatus.openMicrophonePane()
            case .accessibility:
                PermissionStatus.openAccessibilityPane()
            case .inputMonitoring:
                // Don't call CGRequestListenEventAccess here — on recent macOS it
                // can report "granted" before Sayful actually appears in the list.
                // Opening the pane and waiting for the real toggle stays honest.
                PermissionStatus.openInputMonitoringPane()
            }
        }
    }

    @ViewBuilder
    private func activeStep(_ step: Step) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "\(step.stepNumber).circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text(step.title)
                    .font(.headline)
                if steps.count > 1 {
                    Text("(step \(step.stepNumber) of \(steps.count))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Text(step.rationale)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(step.instruction)
                .font(.callout)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: step.openSettings) {
                    Text(step.actionTitle)
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.08))
                )
        )
    }

    @ViewBuilder
    private func completedStep(_ step: Step) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundColor(.green)
            Text(step.title)
                .font(.body)
            Spacer()
            Text("Granted")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func upcomingStep(_ step: Step) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "\(step.stepNumber).circle")
                .font(.title3)
                .foregroundColor(.secondary)
            Text(step.title)
                .font(.body)
                .foregroundColor(.secondary)
            Spacer()
            Text("Step \(step.stepNumber)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
