import Foundation
import AppKit
import SwiftUI

private func log(_ s: String) {
    FileHandle.standardError.write(Data("lang-flip: \(s)\n".utf8))
}

@main
struct LangFlipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings is the only Scene we declare — the actual UI lives in
        // hand-rolled NSWindow controllers (Onboarding, Preferences) so
        // we have full control over activation policy. The Settings scene
        // here is intentionally empty: macOS hooks Cmd+, to it for free,
        // but we never present its window — the menubar's Preferences…
        // item opens our own PreferencesWindowController instead.
        SwiftUI.Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController?
    private var tap: EventTap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status-bar accessory: no Dock icon, no main menu.
        // OnboardingWindowController and PreferencesWindowController flip
        // this to .regular while their window is on screen, then back to
        // .accessory when it closes.
        NSApp.setActivationPolicy(.accessory)

        log("startup, pid=\(getpid())")

        let perms = PermissionStatus.current(prompt: true)
        log("Accessibility permission: \(perms.accessibility ? "GRANTED" : "MISSING")")
        log("Input Monitoring permission: \(perms.inputMonitoring ? "GRANTED" : "MISSING / NOT YET REQUESTED")")
        if !perms.inputMonitoring {
            PermissionStatus.requestInputMonitoring()
        }

        if !Settings.shared.onboardingDone || !perms.allGranted {
            log("showing onboarding window")
            OnboardingWindowController.shared.show()
        }

        menubar = MenubarController()
        log("menubar ready (look for ⌥ icon in menu bar)")

        let tap = EventTap()
        do {
            try tap.start()
            self.tap = tap
            log("event tap started successfully")
        } catch {
            log("event tap FAILED: \(error.localizedDescription)")
        }
    }
}
