import Foundation
import AppKit
import AVFoundation
import IOKit.hid
import ApplicationServices
import CoreGraphics

/// Snapshot of the two macOS privacy approvals our event tap relies on.
/// Re-read on demand — both APIs are cheap and reflect the current state.
struct PermissionStatus: Equatable {
    let accessibility: Bool
    let inputMonitoring: Bool
    let microphone: Bool

    /// The two approvals the keyboard event tap relies on (flip + hotkeys).
    /// Surfaced in the LangFlip tab's Permissions section; deliberately excludes
    /// the microphone, which is handled on its own (onboarding + Voice tab).
    var allGranted: Bool { accessibility && inputMonitoring }

    /// Read the current permission state. `prompt = true` shows the
    /// Accessibility consent dialog the first time it's queried.
    ///
    /// Passing an empty CFDictionary to AXIsProcessTrustedWithOptions
    /// crashes inside CFGetTypeID on macOS 26 (EXC_BAD_ACCESS at
    /// offset 0x8) — we hit this on every silent permission probe
    /// after the onboarding refactor went prompt-free. Pass nil
    /// explicitly when there's no option to set; that's the supported
    /// shape per Apple's docs.
    static func current(prompt: Bool = false) -> PermissionStatus {
        let ax: Bool
        if prompt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            ax = AXIsProcessTrustedWithOptions(opts)
        } else {
            ax = AXIsProcessTrustedWithOptions(nil)
        }
        let im = CGPreflightListenEventAccess()
            && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            && canCreateKeyboardEventTap()
        return PermissionStatus(accessibility: ax, inputMonitoring: im, microphone: hasMicrophone())
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

    static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func hasMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void = { _ in }) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    static func openMicrophonePane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openSoundInputPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound?input") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openScreenRecordingPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Best-effort programmatic prompt for Input Monitoring. macOS only
    /// surfaces the system dialog here on the first call per binary;
    /// subsequent calls are a no-op so we always pair it with a deep-link
    /// to the settings pane.
    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    /// The system privacy APIs can report optimistic state immediately
    /// after a request call. The app is only useful once a keyboard event
    /// tap can actually be created, so onboarding uses this as the final
    /// practical check before unlocking Continue.
    private static func canCreateKeyboardEventTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, _ in
                Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            return false
        }
        CFMachPortInvalidate(tap)
        return true
    }
}
