import AppKit
import ApplicationServices

/// Reads the focused application and decides whether auto-flip should stay
/// silent there. The manual double-/triple-Shift hotkey is *not* gated by
/// this — pressing it is an explicit user intent that should work everywhere.
enum AppContext {

    /// Bundle IDs where automatic flipping is silenced by default.
    ///
    /// Conservative list — only apps where auto-flip would do real harm:
    ///   - Terminals: synthesized events are flaky in PTYs, and Cmd+Backspace
    ///     in shells does line-kill, not char-delete. Auto-flip can corrupt
    ///     shell history.
    ///   - Password managers: never touch credential fields.
    ///
    /// Code editors / IDEs are intentionally NOT here. Modern workflows mix
    /// natural-language input (AI-extension chats, commit messages, comments,
    /// markdown, docs) with code, and a blanket block makes the app useless
    /// to anyone living in their editor. Users who want them silenced can
    /// add them via the "Disable auto-flip in [App]" menu item.
    private static let builtinBlocklist: Set<String> = [
        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.tabby",

        // Password managers (defence-in-depth — substring rules below also catch them)
        "com.1password.1password",
        "com.1password.1password7",
        "com.1password.1password8",
        "com.agilebits.onepassword4-helper",
        "com.agilebits.onepassword7",
        "com.lastpass.LastPass",
        "com.lastpass.LastPassMacDesktop",
        "com.dashlane.Dashlane",
        "com.bitwarden.desktop",
        "io.keepassxc.KeePassXC",
    ]

    /// Substrings that, when contained anywhere in the lowercased bundle ID,
    /// are an unambiguous signal to stay quiet (catches plugin-style IDs
    /// like `com.something.password.helper`).
    private static let blocklistedSubstrings: [String] = [
        "password",
        "keychain",
        "1password",
        "lastpass",
        "bitwarden",
        "keepass",
        "vault",
        "secret",
    ]

    /// Bundle ID of the user's currently focused application, or nil if
    /// nothing has key focus. The status-item menu does *not* take key
    /// focus, so this stays correct even while our menu is open.
    static func frontmostBundleID() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Localised name of the focused application, for display in our menu.
    static func frontmostAppName() -> String? {
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// Frame of the focused window of the focused app, in screen coordinates,
    /// via the Accessibility API. Returns nil if AX lookup fails — usually
    /// because the app hasn't granted us Accessibility (which would also
    /// make the rest of the app inert) or the focused app exposes no
    /// AXFocusedWindow.
    static func frontmostWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef
        else { return nil }
        let axWindow = window as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
        let sizeErr = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        guard posErr == .success, sizeErr == .success,
              let posVal = positionRef, let sizeVal = sizeRef
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    /// True if the focused window's dimensions match any connected screen's
    /// — strong signal of a true fullscreen mode (game, video player, IDE
    /// in fullscreen). We compare *sizes* rather than full rects because
    /// AX uses top-left origin and NSScreen uses bottom-left, and matching
    /// sizes alone is enough for the fullscreen signal.
    ///
    /// Excludes "maximized but not fullscreen" windows (where the menu bar
    /// is still visible) — those have a slightly smaller height.
    static func isFrontmostFullscreen() -> Bool {
        guard let frame = frontmostWindowFrame() else { return false }
        let tolerance: CGFloat = 1
        for screen in NSScreen.screens {
            let s = screen.frame.size
            if abs(s.width - frame.size.width) < tolerance && abs(s.height - frame.size.height) < tolerance {
                return true
            }
        }
        return false
    }

    /// Why a bundle ID is on the blocklist (if it is). nil means the app is
    /// allowed.
    enum BlockReason {
        case builtin       // hard-coded
        case userBlocked   // toggled off by the user
    }

    static func blockReason(for bundleID: String) -> BlockReason? {
        if builtinBlocklist.contains(bundleID) { return .builtin }
        let lower = bundleID.lowercased()
        for needle in blocklistedSubstrings where lower.contains(needle) {
            return .builtin
        }
        if Settings.shared.userBlacklist.contains(bundleID) { return .userBlocked }
        return nil
    }

    /// Detailed suppression cause — useful for debug logging.
    enum SuppressionCause {
        case builtinApp(String)   // bundle ID
        case userApp(String)      // bundle ID
        case fullscreen           // window covers the whole screen
    }

    /// Returns the reason auto-flip should be suppressed for the focused
    /// context, or nil if it should fire normally.
    static func suppressionCause() -> SuppressionCause? {
        if let bundleID = frontmostBundleID() {
            switch blockReason(for: bundleID) {
            case .builtin:    return .builtinApp(bundleID)
            case .userBlocked: return .userApp(bundleID)
            case .none:        break
            }
        }
        if isFrontmostFullscreen() { return .fullscreen }
        return nil
    }

    /// True when auto-flip should stay silent for the focused context.
    static func shouldSuppressAutoFlip() -> Bool {
        return suppressionCause() != nil
    }
}
