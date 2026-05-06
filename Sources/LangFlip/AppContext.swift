import AppKit

/// Reads the focused application and decides whether auto-flip should stay
/// silent there. The manual double-/triple-Shift hotkey is *not* gated by
/// this — pressing it is an explicit user intent that should work everywhere.
enum AppContext {

    /// Bundle IDs where automatic flipping is more likely to break things
    /// (terminals where synthesized events are flaky, IDEs where we'd
    /// rewrite source code, password fields where we'd corrupt secrets).
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

        // IDEs and code editors
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "org.vim.MacVim",
        "com.github.atom",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",

        // JetBrains family
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.RubyMine",
        "com.jetbrains.GoLand",
        "com.jetbrains.rider",
        "com.jetbrains.AppCode",
        "com.jetbrains.CLion",
        "com.jetbrains.datagrip",
        "com.jetbrains.AndroidStudio",
        "com.google.android.studio",

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

    /// True when auto-flip should stay silent for the focused app.
    static func shouldSuppressAutoFlip() -> Bool {
        guard let bundleID = frontmostBundleID() else { return false }
        return blockReason(for: bundleID) != nil
    }
}
