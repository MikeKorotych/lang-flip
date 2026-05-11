import AppKit
import SwiftUI

/// Welcome / permissions wizard shown on first launch (and on any launch
/// where a previously-granted permission has been revoked). Walks the user
/// through Accessibility and Input Monitoring one at a time so they don't
/// have to figure out the right order or remember to come back to the
/// window after a System Settings detour. Closed by Continue, which is
/// gated on both permissions being granted — no Skip by design (without
/// the permissions the app is inert).
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
            win.title = "LangFlip"
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

    private func markDoneAndClose(openPreferences: Bool) {
        Settings.shared.onboardingDone = true
        window?.close()
        NSApp.setActivationPolicy(.accessory)
        let cb = onComplete
        onComplete = nil
        cb?()
        if openPreferences {
            DispatchQueue.main.async {
                PreferencesWindowController.shared.show()
            }
        }
    }
}

private struct SetupChecklist: View {
    private enum RunState: Equatable {
        case idle
        case running
        case success(String)
        case failed(String)
    }

    let onOpenPreferences: () -> Void

    @State private var dictionaryStats = DictionaryManager.stats()
    @State private var dictionaryState: RunState = .idle
    @State private var aiReady = AIAssistantManager.shared.isReady
    @State private var grammarState: RunState = .idle
    @State private var ocrState: RunState = .idle

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick setup")
                .font(.headline)

            checklistRow(
                done: hasExtendedDictionaries,
                icon: "text.book.closed",
                title: "Install extended dictionaries",
                detail: hasExtendedDictionaries ? "Extended EN/UK/RU dictionaries are active." : "Improves auto-flip coverage for real typing.",
                state: dictionaryState
            ) {
                Button(dictionaryButtonTitle) {
                    installDictionaries()
                }
                .disabled(dictionaryState == .running)
            }

            checklistRow(
                done: aiReady,
                icon: "sparkles",
                title: "Use Qwen 3.5 for local AI",
                detail: aiReady ? "Qwen 3.5 is selected and reachable through Ollama." : "Select Qwen 3.5 for grammar fixes, translation, and OCR.",
                state: .idle
            ) {
                HStack(spacing: 8) {
                    Button("Select Qwen") {
                        Settings.shared.aiMode = .ollama
                        Settings.shared.ollamaModel = "qwen3.5:4b"
                        refresh()
                    }
                    Button("AI Settings", action: onOpenPreferences)
                }
            }

            checklistRow(
                done: grammarSucceeded,
                icon: "wand.and.stars",
                title: "Run grammar test",
                detail: "Checks selected-text cleanup before you need it.",
                state: grammarState
            ) {
                Button(grammarState == .running ? "Testing..." : "Test") {
                    runGrammarTest()
                }
                .disabled(grammarState == .running || !aiReady)
            }

            checklistRow(
                done: ocrSucceeded,
                icon: "viewfinder",
                title: "Run OCR test",
                detail: "Checks that the local vision model can read text from images.",
                state: ocrState
            ) {
                Button(ocrState == .running ? "Testing..." : "Test") {
                    runOCRTest()
                }
                .disabled(ocrState == .running || !aiReady)
            }

            checklistRow(
                done: true,
                icon: "keyboard",
                title: "Remember the core hotkeys",
                detail: "Double Shift flips layout, single Shift fixes text, Shift+Command+S captures screen text.",
                state: .idle
            ) {
                Button("Hotkeys", action: onOpenPreferences)
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

    private var dictionaryButtonTitle: String {
        if dictionaryState == .running { return "Installing..." }
        return hasExtendedDictionaries ? "Update" : "Install"
    }

    private var grammarSucceeded: Bool {
        if case .success = grammarState { return true }
        return false
    }

    private var ocrSucceeded: Bool {
        if case .success = ocrState { return true }
        return false
    }

    @ViewBuilder
    private func checklistRow<Action: View>(
        done: Bool,
        icon: String,
        title: String,
        detail: String,
        state: RunState,
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
        case .running:
            return "Running..."
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

    private func refresh() {
        dictionaryStats = DictionaryManager.stats()
        aiReady = AIAssistantManager.shared.isReady
    }

    private func installDictionaries() {
        dictionaryState = .running
        DictionaryManager.installExtendedFrequencyPack { result in
            DispatchQueue.main.async {
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

    private func runGrammarTest() {
        grammarState = .running
        AIAssistantManager.shared.current.fixSelection(
            AIFixRequest(text: "World is wery gandgerous plsce to leave in!", activeLayout: .en)
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .fixed(let output):
                    grammarState = .success(output.trimmingCharacters(in: .whitespacesAndNewlines))
                case .unchanged:
                    grammarState = .success("Model replied; sample was unchanged.")
                case .unsupported:
                    grammarState = .failed("selected AI mode does not support text fixes")
                case .failed(let reason):
                    grammarState = .failed(reason)
                }
            }
        }
    }

    private func runOCRTest() {
        guard let imageBase64 = makeOCRSampleImageBase64() else {
            ocrState = .failed("could not create test image")
            return
        }
        ocrState = .running
        AIAssistantManager.shared.current.extractTextFromImage(
            AIOcrRequest(imageBase64: imageBase64)
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .extracted(let output):
                    ocrState = .success(output.trimmingCharacters(in: .whitespacesAndNewlines))
                case .unsupported:
                    ocrState = .failed("selected model does not support image input")
                case .failed(let reason):
                    ocrState = .failed(reason)
                }
            }
        }
    }

    private func makeOCRSampleImageBase64() -> String? {
        let sample = "LangFlip OCR test"
        let image = NSImage(size: NSSize(width: 720, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 720, height: 180).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        sample.draw(in: NSRect(x: 36, y: 72, width: 650, height: 60), withAttributes: attrs)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png.base64EncodedString()
    }
}

// MARK: - SwiftUI

private struct OnboardingView: View {
    let onContinue: () -> Void
    let onOpenPreferences: () -> Void

    @State private var status: PermissionStatus = .current()
    /// Driven by polling — when it changes from "missing" to "granted",
    /// the view auto-advances to the next step and the window pops
    /// forward.
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var stepIndex: Int {
        if !status.accessibility { return 0 }
        if !status.inputMonitoring { return 1 }
        return 2 // done
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            Divider().padding(.vertical, 2)

            // Completed steps shrink to a one-line row with a checkmark;
            // the active step gets the prominent action card; the future
            // step (if any) is just hinted as a small disabled row so the
            // user can see what's coming.
            VStack(spacing: 10) {
                if stepIndex == 0 {
                    activeStep(.accessibility)
                    upcomingStep(.inputMonitoring)
                } else if stepIndex == 1 {
                    completedStep(.accessibility)
                    activeStep(.inputMonitoring)
                } else {
                    completedStep(.accessibility)
                    completedStep(.inputMonitoring)
                    SetupChecklist(onOpenPreferences: onOpenPreferences)
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
            let wasIncomplete = !status.allGranted
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
            Text(status.allGranted ? "All set!" : "Welcome to LangFlip")
                .font(.system(size: 20, weight: .semibold))
            Text(headerSubtitle)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerSubtitle: String {
        switch stepIndex {
        case 0:
            return "Two quick permissions and you're done."
        case 1:
            return "One more permission to go."
        default:
            return "LangFlip is ready. One quick setup pass can make the first session much better."
        }
    }

    @ViewBuilder
    private var footer: some View {
        if status.allGranted {
            HStack(spacing: 10) {
                Button(action: onContinue) {
                    Text("Continue")
                        .frame(minWidth: 120)
                }
                .keyboardShortcut(.return)
                .controlSize(.large)

                Button(action: onOpenPreferences) {
                    Text("Open Preferences")
                        .frame(minWidth: 140)
                }
                .controlSize(.large)
            }
        } else {
            // Plain helper text while the user is mid-flow. Tells them
            // explicitly to come back, since otherwise it's easy to assume
            // System Settings is where the app lives now.
            Text("After toggling LangFlip on, this window will update automatically. You don't have to come back manually.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }

    // MARK: Step rendering

    private enum Step {
        case accessibility, inputMonitoring

        var title: String {
            switch self {
            case .accessibility:   return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var rationale: String {
            switch self {
            case .accessibility:
                return "Lets LangFlip see the keys you press, so it can detect a wrong-layout word."
            case .inputMonitoring:
                return "Lets LangFlip rewrite the word and switch your input source for you."
            }
        }

        var stepNumber: Int {
            self == .accessibility ? 1 : 2
        }

        func openSettings() {
            switch self {
            case .accessibility:
                PermissionStatus.openAccessibilityPane()
            case .inputMonitoring:
                // The first call to IOHIDRequestAccess shows the system
                // dialog and adds us to the Input Monitoring list, so the
                // user has something to toggle when the pane opens.
                PermissionStatus.requestInputMonitoring()
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
                Text("(step \(step.stepNumber) of 2)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(step.rationale)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Click below, find **LangFlip** in the list and toggle it on.")
                .font(.callout)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: step.openSettings) {
                    Text("Open System Settings")
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
