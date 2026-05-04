import Foundation
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController?
    private var tap: EventTap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask for Accessibility on first launch — the only way the event tap works.
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            FileHandle.standardError.write(Data(
                "lang-flip: waiting for Accessibility permission. Approve in System Settings → Privacy & Security → Accessibility, then relaunch.\n".utf8
            ))
        }

        menubar = MenubarController()

        let tap = EventTap()
        do {
            try tap.start()
            self.tap = tap
        } catch {
            FileHandle.standardError.write(Data("lang-flip: \(error.localizedDescription)\n".utf8))
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: status bar app, no Dock icon, no main menu.
app.setActivationPolicy(.accessory)
app.run()
