import AppKit

final class MenubarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let autoFlipItem = NSMenuItem(title: "Auto-flip on word boundary", action: #selector(toggleAutoFlip), keyEquivalent: "")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.title = "⌥"
            button.toolTip = "lang-flip — keyboard layout converter"
        }

        enabledItem.target = self
        autoFlipItem.target = self
        refreshChecks()

        menu.addItem(enabledItem)
        menu.addItem(autoFlipItem)
        menu.addItem(.separator())

        let hotkeyHint = NSMenuItem(title: "Hotkey: double-tap ⇧ — selection if any, else last word", action: nil, keyEquivalent: "")
        hotkeyHint.isEnabled = false
        menu.addItem(hotkeyHint)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit lang-flip", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func refreshChecks() {
        enabledItem.state = Settings.shared.enabled ? .on : .off
        autoFlipItem.state = Settings.shared.autoFlip ? .on : .off
        if let button = statusItem.button {
            button.title = Settings.shared.enabled ? "⌥" : "⌥̶"
        }
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        refreshChecks()
    }

    @objc private func toggleAutoFlip() {
        Settings.shared.autoFlip.toggle()
        refreshChecks()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
