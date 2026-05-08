import AppKit

/// Slim status-bar menu — only the most-frequent toggles plus a one-click
/// entry to the full Preferences window. Anything that's a one-time
/// configuration choice (language pickers, exception lists, per-app
/// blacklist) lives in PreferencesView.
final class MenubarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let autoFlipItem = NSMenuItem(title: "Auto-flip on word boundary", action: #selector(toggleAutoFlip), keyEquivalent: "")
    private let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit LangFlip", action: #selector(quit), keyEquivalent: "q")

    /// Cached, resized copy of AppIcon for the menu bar. macOS renders
    /// menu-bar items at ~18pt; pre-resizing here keeps the layout
    /// stable and avoids the OS picking a fuzzy intermediate size.
    private static let menubarIcon: NSImage? = {
        guard let icon = NSImage(named: "AppIcon") else { return nil }
        let resized = NSImage(size: NSSize(width: 18, height: 18))
        resized.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18),
                  from: .zero,
                  operation: .sourceOver,
                  fraction: 1.0)
        resized.unlockFocus()
        return resized
    }()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            if let icon = Self.menubarIcon {
                button.image = icon
                button.imagePosition = .imageOnly
            } else {
                // Fallback if AppIcon isn't bundled for some reason.
                button.title = "⌥"
            }
            button.toolTip = "LangFlip — keyboard layout converter"
        }

        enabledItem.target = self
        autoFlipItem.target = self
        prefsItem.target = self
        updatesItem.target = self
        quitItem.target = self

        menu.addItem(enabledItem)
        menu.addItem(autoFlipItem)
        menu.addItem(.separator())
        menu.addItem(prefsItem)
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.delegate = self

        // Refresh on the both-Shifts toggle so the menubar icon's
        // dimmed-when-disabled state stays in sync with Settings.enabled.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalEnabledChange),
            name: .langFlipEnabledChanged,
            object: nil
        )

        refresh()
    }

    @objc private func externalEnabledChange() {
        refresh()
    }

    private func refresh() {
        enabledItem.state = Settings.shared.enabled ? .on : .off
        autoFlipItem.state = Settings.shared.autoFlip ? .on : .off
        if let button = statusItem.button {
            // When the icon is bundled, dim it to communicate "paused";
            // when we're on the text fallback, swap glyph as before.
            if Self.menubarIcon != nil {
                button.alphaValue = Settings.shared.enabled ? 1.0 : 0.4
            } else {
                button.title = Settings.shared.enabled ? "⌥" : "⌥̶"
            }
        }
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        refresh()
    }

    @objc private func toggleAutoFlip() {
        Settings.shared.autoFlip.toggle()
        refresh()
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.show()
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension MenubarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Pull live state in case the both-Shifts gesture or the
        // Preferences window changed something while the menu was closed.
        refresh()
    }
}
