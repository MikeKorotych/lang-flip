import AppKit

final class MenubarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let autoFlipItem = NSMenuItem(title: "Auto-flip on word boundary", action: #selector(toggleAutoFlip), keyEquivalent: "")

    private let primaryMenu = NSMenu()
    private let secondaryMenu = NSMenu()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.title = "⌥"
            button.toolTip = "lang-flip — keyboard layout converter"
        }

        enabledItem.target = self
        autoFlipItem.target = self

        menu.addItem(enabledItem)
        menu.addItem(autoFlipItem)
        menu.addItem(.separator())

        // Primary language submenu (double-tap Shift target).
        let primaryItem = NSMenuItem(title: "Primary language (⇧⇧)", action: nil, keyEquivalent: "")
        primaryItem.submenu = primaryMenu
        for layout in Layout.nonEnglish {
            let item = NSMenuItem(title: layout.displayName, action: #selector(setPrimary(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.rawValue
            primaryMenu.addItem(item)
        }
        menu.addItem(primaryItem)

        // Secondary language submenu (triple-tap Shift target).
        let secondaryItem = NSMenuItem(title: "Secondary language (⇧⇧⇧)", action: nil, keyEquivalent: "")
        secondaryItem.submenu = secondaryMenu
        let noneItem = NSMenuItem(title: "None", action: #selector(setSecondary(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = "" // empty = nil
        secondaryMenu.addItem(noneItem)
        secondaryMenu.addItem(.separator())
        for layout in Layout.nonEnglish {
            let item = NSMenuItem(title: layout.displayName, action: #selector(setSecondary(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.rawValue
            secondaryMenu.addItem(item)
        }
        menu.addItem(secondaryItem)

        menu.addItem(.separator())

        let hotkeyHint = NSMenuItem(title: "Hotkey: ⇧⇧ → primary, ⇧⇧⇧ → secondary (selection if any, else last word)", action: nil, keyEquivalent: "")
        hotkeyHint.isEnabled = false
        menu.addItem(hotkeyHint)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit lang-flip", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refresh()
    }

    private func refresh() {
        enabledItem.state = Settings.shared.enabled ? .on : .off
        autoFlipItem.state = Settings.shared.autoFlip ? .on : .off
        if let button = statusItem.button {
            button.title = Settings.shared.enabled ? "⌥" : "⌥̶"
        }

        let primary = Settings.shared.primaryLanguage
        for item in primaryMenu.items {
            guard let raw = item.representedObject as? String else { continue }
            item.state = (raw == primary.rawValue) ? .on : .off
        }

        let secondary = Settings.shared.secondaryLanguage
        for item in secondaryMenu.items {
            guard let raw = item.representedObject as? String else { continue }
            if raw.isEmpty {
                item.state = (secondary == nil) ? .on : .off
            } else {
                item.state = (raw == secondary?.rawValue) ? .on : .off
            }
            // Don't let the user pick the primary as the secondary.
            item.isEnabled = (raw != primary.rawValue)
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

    @objc private func setPrimary(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = Layout(rawValue: raw)
        else { return }
        Settings.shared.primaryLanguage = layout
        refresh()
    }

    @objc private func setSecondary(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if raw.isEmpty {
            Settings.shared.secondaryLanguage = nil
        } else if let layout = Layout(rawValue: raw) {
            Settings.shared.secondaryLanguage = layout
        }
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
