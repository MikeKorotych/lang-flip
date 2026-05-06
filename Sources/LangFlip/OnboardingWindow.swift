import AppKit
import SwiftUI

/// Single welcome / permissions window shown on first launch and any time
/// the app starts without both required permissions. Closed only when the
/// user clicks Continue, which is gated on both permissions being granted —
/// no Skip button by design (without permissions the app is inert).
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    /// Show the window if it isn't already up. Brings the app to the
    /// foreground so the user can see + click it; LSUIElement=YES would
    /// otherwise let the window appear behind whatever's focused.
    func show() {
        if window == nil {
            let view = OnboardingView(onContinue: { [weak self] in
                self?.markDoneAndClose()
            })
            let host = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: host)
            win.title = "lang-flip"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 480, height: 400))
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }

        // Switch from menubar-only mode so the window can take focus, then
        // restore .accessory when it closes (see markDoneAndClose).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func markDoneAndClose() {
        Settings.shared.onboardingDone = true
        window?.close()
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct OnboardingView: View {
    let onContinue: () -> Void

    @State private var status: PermissionStatus = .current()

    /// Polls every 500 ms so the checkmarks turn green the moment the user
    /// flips a switch in System Settings, without them having to come back
    /// to our window.
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            VStack(spacing: 6) {
                Text("Welcome to lang-flip")
                    .font(.system(size: 20, weight: .semibold))
                Text("Fix typing in the wrong keyboard layout — automatically.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    title: "Accessibility",
                    granted: status.accessibility,
                    action: PermissionStatus.openAccessibilityPane
                )
                permissionRow(
                    title: "Input Monitoring",
                    granted: status.inputMonitoring,
                    action: {
                        // Triggers the system prompt the first time, which
                        // in turn lists us in the Settings pane the user
                        // is about to open.
                        PermissionStatus.requestInputMonitoring()
                        PermissionStatus.openInputMonitoringPane()
                    }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().padding(.vertical, 4)

            Text("Once both are granted, look for ⌥ in the menu bar. Double-tap Shift to flip the last word; press both Shifts at once to pause.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onContinue) {
                Text("Continue")
                    .frame(minWidth: 100)
            }
            .keyboardShortcut(.return)
            .controlSize(.large)
            .disabled(!status.allGranted)
        }
        .padding(24)
        .frame(width: 432)
        .onReceive(timer) { _ in
            let next = PermissionStatus.current()
            if next != status { status = next }
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundColor(granted ? .green : .secondary)
            Text(title)
                .font(.body)
            Spacer()
            Button("Open System Settings", action: action)
                .controlSize(.small)
                .disabled(granted)
        }
    }
}
