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
        case running(String)
        case success(String)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }
    }

    let onOpenPreferences: () -> Void

    @State private var dictionaryStats = DictionaryManager.stats()
    @State private var dictionaryState: RunState = .idle
    @State private var dictionaryProgress: Double?
    @State private var aiReady = AIAssistantManager.shared.isReady
    @State private var qwenState: RunState = .idle
    @State private var grammarState: RunState = .idle
    @State private var ocrState: RunState = .idle
    @State private var screenshotPasteTarget = ""
    @State private var screenshotPulse = false

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private let qwenModel = "qwen3.5:2b"
    private let grammarSample = "I dont know why this app works so well but it realy helps me every day"
    private let screenshotSample = "SCAN THIS TEXT"
    private let grammarHint = "After this, just press Shift to fix the last sentence, or select any text and press Shift."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick setup")
                .font(.headline)

            checklistRow(
                done: hasExtendedDictionaries,
                icon: "text.book.closed",
                title: "Install extended dictionaries",
                detail: hasExtendedDictionaries ? "Extended EN/UK/RU dictionaries are active." : "Improves auto-flip coverage for real typing.",
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
                done: aiReady,
                icon: "sparkles",
                title: "Use Qwen 3.5 for local AI",
                detail: aiReady ? "Qwen 3.5 is selected and reachable through Ollama." : "Download and select Qwen 3.5 for grammar fixes, translation, and screenshot text.",
                state: qwenState
            ) {
                Button {
                    Task {
                        await installAndSelectQwen()
                    }
                } label: {
                    Text(qwenButtonTitle)
                        .frame(width: 108)
                }
                .disabled(qwenState.isRunning || aiReady)
                .focusable(false)
            }

            checklistRow(
                done: grammarSucceeded,
                icon: "wand.and.stars",
                title: "Run grammar test",
                detail: grammarHint,
                state: grammarState
            ) {
                Button {
                    runGrammarTest()
                } label: {
                    Text(grammarState.isRunning ? "Testing..." : "Test")
                        .frame(width: 76)
                }
                .disabled(grammarState.isRunning || !aiReady)
                .focusable(false)
            }
            testTextBlock(label: "Input", text: grammarSample)
            if let grammarOutput {
                testTextBlock(label: "Output", text: grammarOutput)
            }

            checklistRow(
                done: ocrSucceeded,
                icon: "viewfinder",
                title: "Copy text from screenshot",
                detail: "Checks that Qwen can read text from an image and copy it for pasting.",
                state: ocrState
            ) {
                Button {
                    runOCRTest()
                } label: {
                    Text(ocrState.isRunning ? "Testing..." : "Test")
                        .frame(width: 76)
                }
                .disabled(ocrState.isRunning || !aiReady)
                .focusable(false)
            }
            if !ocrState.isIdle {
                screenshotTargetBlock()
            }
            if ocrSucceeded {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Select this text input and press ⌘V")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    TextField("", text: $screenshotPasteTarget)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(.leading, 34)
            }

            checklistRow(
                done: true,
                icon: "keyboard",
                title: "Remember the core hotkeys",
                detail: "These are the main gestures to try first.",
                state: .idle
            ) {
                EmptyView()
            }
            hotkeySummary()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                screenshotPulse.toggle()
            }
        }
    }

    private var hasExtendedDictionaries: Bool {
        dictionaryStats.values.contains { $0.installedCount > 0 }
    }

    private var grammarSucceeded: Bool {
        if case .success = grammarState { return true }
        return false
    }

    private var ocrSucceeded: Bool {
        if case .success = ocrState { return true }
        return false
    }

    private var grammarOutput: String? {
        if case .success(let output) = grammarState { return output }
        return nil
    }

    private var qwenButtonTitle: String {
        if qwenState.isRunning { return "Installing..." }
        if case .failed = qwenState { return "Try again" }
        return "Install Qwen"
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

    private func testTextBlock(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 34)
    }

    private func screenshotTargetBlock() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Select this area when the crosshair appears")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(screenshotSample)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(screenshotPulse ? 0.28 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(screenshotPulse ? 0.95 : 0.35), lineWidth: 1.5)
                )
        }
        .padding(.leading, 34)
    }

    private func hotkeySummary() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            hotkeyLine("Single Shift", "Fix selected text, or the last sentence when nothing is selected.")
            hotkeyLine("Double Shift", "Flip selected text or the last wrong-layout word run to Ukrainian.")
            hotkeyLine("Triple Shift", "Flip selected text or the last wrong-layout word run to Russian.")
            hotkeyLine("Shift + Space", "Translate selected text.")
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
        aiReady = AIAssistantManager.shared.isReady
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

    @MainActor
    private func installAndSelectQwen() async {
        clearButtonFocus()
        Settings.shared.aiMode = .ollama
        Settings.shared.ollamaModel = qwenModel

        guard Self.ollamaExecutableURL() != nil || isOllamaAppInstalled else {
            qwenState = .failed("Ollama is not installed. Download Ollama, open it once, then click Try again.")
            openOllamaDownloadPage()
            return
        }

        qwenState = .running("Checking Qwen 3.5...")

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if await isOllamaModelInstalled(qwenModel) {
            refresh()
            qwenState = AIAssistantManager.shared.isReady
                ? .success("Qwen 3.5 is selected and ready.")
                : .running("Qwen is installed. Waiting for Ollama to become ready...")
            return
        }

        qwenState = .running("Downloading Qwen 3.5 2B. This can take a few minutes...")
        if let failure = await Self.pullOllamaModel(qwenModel, progress: { message in
            qwenState = .running(message)
        }) {
            qwenState = .failed(failure)
            refresh()
            return
        }

        refresh()
        qwenState = AIAssistantManager.shared.isReady
            ? .success("Qwen 3.5 is selected and ready.")
            : .success("Qwen 3.5 is installed. If tests are disabled, reopen Ollama and wait a moment.")
    }

    private func runGrammarTest() {
        clearButtonFocus()
        grammarState = .running("Asking the local model to fix the sample...")
        AIAssistantManager.shared.current.fixSelection(
            AIFixRequest(text: grammarSample, activeLayout: .en)
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
        clearButtonFocus()
        screenshotPasteTarget = ""
        ocrState = .running("Select the highlighted SCAN THIS TEXT area.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            startInteractiveScreenshotTextTest()
        }
    }

    private func startInteractiveScreenshotTextTest() {
        guard PermissionStatus.hasScreenRecording() else {
            PermissionStatus.requestScreenRecording()
            PermissionStatus.openScreenRecordingPane()
            ocrState = .failed("Screen Recording permission is required. Toggle LangFlip on and try again.")
            return
        }

        let pngURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("langflip-onboarding-screen-text-\(getpid())-\(Int(Date().timeIntervalSince1970)).png")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-t", "png", "-o", pngURL.path]
        task.terminationHandler = { proc in
            DispatchQueue.main.async {
                guard proc.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: pngURL.path),
                      let imageData = try? Data(contentsOf: pngURL),
                      !imageData.isEmpty
                else {
                    try? FileManager.default.removeItem(at: pngURL)
                    ocrState = .idle
                    return
                }

                ocrState = .running("Reading selected screenshot area...")
                let request = AIOcrRequest(imageBase64: imageData.base64EncodedString())
                AIAssistantManager.shared.current.extractTextFromImage(request) { result in
                    DispatchQueue.main.async {
                        defer { try? FileManager.default.removeItem(at: pngURL) }
                        switch result {
                        case .extracted(let output):
                            let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(clean, forType: .string)
                            ocrState = .success("Copied: \(clean)")
                        case .unsupported:
                            ocrState = .failed("selected model does not support image input")
                        case .failed(let reason):
                            ocrState = .failed(reason)
                        }
                    }
                }
            }
        }

        do {
            try task.run()
        } catch {
            try? FileManager.default.removeItem(at: pngURL)
            ocrState = .failed("Could not launch screen capture: \(error.localizedDescription)")
        }
    }

    private var isOllamaAppInstalled: Bool {
        let appURL = URL(fileURLWithPath: "/Applications/Ollama.app")
        return FileManager.default.fileExists(atPath: appURL.path)
    }

    private func openOllamaDownloadPage() {
        if let downloadURL = URL(string: "https://ollama.com/download/mac") {
            NSWorkspace.shared.open(downloadURL)
        }
    }

    private func isOllamaModelInstalled(_ model: String) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return false
            }
            let decoded = try JSONDecoder().decode(OnboardingOllamaTagsResponse.self, from: data)
            let canonical = canonicalModelTag(model)
            return decoded.models.contains { canonicalModelTag($0.name) == canonical }
        } catch {
            return false
        }
    }

    private func canonicalModelTag(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(":latest") {
            return String(trimmed.dropLast(":latest".count))
        }
        return trimmed
    }

    nonisolated private static func pullOllamaModel(
        _ model: String,
        progress: @escaping @MainActor (String) -> Void
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let executableURL = ollamaExecutableURL() else {
                return "Ollama was not found. Install Ollama, open it once, then try again."
            }

            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["pull", model]
            process.standardOutput = pipe
            process.standardError = pipe

            let outputBuffer = LockedOutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }
                let message = Self.ollamaProgressMessage(from: outputBuffer.appendAndRead(chunk), model: model)
                if let message {
                    Task { @MainActor in
                        progress(message)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                return "Could not open Ollama: \(error.localizedDescription)"
            }

            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            let output: String? = outputBuffer.read()
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .suffix(2)
                .joined(separator: " ")

            guard process.terminationStatus == 0 else {
                let detail = output?.isEmpty == false ? " \(output!)" : ""
                return "Ollama could not download \(model).\(detail)"
            }
            return nil
        }.value
    }

    nonisolated private static func ollamaProgressMessage(from output: String, model: String) -> String? {
        let lines = output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }

        if let percentRange = last.range(of: #"\d{1,3}%"#, options: .regularExpression) {
            let percent = String(last[percentRange])
            return "Downloading Qwen 3.5 2B... \(percent)"
        }

        let lower = last.lowercased()
        if lower.contains("pulling manifest") { return "Preparing Qwen 3.5 download..." }
        if lower.contains("verifying") { return "Verifying Qwen 3.5..." }
        if lower.contains("writing manifest") { return "Finishing Qwen 3.5 install..." }
        if lower.contains("success") { return "Qwen 3.5 downloaded." }

        return "Downloading Qwen 3.5 2B..."
    }

    nonisolated private static func ollamaExecutableURL() -> URL? {
        let candidates = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private struct OnboardingOllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
}

private final class LockedOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func appendAndRead(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        value += chunk
        return value
    }

    func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
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
                return "Lets LangFlip receive keyboard events even while you type in another app."
            }
        }

        var instruction: LocalizedStringKey {
            switch self {
            case .accessibility:
                return "Click below, find **LangFlip** in the list and toggle it on."
            case .inputMonitoring:
                return "Click below, press **+** if LangFlip is missing, add **/Applications/LangFlip.app**, then toggle it on."
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
                // Do not call CGRequestListenEventAccess here. On recent
                // macOS builds it can make the privacy APIs report
                // "granted" immediately even when LangFlip is not visible
                // in the Input Monitoring list yet. Opening the pane and
                // waiting for the real toggle keeps onboarding honest.
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
            Text(step.instruction)
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
