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
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.tabby",
    ]

    private static let builtinBlocklist: Set<String> = terminalBundleIDs.union([
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
    ])

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

    static func isTerminalBundleID(_ bundleID: String) -> Bool {
        return terminalBundleIDs.contains(bundleID)
    }

    static func frontmostAppIsTerminal() -> Bool {
        guard let bundleID = frontmostBundleID() else { return false }
        return isTerminalBundleID(bundleID)
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
        guard let axWindow = frontmostAXWindow() else { return nil }

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

    /// Fullscreen state from the focused AX window itself. This catches real
    /// macOS fullscreen windows whose AX frame does not exactly equal the
    /// physical screen frame during/after Space transitions.
    static func frontmostWindowIsFullscreen() -> Bool? {
        guard let axWindow = frontmostAXWindow() else { return nil }

        if let focusedFullscreen = axFullscreenValue(axWindow) {
            return focusedFullscreen
        }

        let windows = frontmostAXWindows()
        var sawFullscreenAttribute = false
        for window in windows {
            guard let fullscreen = axFullscreenValue(window) else { continue }
            sawFullscreenAttribute = true
            if fullscreen { return true }
        }

        return sawFullscreenAttribute ? false : nil
    }

    /// Frame of a fullscreen window owned by the focused app. Some apps focus a
    /// child/composer window while their main window owns fullscreen state, so
    /// callers that place overlays should prefer this over AXFocusedWindow.
    static func frontmostFullscreenWindowFrame() -> CGRect? {
        for window in frontmostAXWindows() where axFullscreenValue(window) == true {
            if let frame = frame(of: window) {
                return frame
            }
        }
        return nil
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
        if let axFullscreen = frontmostWindowIsFullscreen() {
            return axFullscreen
        }
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

    private static func frontmostAXWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef
        else { return nil }
        return (window as! AXUIElement)
    }

    private static func frontmostAXWindows() -> [AXUIElement] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return [] }

        return windows
    }

    private static func axFullscreenValue(_ window: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &valueRef) == .success,
              let valueRef
        else { return nil }

        return valueRef as? Bool
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
        let sizeErr = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard posErr == .success, sizeErr == .success,
              let posVal = positionRef, let sizeVal = sizeRef
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
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
    ///
    /// Result is cached and invalidated on NSWorkspace activation /
    /// active-space-change notifications, plus a 500 ms safety timer in
    /// case the notifications get dropped. Inside a typing burst (which
    /// keeps focus on one app) this means every keystroke after the
    /// first lookup is a free hash-lookup of the cached value instead
    /// of a fresh NSWorkspace.frontmostApplication IPC call.
    static func suppressionCause() -> SuppressionCause? {
        installCacheObserversIfNeeded()
        cacheLock.lock()
        if let cached = cachedCause {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Compute outside the lock so other threads aren't blocked on
        // an AX / NSWorkspace round-trip.
        let cause = computeSuppressionCause()

        cacheLock.lock()
        cachedCause = .some(cause)
        cacheLock.unlock()
        return cause
    }

    /// True when auto-flip should stay silent for the focused context.
    static func shouldSuppressAutoFlip() -> Bool {
        return suppressionCause() != nil
    }

    // MARK: - Cache plumbing

    /// Double-optional: nil = not cached yet, .some(nil) = cached "no
    /// cause", .some(.some(...)) = cached cause.
    private static var cachedCause: SuppressionCause?? = nil
    private static let cacheLock = NSLock()
    private static var observersInstalled = false
    private static var safetyTimer: DispatchSourceTimer?

    private static func installCacheObserversIfNeeded() {
        cacheLock.lock()
        guard !observersInstalled else { cacheLock.unlock(); return }
        observersInstalled = true
        cacheLock.unlock()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: nil) { _ in invalidateSuppressionCache() }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                       object: nil, queue: nil) { _ in invalidateSuppressionCache() }

        // Safety net: AppKit notifications can be dropped under load,
        // and we don't want a stale cache to keep the app silent in a
        // password manager that just lost focus. 500 ms is short enough
        // that a single missed notification can't cause a real bug.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { invalidateSuppressionCache() }
        timer.resume()
        safetyTimer = timer
    }

    private static func invalidateSuppressionCache() {
        cacheLock.lock()
        cachedCause = nil
        cacheLock.unlock()
    }

    private static func computeSuppressionCause() -> SuppressionCause? {
        if let bundleID = frontmostBundleID() {
            switch blockReason(for: bundleID) {
            case .builtin:     return .builtinApp(bundleID)
            case .userBlocked: return .userApp(bundleID)
            case .none:        break
            }
        }
        if Settings.shared.suppressInFullscreen, isFrontmostFullscreen() {
            return .fullscreen
        }
        return nil
    }
}
