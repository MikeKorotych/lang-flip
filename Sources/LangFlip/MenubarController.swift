import AppKit

/// Minimal status-bar menu, in the spirit of the reference design: open the
/// app, re-paste the last dictation, jump to settings, switch language, get
/// help, quit. All the per-action commands (flip / fix / translate / read /
/// capture) are driven by their global hotkeys and surfaced in the main
/// window's "Superpowers" list — they don't clutter the menu. Quick toggles
/// (enabled / auto-flip / single-Shift fix) live in Settings › General.
final class MenubarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let openItem = NSMenuItem(title: "Open Sayful", action: #selector(openMain), keyEquivalent: "")
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let pasteLastItem = NSMenuItem(title: "Paste last transcript", action: #selector(pasteLastTranscript), keyEquivalent: "v")
    private let pastePreviewItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    private let languagesItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
    private let helpItem = NSMenuItem(title: "Help", action: #selector(openHelp), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Sayful", action: #selector(quit), keyEquivalent: "q")

    /// Cached, resized copy of AppIcon for the menu bar. macOS renders
    /// menu-bar items at ~18pt; pre-resizing here keeps the layout stable.
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
                button.title = "⌥"
            }
            button.toolTip = "Sayful"
        }

        for item in [openItem, updatesItem, pasteLastItem, settingsItem, helpItem, quitItem] {
            item.target = self
        }
        pasteLastItem.keyEquivalentModifierMask = [.control, .command]
        pastePreviewItem.isEnabled = false

        let langSub = NSMenu()
        for layout in [Layout.en, .uk, .ru] {
            let item = NSMenuItem(title: layout.displayName, action: #selector(setPrimaryLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.rawValue
            langSub.addItem(item)
        }
        languagesItem.submenu = langSub

        menu.addItem(openItem)
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        menu.addItem(pasteLastItem)
        menu.addItem(pastePreviewItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(languagesItem)
        menu.addItem(.separator())
        menu.addItem(helpItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: .langFlipEnabledChanged,
            object: nil
        )

        refresh()
    }

    @objc private func refresh() {
        // "Paste last transcript" reflects the most recent dictation, with a
        // dimmed preview line beneath it (like the reference menu).
        let last = DictationHistory.shared.entries.first
        pasteLastItem.isEnabled = (last != nil)
        if let last {
            pastePreviewItem.isHidden = false
            let snippet = last.text.replacingOccurrences(of: "\n", with: " ")
            pastePreviewItem.title = snippet.count > 44 ? String(snippet.prefix(44)) + "…" : snippet
        } else {
            pastePreviewItem.isHidden = true
        }

        if let sub = languagesItem.submenu {
            let current = Settings.shared.primaryLanguage.rawValue
            for item in sub.items {
                if let raw = item.representedObject as? String {
                    item.state = (raw == current) ? .on : .off
                }
            }
        }

        if let button = statusItem.button {
            if Self.menubarIcon != nil {
                button.alphaValue = Settings.shared.enabled ? 1.0 : 0.4
            } else {
                button.title = Settings.shared.enabled ? "⌥" : "⌥̶"
            }
        }
    }

    @objc private func openMain() {
        MainWindowController.shared.show(section: .home)
    }

    @objc private func openSettings() {
        MainWindowController.shared.show(section: .settings)
    }

    @objc private func pasteLastTranscript() {
        guard let last = DictationHistory.shared.entries.first else { return }
        VoiceDictationController.shared.pasteText(last.text)
    }

    @objc private func setPrimaryLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = Layout(rawValue: raw) else { return }
        Settings.shared.primaryLanguage = layout
        refresh()
    }

    @objc private func openHelp() {
        if let url = URL(string: "https://github.com/MikeKorotych/lang-flip") {
            NSWorkspace.shared.open(url)
        }
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
        refresh()
    }
}
