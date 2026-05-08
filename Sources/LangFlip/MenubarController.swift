import AppKit

/// Slim status-bar menu — only the most-frequent toggles plus a one-click
/// entry to the full Preferences window. Anything that's a one-time
/// configuration choice (language pickers, exception lists, per-app
/// blacklist) lives in PreferencesView.
final class MenubarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    /// Weak ref so the menubar can dispatch selection-mode AI features
    /// (Sprint G translate-selection) into the running event tap. Held
    /// weakly because EventTap's lifetime is owned by AppDelegate.
    private weak var eventTap: EventTap?

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let autoFlipItem = NSMenuItem(title: "Auto-flip on word boundary", action: #selector(toggleAutoFlip), keyEquivalent: "")
    private let translateMenuItem = NSMenuItem(title: "Translate selection", action: nil, keyEquivalent: "")
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

    init(eventTap: EventTap? = nil) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.eventTap = eventTap
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

        // Translate-selection submenu — built once, shown/hidden in
        // refresh() based on whether AI is active.
        let translateSub = NSMenu()
        for layout in [Layout.en, .uk, .ru] {
            let item = NSMenuItem(
                title: "To \(layout.displayName)",
                action: #selector(translateSelectionMenuFired(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = layout.rawValue
            translateSub.addItem(item)
        }
        translateMenuItem.submenu = translateSub
        menu.addItem(.separator())
        menu.addItem(translateMenuItem)

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
        // Hide the Translate submenu entirely when AI is off — it
        // wouldn't do anything useful and risks confusing users who
        // haven't opted into AI yet.
        translateMenuItem.isHidden = (Settings.shared.aiMode == .off)
        // Bullet the configured default target so users know which
        // entry the ⌃⌥T hotkey maps to.
        if let sub = translateMenuItem.submenu {
            let defaultTarget = Settings.shared.translationTarget
            for item in sub.items {
                if let raw = item.representedObject as? String,
                   let layout = Layout(rawValue: raw) {
                    item.state = (layout == defaultTarget) ? .on : .off
                }
            }
        }
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

    @objc private func translateSelectionMenuFired(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let target = Layout(rawValue: raw) else { return }
        // Status menu actions fire on the main thread after the menu
        // closes — focus has already returned to the previously-active
        // app, so a Cmd+C round-trip from inside translateSelectionWithAI
        // lands in the right window.
        eventTap?.translateSelectionWithAI(target: target)
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
