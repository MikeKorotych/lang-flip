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
    private let quitItem = NSMenuItem(title: "Quit lang-flip", action: #selector(quit), keyEquivalent: "q")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.title = "⌥"
            button.toolTip = "lang-flip — keyboard layout converter"
        }

        enabledItem.target = self
        autoFlipItem.target = self
        prefsItem.target = self
        quitItem.target = self

        menu.addItem(enabledItem)
        menu.addItem(autoFlipItem)
        menu.addItem(.separator())
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.delegate = self

        // Refresh on the both-Shifts toggle so the icon ⌥ ↔ ⌥̶ stays in sync.
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
            button.title = Settings.shared.enabled ? "⌥" : "⌥̶"
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
