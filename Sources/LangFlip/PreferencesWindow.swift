import AppKit
import SwiftUI

/// Hand-rolled NSWindow + NSHostingController combo, mirroring
/// OnboardingWindowController. We intentionally don't use SwiftUI's
/// `Settings` scene because for menubar-only apps (LSUIElement=YES) it
/// requires private selectors to open programmatically, and we want full
/// control over activation policy anyway.
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: PreferencesView())
            let win = NSWindow(contentViewController: host)
            win.title = "Preferences"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.setContentSize(NSSize(width: 600, height: 460))
            win.isReleasedWhenClosed = false
            win.center()
            // Restore .accessory when the window is dismissed.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: win
            )
            window = win
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func handleWindowWillClose(_ note: Notification) {
        // Only drop back to accessory if our other windows aren't open.
        let onboardingVisible = NSApp.windows.contains {
            $0.isVisible && $0.title == "LangFlip" && $0 !== window
        }
        if !onboardingVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
