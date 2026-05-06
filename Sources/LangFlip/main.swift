import Foundation
import AppKit

private func log(_ s: String) {
    FileHandle.standardError.write(Data("lang-flip: \(s)\n".utf8))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController?
    private var tap: EventTap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("startup, pid=\(getpid())")

        // Read both permissions; the helper handles the prompt-on-first-run
        // for Accessibility. Input Monitoring is queried separately and we
        // also explicitly request it so first-run users get the system
        // dialog instead of an apparent silent failure.
        let perms = PermissionStatus.current(prompt: true)
        log("Accessibility permission: \(perms.accessibility ? "GRANTED" : "MISSING")")
        log("Input Monitoring permission: \(perms.inputMonitoring ? "GRANTED" : "MISSING / NOT YET REQUESTED")")
        if !perms.inputMonitoring {
            PermissionStatus.requestInputMonitoring()
        }

        // Show the welcome / permissions wizard on first launch, OR any
        // launch where a previously-granted permission has been revoked.
        if !Settings.shared.onboardingDone || !perms.allGranted {
            log("showing onboarding window")
            OnboardingWindowController.shared.show()
        }

        // Menubar always comes up — even when permissions are incomplete,
        // so users have a visible affordance to find the app.
        menubar = MenubarController()
        log("menubar ready (look for ⌥ icon in menu bar)")

        // Event tap is best-effort. CGEvent.tapCreate returns nil without
        // Accessibility; we throw and log rather than crash, so the
        // onboarding window stays up.
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: status-bar app, no Dock icon, no main menu. The onboarding
// window flips this to .regular while it's visible.
app.setActivationPolicy(.accessory)
app.run()
