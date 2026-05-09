import SwiftUI
import AppKit
import ServiceManagement

/// Top-level Preferences view: 5 sections covering everything that used to
/// live in the menubar. The menubar keeps only quick toggles + the
/// "Preferences…" entry point.
///
/// Uses a segmented Picker rather than SwiftUI's `TabView` because the
/// macOS TabView styling pads the selected tab's highlight more than the
/// label requires, so labels and the blue selection rect don't visually
/// line up (especially noticeable on short tab names like "General").
struct PreferencesView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case languages = "Languages"
        case behavior = "Behavior"
        case models = "AI"
        case apps = "Apps"
        case about = "About"

        var id: Self { self }
    }

    @State private var section: Section = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch section {
                case .general:   GeneralTab()
                case .languages: LanguagesTab()
                case .behavior:  BehaviorTab()
                case .models:    ModelsTab()
                case .apps:      AppsTab()
                case .about:     AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 440)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage("lf.enabled") private var enabled = true
    @AppStorage("lf.soundEnabled") private var soundEnabled = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var permissions = PermissionStatus.current()
    @State private var exceptionsCount = BackspaceLearner.shared.exceptions.count

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $enabled)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        launchAtLogin = newValue
                        LaunchAtLogin.set(newValue)
                        // Re-read in case the system rejected the change.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                Toggle("Play sound on flip", isOn: $soundEnabled)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    granted: permissions.accessibility,
                    open: PermissionStatus.openAccessibilityPane
                )
                permissionRow(
                    title: "Input Monitoring",
                    granted: permissions.inputMonitoring,
                    open: PermissionStatus.openInputMonitoringPane
                )
            }

            Section("Statistics") {
                HStack {
                    Text("Learned exceptions")
                    Spacer()
                    Text("\(exceptionsCount)").foregroundColor(.secondary)
                    Button("Forget all") {
                        BackspaceLearner.shared.clearExceptions()
                        exceptionsCount = 0
                    }
                    .disabled(exceptionsCount == 0)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            permissions = PermissionStatus.current()
            exceptionsCount = BackspaceLearner.shared.exceptions.count
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(granted ? .green : .orange)
            Text(title)
            Spacer()
            Button("Open System Settings", action: open)
                .controlSize(.small)
        }
    }
}

// MARK: - Languages

private struct LanguagesTab: View {
    @AppStorage("lf.primaryLanguage") private var primary = "uk"
    @AppStorage("lf.secondaryLanguage") private var secondary = ""

    var body: some View {
        Form {
            Section {
                Picker("Primary language", selection: $primary) {
                    Text("Українська").tag("uk")
                    Text("Русский").tag("ru")
                }
                .onChange(of: primary) { newValue in
                    // Clearing the secondary if it now collides with the primary.
                    if secondary == newValue { secondary = "" }
                }

                Picker("Secondary language", selection: $secondary) {
                    Text("None").tag("")
                    if primary != "uk" { Text("Українська").tag("uk") }
                    if primary != "ru" { Text("Русский").tag("ru") }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Double-tap ⇧ swaps with the **primary** language.", systemImage: "1.circle")
                    Label("Triple-tap ⇧ swaps with the **secondary** language.", systemImage: "2.circle")
                    Label("Press both ⇧ at once to pause / resume.", systemImage: "pause.circle")
                }
                .font(.callout)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Behavior

private struct BehaviorTab: View {
    @AppStorage("lf.autoFlip") private var autoFlip = true
    @AppStorage("lf.doubleCapsFix") private var doubleCapsFix = true
    @AppStorage("lf.crossLayoutFix") private var crossLayoutFix = true
    @AppStorage("lf.suppressInFullscreen") private var suppressInFullscreen = false
    @AppStorage("lf.showOverlay") private var showOverlay = true
    @AppStorage("lf.hotkeyPreset") private var hotkeyPreset = HotkeyPreset.doubleShift.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: $hotkeyPreset) {
                    ForEach(HotkeyPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset.rawValue)
                    }
                }
                helpText("Pick the gesture that flips the last word or selection. Heavy-use modifiers like plain Cmd / Option are intentionally excluded — they'd false-fire on rapid system shortcuts. Pressing both Shifts at once still pauses the app regardless of this setting.")
            }
            Section {
                Toggle("Auto-flip on word boundary", isOn: $autoFlip)
                helpText("After a space or punctuation, if the just-typed word reads as gibberish in the current layout but a real word in another, fix it automatically. Press Backspace right after to undo and teach the app to skip that word forever.")
            }
            Section {
                Toggle("Fix sticky-shift typos (WOrld → World)", isOn: $doubleCapsFix)
                helpText("Catches the classic two-uppercase mistake. Only applied when the corrected form is a real dictionary word, so acronyms like OAuth aren't mangled.")
            }
            Section {
                Toggle("Fix UK ↔ RU letter slips (ы ↔ і, э ↔ є)", isOn: $crossLayoutFix)
                helpText("Catches words where one Russian-only letter (ы, э) is sitting in an otherwise Ukrainian word — or vice versa. \"пыдтримую\" → \"підтримую\", \"эдиний\" → \"єдиний\", \"єто\" → \"это\". Only fires when the corrected form is in the target language's dictionary.")
            }
            Section {
                HStack {
                    Toggle("Show flip overlay", isOn: $showOverlay)
                    Spacer()
                    Button("Preview") {
                        // Force the overlay to play even when the user has
                        // it toggled off, so they can see what they'd be
                        // opting into before flipping the switch.
                        let wasOn = Settings.shared.showOverlay
                        Settings.shared.showOverlay = true
                        FlipOverlay.shared.show()
                        if !wasOn {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                Settings.shared.showOverlay = false
                            }
                        }
                    }
                    .controlSize(.small)
                }
                helpText("A small confirmation flourish — the LangFlip icon bounces up at the bottom of the screen and does a 360° flip — every time the app rewrites text. Off by default; turn on if you want a visible cue every flip.")
            }
            Section {
                Toggle("Pause auto-flip in fullscreen apps", isOn: $suppressInFullscreen)
                helpText("Useful for games and video players. Off by default — many users want flipping to keep working in a fullscreen browser or note app.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Models (AI)

private struct ModelsTab: View {
    private let releaseAIModes: [AIMode] = [.off, .appleFoundation, .ollama, .openai]

    @AppStorage("lf.aiMode") private var aiMode = AIMode.off.rawValue
    @AppStorage("lf.grammarCheckOnSingleShift") private var grammarOnSingleShift = false
    @AppStorage("lf.grammarCheckOnSentenceEnd") private var grammarOnSentenceEnd = false
    @AppStorage("lf.translationHotkeyEnabled") private var translationHotkeyEnabled = false
    @AppStorage("lf.screenTextCaptureHotkeyEnabled") private var screenTextCaptureHotkeyEnabled = true
    @AppStorage("lf.translationTarget") private var translationTarget = Layout.en.rawValue
    @AppStorage("lf.ollamaModel") private var ollamaModel = "qwen3.5:4b"
    @AppStorage("lf.tripleShiftAction") private var tripleShiftAction = TripleShiftAction.secondaryLanguage.rawValue
    @AppStorage("lf.cloudProvider") private var cloudProvider = AICloudProvider.openRouter.rawValue
    @AppStorage("lf.openaiModel") private var openaiModel = "gpt-5-nano"
    @AppStorage("lf.openaiBaseURL") private var openaiBaseURL = "https://api.openai.com/v1"

    /// API key kept in Keychain (NOT @AppStorage). Mirror it through
    /// @State so SwiftUI re-renders the SecureField properly. We
    /// write back on commit via .onSubmit / .onChange.
    @State private var openaiKeyDraft: String = KeychainStore.getString(account: KeychainStore.openAIAPIKey) ?? ""

    var body: some View {
        Form {
            Section("Mode") {
                Picker("AI assistant", selection: $aiMode) {
                    ForEach(releaseAIModes) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                    helpText("AI is opt-in. For most Macs today, Ollama with Qwen 3.5 4B is the easiest local setup: it stays on-device, works on current macOS versions, and can handle both grammar fixes and screen text capture.")
            }

            // Backend-specific config sits directly under Mode — that's
            // where the eye lands after switching modes. Burying these
            // blocks at the bottom of the form (where they were
            // initially placed) made it easy to pick e.g. Ollama and
            // never realize a model selection was needed too.
            if AIMode(rawValue: aiMode) == .ollama {
                Section("Ollama") {
                    OllamaModelPicker(selectedModel: $ollamaModel)
                    helpText("Pick a model already pulled in Ollama, or download Qwen 2.5 for grammar and Qwen 3.5 4B for screen text capture. LangFlip talks only to `127.0.0.1:11434`, so local AI stays on this Mac.")
                }
            }

            if AIMode(rawValue: aiMode) == .openai {
                Section("OpenAI / compatible cloud") {
                    Picker("Provider", selection: $cloudProvider) {
                        ForEach(AICloudProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .onChange(of: cloudProvider) { raw in
                        guard let provider = AICloudProvider(rawValue: raw) else { return }
                        if provider != .custom {
                            openaiBaseURL = provider.defaultBaseURL
                        }
                        if openaiModel.isEmpty || openaiModel == "gpt-5-nano" || openaiModel == "openrouter/auto" {
                            openaiModel = provider.defaultModel
                        }
                    }

                    SecureField(apiKeyPlaceholder, text: $openaiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: openaiKeyDraft) { newValue in
                            KeychainStore.setString(newValue, account: KeychainStore.openAIAPIKey)
                        }

                    if AICloudProvider(rawValue: cloudProvider) == .openRouter {
                        OpenRouterModelPicker(selectedModel: $openaiModel)
                    } else {
                        TextField("Model", text: $openaiModel)
                            .textFieldStyle(.roundedBorder)
                    }

                    if AICloudProvider(rawValue: cloudProvider) == .custom {
                        TextField("Base URL", text: $openaiBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    Link(cloudProviderLinkTitle, destination: cloudProviderLinkURL)

                    helpText(cloudHelpText)
                }
                .onAppear {
                    applyCloudProviderDefaultsIfNeeded()
                }
            }

            if AIMode(rawValue: aiMode) != .off {
                Section("Test") {
                    AIModelTestView()
                    if AIMode(rawValue: aiMode) == .ollama {
                        Divider()
                        AIOCRTestView()
                    }
                }
            }

            Section("Features") {
                Toggle("AI fix on single Shift tap", isOn: $grammarOnSingleShift)
                helpText("Single clean tap of Shift (no other key in between, no second tap within ~350 ms) is the all-purpose AI fix gesture. If you have text selected, the AI rewrites the selection — typos, grammar, wrong-keyboard-layout gibberish, mid-sentence script flips. If nothing is selected, it rewrites the most recent sentence. Double-tap Shift stays purely mechanical (layout flip), so the two gestures don't fight. Off by default — opt in once you trust the model on your text.")

                Toggle("Auto-fix sentences when you type . ! or ?", isOn: $grammarOnSentenceEnd)
                helpText("Each time you finish a sentence with a period, exclamation mark, or question mark, the AI rewrites it in place to fix typos and grammar. The fix lands silently a moment later. If you keep typing past the next sentence boundary while the model is thinking, the fix is dropped to avoid disrupting fast typing. Off by default — silent rewrites are powerful and you should opt in only when you trust the model.")

                Picker("Triple-tap Shift action", selection: $tripleShiftAction) {
                    ForEach(TripleShiftAction.allCases) { a in
                        Text(a.displayName).tag(a.rawValue)
                    }
                }
                helpText("Triple-tap is the secondary-language gesture by default. If you don't use a secondary language, repurpose it for AI fix on selection — useful as a stronger or more-deliberate alternative to single-tap when you've already trained the muscle memory.")
            }

            Section("Translate selection") {
                Picker("Default target", selection: $translationTarget) {
                    ForEach(Layout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout.rawValue)
                    }
                }
                helpText("Used by the menubar's Translate submenu (highlights this entry) and the ⌃⌥T hotkey below.")

                Toggle("Enable ⇧Space hotkey to translate selection", isOn: $translationHotkeyEnabled)
                helpText("When this is on AND AI is on, pressing Shift + Space translates the current text selection into the default target above. Shift+Space is rare in normal typing (you release Shift before the trailing space), so hijacking it is generally safe — but disable here if you find a conflict. The menubar's Translate selection → submenu always works regardless of this toggle.")
            }

            if AIMode(rawValue: aiMode) == .ollama {
                Section("Screen text capture") {
                    Toggle("Enable ⇧⌘S hotkey to capture text from screen", isOn: $screenTextCaptureHotkeyEnabled)
                    helpText("Uses the selected vision-capable Ollama model to read text from a selected screen region and copy it to the clipboard. Disable this if ⇧⌘S conflicts with Save As or Duplicate in apps you use often.")
                }
            }

            Section("Privacy") {
                Text(privacyDisclosure)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if aiMode == AIMode.bundledModel.rawValue {
                aiMode = AIMode.ollama.rawValue
            }
        }
    }

    @ViewBuilder
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Disclosure copy that matches the chosen AI backend. We're
    /// explicit about the `.openai` cloud mode because it's the only
    /// one that ever sends user text off-device — switching to it is
    /// a meaningful trust trade-off and the UI shouldn't be coy about
    /// it.
    private var privacyDisclosure: String {
        let mode = AIMode(rawValue: aiMode) ?? .off
        switch mode {
        case .off:
            return "AI is off. The rules engine alone runs entirely on your Mac. No text leaves your machine."
        case .appleFoundation:
            return "Apple Intelligence runs on-device. Apple's Foundation Models execute locally — no text is sent over the network for AI inference. The rest of LangFlip is local too."
        case .ollama:
            return "Ollama runs on-device. The text you write is sent only to the daemon at 127.0.0.1:11434, which lives on your Mac. Nothing leaves the machine for AI inference."
        case .bundledModel:
            return "Bundled MLX models are not part of this release. Use Ollama with Qwen 2.5 for local grammar fixes."
        case .openai:
            return "Cloud mode: each AI feature you trigger sends the relevant text (a sentence, a selection, etc.) to the endpoint configured above. With the default Base URL, that's OpenAI in the US. Your API key is stored in macOS Keychain. Disable any time by switching back to Off, Apple Intelligence, or Ollama. The rules-based layout-flip core remains 100% local regardless of this setting."
        }
    }

    private var selectedCloudProvider: AICloudProvider {
        AICloudProvider(rawValue: cloudProvider) ?? .openRouter
    }

    private var apiKeyPlaceholder: String {
        switch selectedCloudProvider {
        case .openRouter: return "OpenRouter API key"
        case .openAI:     return "OpenAI API key (sk-...)"
        case .custom:     return "API key"
        }
    }

    private var cloudProviderLinkTitle: String {
        switch selectedCloudProvider {
        case .openRouter: return "Open OpenRouter API keys..."
        case .openAI:     return "Open OpenAI API keys..."
        case .custom:     return "Open provider dashboard..."
        }
    }

    private var cloudProviderLinkURL: URL {
        switch selectedCloudProvider {
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")!
        case .openAI:     return URL(string: "https://platform.openai.com/api-keys")!
        case .custom:     return URL(string: "https://openrouter.ai/settings/keys")!
        }
    }

    private var cloudHelpText: String {
        switch selectedCloudProvider {
        case .openRouter:
            return "OpenRouter uses one billing account and one API key for hundreds of models. The model list below is fetched from OpenRouter's `/api/v1/models`; free models are marked as free, and cheap models show approximate input/output prices per 1M tokens. For short grammar fixes, free or tiny low-cost models are usually enough."
        case .openAI:
            return "LangFlip sends requests to OpenAI's chat-completions endpoint with Bearer auth. Your API key is stored in macOS Keychain, never in plain preferences."
        case .custom:
            return "Use any OpenAI-compatible chat-completions provider. LangFlip POSTs to `<Base URL>/chat/completions` with Bearer auth and the model string you enter."
        }
    }

    private func applyCloudProviderDefaultsIfNeeded() {
        let provider = selectedCloudProvider
        guard provider != .custom else { return }
        if openaiBaseURL.isEmpty ||
           (provider == .openRouter && openaiBaseURL == AICloudProvider.openAI.defaultBaseURL) ||
           (provider == .openAI && openaiBaseURL == AICloudProvider.openRouter.defaultBaseURL) {
            openaiBaseURL = provider.defaultBaseURL
        }
        if openaiModel.isEmpty ||
           (provider == .openRouter && openaiModel == AICloudProvider.openAI.defaultModel) ||
           (provider == .openAI && openaiModel == AICloudProvider.openRouter.defaultModel) {
            openaiModel = provider.defaultModel
        }
    }
}

private enum AICloudProvider: String, CaseIterable, Identifiable {
    case openRouter
    case openAI
    case custom

    var id: Self { self }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAI:     return "OpenAI direct"
        case .custom:     return "Custom compatible"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI:     return "https://api.openai.com/v1"
        case .custom:     return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: return "openrouter/auto"
        case .openAI:     return "gpt-5-nano"
        case .custom:     return ""
        }
    }
}

private struct AIModelTestView: View {
    private enum TestState: Equatable {
        case idle
        case running(Date)
        case success(output: String, seconds: TimeInterval)
        case unchanged(seconds: TimeInterval)
        case failed(String)
    }

    private let sample = "World is wery gandgerous plsce to leave in!"

    @State private var state: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sample)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    statusText
                        .font(.caption)
                        .foregroundColor(statusColor)
                }
                Spacer()
                Button {
                    runTest()
                } label: {
                    Image(systemName: isRunning ? "hourglass" : "play.fill")
                }
                .help("Run grammar test with the selected AI model")
                .disabled(isRunning)
            }

            if let output {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    @ViewBuilder
    private var statusText: some View {
        switch state {
        case .idle:
            Text("Runs the same grammar rewrite path used by Shift and sentence-end auto-fix.")
        case .running:
            Text("Running model test...")
        case .success(_, let seconds):
            Text(String(format: "Model replied in %.1f s.", seconds))
        case .unchanged(let seconds):
            Text(String(format: "Model replied in %.1f s and returned unchanged text.", seconds))
        case .failed(let reason):
            Text("Failed: \(reason)")
        }
    }

    private var statusColor: Color {
        switch state {
        case .failed:
            return .orange
        case .success:
            return .green
        default:
            return .secondary
        }
    }

    private var output: String? {
        switch state {
        case .success(let output, _):
            return output
        default:
            return nil
        }
    }

    private func runTest() {
        let started = Date()
        state = .running(started)

        let request = AIRewriteRequest(
            text: sample,
            preferredLayout: .en
        )
        AIAssistantManager.shared.current.rewriteSentence(request) { result in
            DispatchQueue.main.async {
                let seconds = Date().timeIntervalSince(started)
                switch result {
                case .rewritten(let output):
                    state = .success(output: output, seconds: seconds)
                case .unchanged:
                    state = .unchanged(seconds: seconds)
                case .unsupported:
                    state = .failed("selected assistant does not support grammar rewrite")
                case .failed(let reason):
                    state = .failed(reason)
                }
            }
        }
    }
}

private struct AIOCRTestView: View {
    private enum TestState: Equatable {
        case idle
        case running(Date)
        case success(output: String, seconds: TimeInterval)
        case failed(String)
    }

    private let sample = "LangFlip OCR test"

    @State private var state: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sample)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    statusText
                        .font(.caption)
                        .foregroundColor(statusColor)
                }
                Spacer()
                Button {
                    runTest()
                } label: {
                    Image(systemName: isRunning ? "hourglass" : "viewfinder")
                }
                .help("Run OCR test with the selected Ollama model")
                .disabled(isRunning)
            }

            if let output {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    @ViewBuilder
    private var statusText: some View {
        switch state {
        case .idle:
            Text("Tests the image-to-text path without using screen capture permissions.")
        case .running:
            Text("Running OCR model test...")
        case .success(_, let seconds):
            Text(String(format: "OCR replied in %.1f s.", seconds))
        case .failed(let reason):
            Text("Failed: \(reason)")
        }
    }

    private var statusColor: Color {
        switch state {
        case .failed:
            return .orange
        case .success:
            return .green
        default:
            return .secondary
        }
    }

    private var output: String? {
        switch state {
        case .success(let output, _):
            return output
        default:
            return nil
        }
    }

    private func runTest() {
        guard let imageBase64 = makeOCRSampleImageBase64() else {
            state = .failed("could not create test image")
            return
        }

        let started = Date()
        state = .running(started)

        AIAssistantManager.shared.current.extractTextFromImage(
            AIOcrRequest(imageBase64: imageBase64)
        ) { result in
            DispatchQueue.main.async {
                let seconds = Date().timeIntervalSince(started)
                switch result {
                case .extracted(let output):
                    state = .success(
                        output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                        seconds: seconds
                    )
                case .unsupported:
                    state = .failed("selected model does not support image input")
                case .failed(let reason):
                    state = .failed(reason)
                }
            }
        }
    }

    private func makeOCRSampleImageBase64() -> String? {
        let image = NSImage(size: NSSize(width: 720, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 720, height: 180).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        sample.draw(
            in: NSRect(x: 36, y: 72, width: 650, height: 60),
            withAttributes: attrs
        )
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }
        return png.base64EncodedString()
    }
}

private struct OllamaModelPicker: View {
    private enum InstallState: Equatable {
        case idle
        case installing
        case finished
        case failed
    }

    private let grammarModel = "qwen2.5"
    private let visionModel = "qwen3.5:4b"

    @Binding var selectedModel: String

    @State private var installedModels: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var installState: InstallState = .idle
    @State private var installingModel: String?
    @State private var installMessage: String?

    private var dropdownModels: [String] {
        var models: [String] = []
        for model in [selectedModel] + installedModels + [grammarModel, visionModel] {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = canonicalModelTag(trimmed)
            let alreadyIncluded = models.contains { canonicalModelTag($0) == canonical }
            if !trimmed.isEmpty && !alreadyIncluded {
                models.append(trimmed)
            }
        }
        return models
    }

    private var isInstalling: Bool {
        installingModel != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(dropdownModels, id: \.self) { model in
                        Text(label(for: model)).tag(model)
                    }
                }

                Button {
                    Task { await refreshInstalledModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh installed Ollama models")
                .disabled(isLoading)

                Button {
                    openOllamaOrDownloadPage()
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await refreshInstalledModels()
                    }
                } label: {
                    Image(systemName: "play.circle")
                }
                .help("Open Ollama")
            }

            HStack(spacing: 8) {
                Button(installButtonTitle(for: grammarModel)) {
                    Task { await installModel(grammarModel) }
                }
                .disabled(isModelInstalled(grammarModel) || isInstalling)

                Button(installButtonTitle(for: visionModel)) {
                    Task { await installModel(visionModel) }
                }
                .disabled(isModelInstalled(visionModel) || isInstalling)

                if isModelInstalled(grammarModel), isModelInstalled(visionModel) {
                    Text("Ready for grammar and screen text capture.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if isModelInstalled(grammarModel) {
                    Text("Ready for local grammar fixes.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if isModelInstalled(visionModel) {
                    Text("Ready for local grammar and OCR tests.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            TextField("Custom model tag", text: $selectedModel)
                .textFieldStyle(.roundedBorder)

            if isLoading {
                Text("Refreshing local Ollama models...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let installMessage {
                Text(installMessage)
                    .font(.caption)
                    .foregroundColor(installState == .failed ? .red : .secondary)
            } else if !installedModels.isEmpty {
                Text("Found \(installedModels.count) local model\(installedModels.count == 1 ? "" : "s").")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await refreshInstalledModels()
        }
    }

    private func installButtonTitle(for model: String) -> String {
        if isModelInstalled(model) {
            return "\(displayName(for: model)) installed"
        }
        if installingModel == model {
            return "Downloading \(displayName(for: model))..."
        }
        switch installState {
        case .failed: return "Try \(displayName(for: model)) again"
        case .idle, .installing, .finished: return "Download \(displayName(for: model))"
        }
    }

    private func label(for model: String) -> String {
        if canonicalModelTag(model) == grammarModel {
            return "Qwen 2.5 (recommended)"
        }
        if canonicalModelTag(model) == visionModel {
            return "Qwen 3.5 4B (vision)"
        }
        return model
    }

    private func displayName(for model: String) -> String {
        if canonicalModelTag(model) == grammarModel {
            return "Qwen 2.5"
        }
        if canonicalModelTag(model) == visionModel {
            return "Qwen 3.5 4B"
        }
        return model
    }

    private func isModelInstalled(_ model: String) -> Bool {
        let canonical = canonicalModelTag(model)
        return installedModels.contains { canonicalModelTag($0) == canonical }
    }

    private func canonicalModelTag(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(":latest") {
            return String(trimmed.dropLast(":latest".count))
        }
        return trimmed
    }

    @MainActor
    private func installModel(_ model: String) async {
        selectedModel = model
        installState = .installing
        installingModel = model
        loadError = nil
        installMessage = "Opening Ollama and downloading \(displayName(for: model)). This can take a few minutes the first time."
        defer { installingModel = nil }
        openOllamaOrDownloadPage()

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let failure = await Self.pullOllamaModel(model) {
            installState = .failed
            installMessage = failure
        } else {
            installState = .finished
            installMessage = "\(displayName(for: model)) is ready."
            await refreshInstalledModels()
        }
    }

    @MainActor
    private func refreshInstalledModels() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                loadError = "Ollama is reachable, but returned an unexpected response."
                installedModels = []
                return
            }
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            installedModels = decoded.models.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            loadError = "Ollama is not running. Open Ollama, then refresh."
            installedModels = []
        }
    }

    private func openOllamaOrDownloadPage() {
        let appURL = URL(fileURLWithPath: "/Applications/Ollama.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }

        if let downloadURL = URL(string: "https://ollama.com/download/mac") {
            NSWorkspace.shared.open(downloadURL)
        }
    }

    nonisolated private static func pullOllamaModel(_ model: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let executableURL = ollamaExecutableURL() else {
                return "Ollama command-line tool was not found. Install Ollama from ollama.com, open it once, then try again."
            }

            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["pull", model]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return "Could not start Ollama: \(error.localizedDescription)"
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?
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

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
}

private struct OpenRouterModelPicker: View {
    @Binding var selectedModel: String

    @State private var models: [OpenRouterModel] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var dropdownModels: [OpenRouterModel] {
        var result: [OpenRouterModel] = [
            OpenRouterModel(
                id: "openrouter/auto",
                name: "OpenRouter Auto",
                pricing: .init(prompt: nil, completion: nil),
                architecture: nil
            )
        ]

        for model in models {
            if !result.contains(where: { $0.id == model.id }) {
                result.append(model)
            }
        }

        if !selectedModel.isEmpty && !result.contains(where: { $0.id == selectedModel }) {
            result.insert(
                OpenRouterModel(
                    id: selectedModel,
                    name: selectedModel,
                    pricing: .init(prompt: nil, completion: nil),
                    architecture: nil
                ),
                at: 0
            )
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(dropdownModels) { model in
                        Text(label(for: model)).tag(model.id)
                    }
                }

                Button {
                    Task { await refreshModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh OpenRouter models")
                .disabled(isLoading)
            }

            TextField("Custom model id", text: $selectedModel)
                .textFieldStyle(.roundedBorder)

            if isLoading {
                Text("Refreshing OpenRouter models...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !models.isEmpty {
                Text("Showing free models first, then the cheapest text models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await refreshModels()
        }
    }

    private func label(for model: OpenRouterModel) -> String {
        let price = model.priceLabel
        if price.isEmpty {
            return "\(model.name) - \(model.id)"
        }
        return "\(model.name) - \(price)"
    }

    @MainActor
    private func refreshModels() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        guard let url = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                loadError = "OpenRouter returned an unexpected response."
                models = []
                return
            }
            let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
            models = decoded.data
                .filter { $0.supportsTextOutput }
                .sorted(by: OpenRouterModel.isBetterForProofreading)
                .prefix(80)
                .map { $0 }
        } catch {
            loadError = "Could not load OpenRouter models. Check your internet connection."
            models = []
        }
    }
}

private struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterModel]
}

private struct OpenRouterModel: Decodable, Identifiable {
    struct Pricing: Decodable {
        let prompt: String?
        let completion: String?
    }

    struct Architecture: Decodable {
        let outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case outputModalities = "output_modalities"
        }
    }

    let id: String
    let name: String
    let pricing: Pricing
    let architecture: Architecture?

    var supportsTextOutput: Bool {
        architecture?.outputModalities?.contains("text") ?? true
    }

    var promptPrice: Double {
        Double(pricing.prompt ?? "") ?? .infinity
    }

    var completionPrice: Double {
        Double(pricing.completion ?? "") ?? .infinity
    }

    var isFree: Bool {
        promptPrice == 0 && completionPrice == 0
    }

    var priceLabel: String {
        if id == "openrouter/auto" { return "automatic routing" }
        if isFree { return "free" }
        guard promptPrice.isFinite, completionPrice.isFinite else { return "" }
        let input = promptPrice * 1_000_000
        let output = completionPrice * 1_000_000
        return String(format: "$%.2f / $%.2f per 1M", input, output)
    }

    static func isBetterForProofreading(_ lhs: OpenRouterModel, _ rhs: OpenRouterModel) -> Bool {
        if lhs.isFree != rhs.isFree { return lhs.isFree }
        let lhsCost = lhs.promptPrice + lhs.completionPrice
        let rhsCost = rhs.promptPrice + rhs.completionPrice
        if lhsCost != rhsCost { return lhsCost < rhsCost }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Apps

private struct AppsTab: View {
    @State private var userBlocked = Array(Settings.shared.userBlacklist).sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disabled in")
                .font(.headline)
            if userBlocked.isEmpty {
                Text("No apps blocked. Use the menu bar item “Auto-flip in <App>” to disable auto-flip in the focused app.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            } else {
                List {
                    ForEach(userBlocked, id: \.self) { bundleID in
                        HStack {
                            Text(bundleID).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("Remove") { remove(bundleID) }
                                .controlSize(.small)
                        }
                    }
                }
                .frame(minHeight: 100, maxHeight: 200)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Built-in blocks")
                    .font(.headline)
                Text("These can't be turned on — auto-flip would corrupt commands or credentials.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Terminals: Terminal, iTerm2, Warp, Ghostty, Alacritty, Kitty, Hyper, Tabby")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Password managers: 1Password, LastPass, Dashlane, Bitwarden, KeePassXC, plus anything containing “password” / “keychain” / “vault” in its bundle ID.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func remove(_ bundleID: String) {
        var set = Settings.shared.userBlacklist
        set.remove(bundleID)
        Settings.shared.userBlacklist = set
        userBlocked = Array(set).sorted()
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("LangFlip")
                .font(.system(size: 24, weight: .semibold))
            Text("Version \(version)")
                .font(.callout)
                .foregroundColor(.secondary)

            Text("Free, open-source keyboard layout corrector for macOS.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com/MikeKorotych/lang-flip")!)
                Link("MIT License", destination: URL(string: "https://github.com/MikeKorotych/lang-flip/blob/main/LICENSE")!)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
