import Foundation
import AppKit
import IOKit.hid

private func log(_ s: String) {
    FileHandle.standardError.write(Data("lang-flip: \(s)\n".utf8))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController?
    private var tap: EventTap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("startup, pid=\(getpid())")

        // 1. Accessibility (required for swallowing events / posting synthesized ones).
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        log("Accessibility permission: \(trusted ? "GRANTED" : "MISSING")")

        // 2. Input Monitoring (required for reading keystrokes from other apps on 10.15+).
        let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let inputMonitoringStr: String
        switch inputMonitoring {
        case kIOHIDAccessTypeGranted: inputMonitoringStr = "GRANTED"
        case kIOHIDAccessTypeDenied: inputMonitoringStr = "DENIED"
        case kIOHIDAccessTypeUnknown: inputMonitoringStr = "NOT REQUESTED YET"
        default: inputMonitoringStr = "UNKNOWN(\(inputMonitoring.rawValue))"
        }
        log("Input Monitoring permission: \(inputMonitoringStr)")
        if inputMonitoring != kIOHIDAccessTypeGranted {
            // Triggers the system prompt + adds us to the list.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            log("Requested Input Monitoring access. If denied, add lang-flip in System Settings → Privacy & Security → Input Monitoring and relaunch.")
        }

        if !trusted || inputMonitoring != kIOHIDAccessTypeGranted {
            log("Permissions incomplete — event tap will not see keystrokes. App will keep running so the menubar appears, but hotkey/auto-flip will be inert until you grant both and relaunch.")
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: status bar app, no Dock icon, no main menu.
app.setActivationPolicy(.accessory)
app.run()
