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
    /// Drives the "Manage account" modal (opened from the profile popover).
    @Published var showAccount = false
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
        .sheet(isPresented: $nav.showAccount) { AccountSheet() }
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
            UpdateButton()
            NotificationsButton()
            TopIconButton(icon: theme.isDark ? "sun.max" : "moon") {
                theme.isDark.toggle()
            }
            ProfileButton()
        }
        // Leading inset so the update button's filled background isn't clipped by
        // the title-bar accessory's left edge.
        .padding(.leading, 8)
        .padding(.trailing, 8)
    }
}

/// Title-bar update button — appears only when Sparkle has found a newer version,
/// in the accent colour so it stands out next to the muted icons. Clicking it
/// opens Sparkle's install flow (release notes → download → relaunch).
private struct UpdateButton: View {
    @ObservedObject private var updater = Updater.shared
    @State private var hovering = false

    var body: some View {
        if let version = updater.availableVersion {
            Button { updater.checkForUpdates() } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(FlowTheme.accent.opacity(hovering ? 1 : 0.88))
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .help("Update to \(version)")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}

/// Title-bar bell — opens the in-app notification center, with an unread badge.
private struct NotificationsButton: View {
    @ObservedObject private var center = AppNotifications.shared
    @State private var show = false

    var body: some View {
        TopIconButton(icon: center.unreadCount > 0 ? "bell.badge" : "bell") {
            show.toggle()
            if show { center.markAllRead() }
        }
        .overlay(alignment: .topTrailing) {
            if center.unreadCount > 0 {
                Text("\(min(center.unreadCount, 9))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Circle().fill(Color.red))
                    .offset(x: 2, y: -2)
            }
        }
        .popover(isPresented: $show, arrowEdge: .bottom) {
            popover.frame(width: 300).padding(14)
        }
    }

    @ViewBuilder private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notifications")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundColor(FlowTheme.ink)
                Spacer()
                if !center.items.isEmpty {
                    Button("Clear") { center.clear() }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .font(.system(size: 12))
                        .foregroundColor(FlowTheme.inkSecondary)
                }
            }

            if center.items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash").foregroundColor(FlowTheme.inkSecondary)
                    Text("You're all caught up.")
                        .font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(center.items) { note in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: note.icon)
                                .font(.system(size: 14))
                                .foregroundColor(note.kind == .warning ? .orange : FlowTheme.accent)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(FlowTheme.ink)
                                Text(note.body)
                                    .font(.system(size: 12))
                                    .foregroundColor(FlowTheme.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
}

/// Title-bar profile control — shows the signed-in account (email, plan, weekly
/// quota) in a popover, or a Google sign-in prompt.
private struct ProfileButton: View {
    @ObservedObject private var auth = SupabaseBackendAuth.shared
    @State private var show = false
    @State private var working = false

    var body: some View {
        // Icon reflects the token (isSignedIn), not just the loaded profile, so
        // it's correct from launch even before /me resolves.
        TopIconButton(icon: auth.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle") {
            show.toggle()
        }
        .popover(isPresented: $show, arrowEdge: .bottom) {
            content
                .frame(width: 270)
                .padding(16)
                .task { if auth.isSignedIn && auth.currentUser == nil { _ = try? await auth.refreshUser() } }
        }
    }

    @ViewBuilder private var content: some View {
        if let user = auth.currentUser {
            signedIn(user)
        } else if auth.isSignedIn {
            VStack(spacing: 10) {
                Text("Signed in").font(.system(size: 13, weight: .semibold)).foregroundColor(FlowTheme.ink)
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        } else {
            signedOut
        }
    }

    private func signedIn(_ user: BackendUser) -> some View {
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
                    MainNavigation.shared.showAccount = true
                }
                Spacer()
                FlowSmallButton(title: "Sign out") { auth.signOut() }
            }
        }
    }

    private var signedOut: some View {
        VStack(spacing: 10) {
            Text("Sayful Cloud").font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundColor(FlowTheme.ink)
            Text("Sign in to use AI without an API key.")
                .font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
                .multilineTextAlignment(.center)
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
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
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
        case voice = "Voice"
        case about = "About"
        case developer = "Developer"

        var id: Self { self }
    }

    @State private var tab: Tab = .general
    // The Developer tab holds engineering-only knobs (self-host / local models,
    // STT model override). End users never see it — it's revealed by the
    // "Self-host / local AI" toggle in General, so everything else in Settings
    // is exactly the end-user view.
    @AppStorage("lf.showAdvancedAI") private var showAdvancedAI = false

    private var visibleTabs: [Tab] {
        showAdvancedAI ? Tab.allCases : Tab.allCases.filter { $0 != .developer }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                DisplayText("Settings", size: 26)
                FlowSegmented(items: visibleTabs.map { (value: $0, label: $0.rawValue) },
                              selection: $tab)
                    // Centre the tab row in the available width instead of pinning
                    // it to the left edge.
                    .frame(maxWidth: .infinity, alignment: .center)
                    .onChange(of: showAdvancedAI) { advanced in
                        // If Advanced is turned off while the Developer tab is open,
                        // fall back to General so we don't show a tab that's gone.
                        if !advanced, tab == .developer { tab = .general }
                    }
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
                case .voice:     VoiceTab()
                case .about:     AboutTab()
                case .developer: ModelsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowTheme.paper)
    }
}
