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
    @AppStorage("lf.aiMode") private var aiMode = AIMode.off.rawValue
    @AppStorage("lf.activeModelID") private var activeModelID = ""
    @AppStorage("lf.grammarCheckOnSingleShift") private var grammarOnSingleShift = false
    @AppStorage("lf.grammarCheckOnSentenceEnd") private var grammarOnSentenceEnd = false
    @AppStorage("lf.smartSelectionFix") private var smartSelectionFix = false
    @AppStorage("lf.translationHotkeyEnabled") private var translationHotkeyEnabled = false
    @AppStorage("lf.translationTarget") private var translationTarget = Layout.en.rawValue
    @AppStorage("lf.ollamaModel") private var ollamaModel = "qwen2.5"
    @AppStorage("lf.tripleShiftAction") private var tripleShiftAction = TripleShiftAction.secondaryLanguage.rawValue
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
                    ForEach(AIMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                helpText("AI is opt-in. When enabled, the rules engine asks an on-device model for a second opinion before auto-flipping. Apple Intelligence requires macOS 26 or later; on older systems it falls back to off until you pick a downloadable model.")
            }

            // Backend-specific config sits directly under Mode — that's
            // where the eye lands after switching modes. Burying these
            // blocks at the bottom of the form (where they were
            // initially placed) made it easy to pick e.g. Ollama and
            // never realize a model selection was needed too.
            if AIMode(rawValue: aiMode) == .ollama {
                Section("Ollama") {
                    OllamaModelPicker(selectedModel: $ollamaModel)
                    helpText("Pick a model already pulled in Ollama. LangFlip refreshes this list from `http://localhost:11434/api/tags`; if Ollama is closed, the recommended fallback stays available. Qwen 2.5 is the default because it is usually a better latency/quality trade-off for short grammar fixes than heavier Gemma variants.")
                }
            }

            if AIMode(rawValue: aiMode) == .openai {
                Section("OpenAI / compatible cloud") {
                    SecureField("API key (sk-…)", text: $openaiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: openaiKeyDraft) { newValue in
                            KeychainStore.setString(newValue, account: KeychainStore.openAIAPIKey)
                        }

                    TextField("Model", text: $openaiModel)
                        .textFieldStyle(.roundedBorder)

                    TextField("Base URL", text: $openaiBaseURL)
                        .textFieldStyle(.roundedBorder)

                    Link("Open OpenAI API keys...", destination: URL(string: "https://platform.openai.com/api-keys")!)

                    helpText("LangFlip POSTs to <Base URL>/chat/completions with Bearer auth — works for any OpenAI-compatible provider. Examples:\n  • OpenAI direct: https://api.openai.com/v1 + `gpt-5-nano`\n  • OpenRouter: https://openrouter.ai/api/v1 + `openai/gpt-oss-120b` (single key, hundreds of models)\n  • Together AI: https://api.together.xyz/v1 + `gpt-oss-120b`\n  • Groq: https://api.groq.com/openai/v1 + `llama-3.1-70b-versatile` (very fast, free tier)\n\nOpenAI API access uses an API key from your OpenAI account. Your key is stored in macOS Keychain (encrypted at rest with your login key), never in plain config. Empty the field to remove.")
                }
            }

            if AIMode(rawValue: aiMode) == .bundledModel {
                Section("Downloadable models") {
                    ForEach(ModelCatalog.all) { model in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName).font(.body)
                                Text(model.summary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(activeModelID == model.id ? "Active" : "Available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button(activeModelID == model.id ? "Active" : "Download") {
                                // Sprint D will wire this to ModelDownloader.
                                activeModelID = model.id
                            }
                            .controlSize(.small)
                            .disabled(activeModelID == model.id)
                        }
                        .padding(.vertical, 2)
                    }
                    helpText("Models live in ~/Library/Application Support/LangFlip/Models/. Download is verified against an EdDSA signature before installation. (Downloader lands in Sprint D — for now this is UI scaffolding only.)")
                }
            }

            Section("Features") {
                Toggle("Grammar fix on single Shift tap", isOn: $grammarOnSingleShift)
                helpText("When the AI is on, a single clean tap of Shift (no other key in between, no second tap within ~350 ms) fixes selected text first; if nothing is selected, it rewrites the most recent sentence to fix typos and grammar. Off by default — single Shift is a low-friction gesture and accidental fixes would be annoying. The rewrite is silent: no overlay, no sound, just the diff in your text.")

                Toggle("Auto-fix sentences when you type . ! or ?", isOn: $grammarOnSentenceEnd)
                helpText("Each time you finish a sentence with a period, exclamation mark, or question mark, the AI rewrites it in place to fix typos and grammar. The fix lands silently a moment later. If you keep typing past the next sentence boundary while the model is thinking, the fix is dropped to avoid disrupting fast typing. Off by default — silent rewrites are powerful and you should opt in only when you trust the model.")

                Toggle("Smart selection fix (AI fixes everything)", isOn: $smartSelectionFix)
                helpText("Select any text, then double-tap Shift. With this on, the AI rewrites the selection to fix typos, grammar, wrong-keyboard-layout gibberish, and mid-sentence script flips — anything it can repair while preserving meaning. Without this toggle, the same gesture only does a mechanical layout flip. Falls back to the mechanical flip if the AI is unavailable or declines.")

                Picker("Triple-tap Shift action", selection: $tripleShiftAction) {
                    ForEach(TripleShiftAction.allCases) { a in
                        Text(a.displayName).tag(a.rawValue)
                    }
                }
                helpText("If you don't use a secondary language, repurpose triple-tap-Shift as a non-conflicting AI gesture. Select text, triple-tap Shift, the AI rewrites it. Same fix-everything pipeline as the smart selection fix toggle above — bind it to whichever gesture fits your muscle memory better.")
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

            Section("Privacy") {
                Text(privacyDisclosure)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            return "Ollama runs on-device. The text you write is sent only to the daemon at localhost:11434, which lives on your Mac. Nothing leaves the machine for AI inference."
        case .bundledModel:
            return "Bundled MLX models run on-device once downloaded. (Downloader lands in a future sprint — for now this is UI scaffolding only.)"
        case .openai:
            return "Cloud mode: each AI feature you trigger sends the relevant text (a sentence, a selection, etc.) to the endpoint configured above. With the default Base URL, that's OpenAI in the US. Your API key is stored in macOS Keychain. Disable any time by switching back to Off, Apple Intelligence, or Ollama. The rules-based layout-flip core remains 100% local regardless of this setting."
        }
    }
}

private struct OllamaModelPicker: View {
    @Binding var selectedModel: String

    @State private var installedModels: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var dropdownModels: [String] {
        var models: [String] = []
        for model in ["qwen2.5"] + installedModels + [selectedModel] {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !models.contains(trimmed) {
                models.append(trimmed)
            }
        }
        return models
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

    private func label(for model: String) -> String {
        if model == "qwen2.5" {
            return "Qwen 2.5 (recommended)"
        }
        return model
    }

    @MainActor
    private func refreshInstalledModels() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        guard let url = URL(string: "http://localhost:11434/api/tags") else { return }
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
            loadError = "Ollama is not running, or no local model list is available."
            installedModels = []
        }
    }
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
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
