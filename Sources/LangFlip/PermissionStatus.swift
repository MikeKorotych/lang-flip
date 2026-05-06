import Foundation
import AppKit
import IOKit.hid
import ApplicationServices

/// Snapshot of the two macOS privacy approvals our event tap relies on.
/// Re-read on demand — both APIs are cheap and reflect the current state.
struct PermissionStatus: Equatable {
    let accessibility: Bool
    let inputMonitoring: Bool

    var allGranted: Bool { accessibility && inputMonitoring }

    /// Read the current permission state. `prompt = true` shows the
    /// Accessibility consent dialog the first time it's queried.
    static func current(prompt: Bool = false) -> PermissionStatus {
        let opts: CFDictionary = prompt
            ? [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            : [:] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        return PermissionStatus(accessibility: ax, inputMonitoring: im)
    }

    /// Open the right pane of System Settings → Privacy & Security → …
    /// Both URLs are stable across recent macOS releases.
    static func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openInputMonitoringPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Best-effort programmatic prompt for Input Monitoring. macOS only
    /// surfaces the system dialog here on the first call per binary;
    /// subsequent calls are a no-op so we always pair it with a deep-link
    /// to the settings pane.
    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
