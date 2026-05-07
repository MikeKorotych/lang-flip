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
    @AppStorage("lf.suppressInFullscreen") private var suppressInFullscreen = false
    @AppStorage("lf.showOverlay") private var showOverlay = true

    var body: some View {
        Form {
            Section {
                Toggle("Auto-flip on word boundary", isOn: $autoFlip)
                helpText("After a space or punctuation, if the just-typed word reads as gibberish in the current layout but a real word in another, fix it automatically. Press Backspace right after to undo and teach the app to skip that word forever.")
            }
            Section {
                Toggle("Fix sticky-shift typos (WOrld → World)", isOn: $doubleCapsFix)
                helpText("Catches the classic two-uppercase mistake. Only applied when the corrected form is a real dictionary word, so acronyms like OAuth aren't mangled.")
            }
            Section {
                Toggle("Show flip overlay", isOn: $showOverlay)
                helpText("A small HUD-style banner pops up at the bottom of the screen when LangFlip rewrites text, showing what changed. Disappears after ~1.5 s.")
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
