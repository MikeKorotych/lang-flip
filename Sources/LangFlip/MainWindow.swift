import AppKit
import SwiftUI

/// Full main application window (sidebar + content), mirroring the reference
/// desktop app. Hand-rolled NSWindow like PreferencesWindowController so we
/// keep control of the activation policy for this menubar-only (LSUIElement)
/// app. The existing Preferences window stays as the "Advanced" surface for
/// now — the sidebar's gear opens it.
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    func show(section: MainSection? = nil) {
        if let section {
            MainNavigation.shared.section = section
        }
        if window == nil {
            let host = NSHostingController(rootView: MainView())
            let win = NSWindow(contentViewController: host)
            win.title = "Sayful"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.setContentSize(NSSize(width: 1040, height: 720))
            win.minSize = NSSize(width: 900, height: 600)
            win.isReleasedWhenClosed = false
            win.center()
            // The whole window (custom views + embedded settings Forms) follows
            // the user's theme choice via the window appearance; FlowTheme's
            // dynamic colors resolve to match.
            win.appearance = ThemeManager.shared.appearance
            win.backgroundColor = NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark
                    ? NSColor(srgbRed: 0.118, green: 0.114, blue: 0.110, alpha: 1)
                    : NSColor(srgbRed: 0.957, green: 0.945, blue: 0.925, alpha: 1)
            }

            // Title-bar controls — native accessory views render in the
            // title-bar band, on the same row as the traffic-light buttons.
            let leading = NSTitlebarAccessoryViewController()
            leading.layoutAttribute = .leading
            let leadingView = NSHostingView(rootView: TitlebarLeadingControls())
            leadingView.frame = NSRect(x: 0, y: 0, width: 38, height: 28)
            leading.view = leadingView
            win.addTitlebarAccessoryViewController(leading)

            let trailing = NSTitlebarAccessoryViewController()
            trailing.layoutAttribute = .trailing
            let trailingView = NSHostingView(rootView: TitlebarTrailingControls())
            trailingView.frame = NSRect(x: 0, y: 0, width: 104, height: 28)
            trailing.view = trailingView
            win.addTitlebarAccessoryViewController(trailing)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: win
            )
            window = win
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func handleWindowWillClose(_ note: Notification) {
        let otherVisible = NSApp.windows.contains {
            $0.isVisible && $0 !== window && $0.title == "Sayful"
        }
        if !otherVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Sections

enum MainSection: String, CaseIterable, Identifiable {
    case home, langflip, hotkeys, insights, dictionary, snippets, transforms, settings

    var id: String { rawValue }

    /// Top sidebar group — the speech-to-text features. `settings` lives at the
    /// bottom; the layout-flip tools (`secondary`) sit in their own group below.
    static let primary: [MainSection] = [.home, .insights, .snippets, .transforms]

    /// Layout-flip tools + global shortcuts, grouped apart from the STT features.
    static let secondary: [MainSection] = [.dictionary, .langflip, .hotkeys]

    var title: String {
        switch self {
        case .home:       return "Home"
        case .langflip:   return "LangFlip"
        case .hotkeys:    return "Hotkeys"
        case .insights:   return "Insights"
        case .dictionary: return "Dictionary"
        case .snippets:   return "Snippets"
        case .transforms: return "Transforms"
        case .settings:   return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home:       return "square.grid.2x2"
        case .langflip:   return "keyboard"
        case .hotkeys:    return "command"
        case .insights:   return "chart.bar"
        case .dictionary: return "character.book.closed"
        case .snippets:   return "scissors"
        case .transforms: return "wand.and.stars"
        case .settings:   return "gearshape"
        }
    }
}

/// Shared selection so menubar entry points (e.g. "Preferences…") can deep-link
/// the main window to a specific section.
final class MainNavigation: ObservableObject {
    static let shared = MainNavigation()
    @Published var section: MainSection = .home
    @Published var sidebarCollapsed = false
    private init() {}
}

// MARK: - Main view

struct MainView: View {
    @ObservedObject private var nav = MainNavigation.shared

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(section: $nav.section, collapsed: nav.sidebarCollapsed)
                .frame(width: nav.sidebarCollapsed ? 64 : 220)
            Divider().overlay(FlowTheme.cardStroke)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FlowTheme.paper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowTheme.paper)
    }

    @ViewBuilder
    private var detail: some View {
        // Settings hosts grouped Forms that scroll themselves — keep it out of
        // the outer ScrollView to avoid nested scrolling.
        if nav.section == .settings {
            SettingsHostView()
        } else {
            ScrollView {
                Group {
                    switch nav.section {
                    case .home:       HomeView()
                    case .langflip:   LangFlipView()
                    case .hotkeys:    HotkeysView()
                    case .insights:   InsightsView()
                    case .dictionary: DictionaryView()
                    case .snippets:   SnippetsView()
                    case .transforms: TransformsView()
                    case .settings:   EmptyView()
                    }
                }
                .padding(28)
                .frame(maxWidth: 980)
                // Center the capped content in the available width instead of
                // pinning it to the left edge.
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Binding var section: MainSection
    let collapsed: Bool

    var body: some View {
        VStack(spacing: 2) {
            // Logo — its icon aligns on the same vertical axis as the row icons.
            SidebarItem(icon: "waveform", iconColor: FlowTheme.accent, collapsed: collapsed,
                        isSelected: false, showHighlight: false) {
                HStack(spacing: 7) {
                    Text("Sayful")
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundColor(FlowTheme.ink)
                        .lineLimit(1)
                        .fixedSize()
                    Text("Beta")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(FlowTheme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(FlowTheme.accentSoft))
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 20)

            ForEach(MainSection.primary) { navRow($0) }

            // Set the layout-flip tools (Dictionary, LangFlip) apart from the
            // speech-to-text features above with a divider + extra spacing.
            Divider()
                .overlay(FlowTheme.cardStroke)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            ForEach(MainSection.secondary) { navRow($0) }

            Spacer()

            SidebarItem(icon: MainSection.settings.icon, collapsed: collapsed, isSelected: section == .settings,
                        action: { section = .settings }) {
                Text("Settings").font(.system(size: 14))
            }
            SidebarItem(icon: "questionmark.circle", iconColor: FlowTheme.inkSecondary, collapsed: collapsed,
                        isSelected: false, action: {
                if let url = URL(string: "https://github.com/MikeKorotych/lang-flip") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text("Help").font(.system(size: 14)).foregroundColor(FlowTheme.inkSecondary)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 10)
        .background(FlowTheme.paper)
    }

    @ViewBuilder
    private func navRow(_ item: MainSection) -> some View {
        SidebarItem(icon: item.icon, collapsed: collapsed, isSelected: section == item,
                    action: { section = item }) {
            Text(item.title).font(.system(size: 14, weight: section == item ? .semibold : .regular))
        }
    }
}

/// Unified sidebar item used for the logo and every row, so icons share one
/// vertical axis in both expanded and collapsed (icon-only) modes.
private struct SidebarItem<Label: View>: View {
    let icon: String
    var iconColor: Color = FlowTheme.ink
    let collapsed: Bool
    var isSelected: Bool
    var showHighlight: Bool = true
    var action: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label

    @State private var hovering = false

    private var content: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: collapsed ? 17 : 15, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 24)
            if !collapsed {
                label()
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: collapsed ? nil : .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(showHighlight ? (isSelected ? FlowTheme.rowSelected : (hovering ? FlowTheme.rowHover : .clear)) : .clear)
        )
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
    }

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovering = $0 }
        } else {
            content
        }
    }
}

/// Left title-bar accessory: the sidebar collapse/expand toggle, sitting just
/// right of the traffic-light buttons.
private struct TitlebarLeadingControls: View {
    @ObservedObject private var nav = MainNavigation.shared
    var body: some View {
        TopIconButton(icon: "sidebar.left") {
            withAnimation(.easeInOut(duration: 0.22)) { nav.sidebarCollapsed.toggle() }
        }
        .padding(.leading, 6)
    }
}

/// Right title-bar accessory: notifications, theme toggle, profile.
private struct TitlebarTrailingControls: View {
    @ObservedObject private var theme = ThemeManager.shared
    var body: some View {
        HStack(spacing: 2) {
            TopIconButton(icon: "bell") {}
            TopIconButton(icon: theme.isDark ? "sun.max" : "moon") {
                theme.isDark.toggle()
            }
            ProfileButton()
        }
        .padding(.trailing, 8)
    }
}

/// Title-bar profile control — shows the signed-in account (email, plan, weekly
/// quota) in a popover, or a Google sign-in prompt.
private struct ProfileButton: View {
    @ObservedObject private var auth = SupabaseBackendAuth.shared
    @State private var show = false
    @State private var working = false

    var body: some View {
        TopIconButton(icon: auth.currentUser != nil ? "person.crop.circle.fill" : "person.crop.circle") {
            show.toggle()
        }
        .popover(isPresented: $show, arrowEdge: .bottom) {
            content.frame(width: 270).padding(16)
        }
    }

    @ViewBuilder private var content: some View {
        if let user = auth.currentUser {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 32)).foregroundColor(FlowTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.email).font(.system(size: 13, weight: .semibold))
                            .foregroundColor(FlowTheme.ink).lineLimit(1)
                        Text(user.role == .corporate ? "Corporate" : "Free")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(FlowTheme.accent)
                    }
                }
                Divider().overlay(FlowTheme.cardStroke)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("This week").font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
                        Spacer()
                        Text("\(user.quota.used) / \(user.quota.limit) words")
                            .font(.system(size: 12)).foregroundColor(FlowTheme.ink)
                    }
                    ProgressView(value: Double(user.quota.used), total: Double(max(user.quota.limit, 1)))
                        .tint(FlowTheme.accent)
                }
                Divider().overlay(FlowTheme.cardStroke)
                HStack {
                    FlowSmallButton(title: "Manage account") {
                        show = false
                        MainNavigation.shared.section = .settings
                    }
                    Spacer()
                    FlowSmallButton(title: "Sign out") { auth.signOut() }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sayful Cloud").font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundColor(FlowTheme.ink)
                Text("Sign in to use AI without an API key.")
                    .font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowSmallButton(title: working ? "Signing in…" : "Sign in with Google", prominent: true) {
                    working = true
                    Task { @MainActor in
                        defer { working = false }
                        _ = try? await auth.signIn()
                        show = false
                    }
                }
                .disabled(working)
            }
        }
    }
}

/// Round, borderless icon button used in the title-bar accessories
/// (collapse / bell / theme / profile).
private struct TopIconButton: View {
    let icon: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(FlowTheme.inkSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? FlowTheme.rowHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

// MARK: - Settings (migrated from the old Preferences window)

/// Hosts the settings tabs inside the main window so the standalone Preferences
/// window can be retired. The tab views are the existing, working ones from
/// PreferencesView.swift; their grouped-Form styling will be migrated to the
/// Flow aesthetic section by section in follow-up iterations.
private struct SettingsHostView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case ai = "AI"
        case voice = "Voice"
        case apps = "Apps"
        case about = "About"

        var id: Self { self }
    }

    @State private var tab: Tab = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                DisplayText("Settings", size: 26)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            // Cap + center the header column so it tracks the tab content
            // (which is capped at 820) instead of stretching the segmented
            // tab bar across the full width on wide windows.
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 14)

            Divider().overlay(FlowTheme.cardStroke)

            Group {
                switch tab {
                case .general:   GeneralTab()
                case .ai:        ModelsTab()
                case .voice:     VoiceTab()
                case .apps:      AppsTab()
                case .about:     AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowTheme.paper)
    }
}
