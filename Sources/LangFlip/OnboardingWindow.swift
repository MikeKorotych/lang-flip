import AppKit
import SwiftUI

/// Welcome / permissions wizard shown on first launch (and on any launch
/// where a previously-granted permission has been revoked). Walks the user
/// through Accessibility and Input Monitoring one at a time so they don't
/// have to figure out the right order or remember to come back to the
/// window after a System Settings detour. Closed by Continue, which is
/// gated on both permissions being granted — no Skip by design (without
/// the permissions the app is inert).
final class OnboardingWindowController: NSObject {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    /// Closure fired after the user clicks Continue with all
    /// permissions granted. AppDelegate uses this to start the event
    /// tap and bring up the menubar — they were deliberately deferred
    /// so the system's "would like to control this computer" alert
    /// doesn't fire while the user is still on the onboarding screen.
    private var onComplete: (() -> Void)?

    func show(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
        if window == nil {
            let view = OnboardingView(onContinue: { [weak self] in
                self?.markDoneAndClose()
            })
            let host = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: host)
            win.title = "LangFlip"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 480, height: 460))
            win.isReleasedWhenClosed = false
            win.center()
            // Keep the window above other apps so when the user comes back
            // from System Settings they immediately see it. Without this
            // it's easy to lose under whatever happened to be focused
            // while they were toggling switches.
            win.level = .floating
            window = win
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Called from the OnboardingView when permission state advances.
    /// Brings the window forward so the user sees the new state without
    /// having to Cmd+Tab back from System Settings.
    func bringToFront() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func markDoneAndClose() {
        Settings.shared.onboardingDone = true
        window?.close()
        NSApp.setActivationPolicy(.accessory)
        let cb = onComplete
        onComplete = nil
        cb?()
    }
}

// MARK: - SwiftUI

private struct OnboardingView: View {
    let onContinue: () -> Void

    @State private var status: PermissionStatus = .current()
    /// Driven by polling — when it changes from "missing" to "granted",
    /// the view auto-advances to the next step and the window pops
    /// forward.
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var stepIndex: Int {
        if !status.accessibility { return 0 }
        if !status.inputMonitoring { return 1 }
        return 2 // done
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            Divider().padding(.vertical, 2)

            // Completed steps shrink to a one-line row with a checkmark;
            // the active step gets the prominent action card; the future
            // step (if any) is just hinted as a small disabled row so the
            // user can see what's coming.
            VStack(spacing: 10) {
                if stepIndex == 0 {
                    activeStep(.accessibility)
                    upcomingStep(.inputMonitoring)
                } else if stepIndex == 1 {
                    completedStep(.accessibility)
                    activeStep(.inputMonitoring)
                } else {
                    completedStep(.accessibility)
                    completedStep(.inputMonitoring)
                }
            }

            Divider().padding(.vertical, 2)

            footer
        }
        .padding(24)
        .frame(width: 432)
        .onReceive(timer) { _ in
            let next = PermissionStatus.current()
            guard next != status else { return }
            let wasIncomplete = !status.allGranted
            status = next
            // Pop the window forward when something just changed, so the
            // user immediately sees the next instruction after toggling
            // a switch in System Settings.
            if wasIncomplete {
                OnboardingWindowController.shared.bringToFront()
            }
        }
    }

    // MARK: Header / footer

    @ViewBuilder
    private var header: some View {
        if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 96, height: 96)
        }
        VStack(spacing: 4) {
            Text(status.allGranted ? "All set!" : "Welcome to LangFlip")
                .font(.system(size: 20, weight: .semibold))
            Text(headerSubtitle)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerSubtitle: String {
        switch stepIndex {
        case 0:
            return "Two quick permissions and you're done."
        case 1:
            return "One more permission to go."
        default:
            return "Look for ⌥ in your menu bar. Select text, then double-tap Shift to flip its layout; press both Shifts at once to pause."
        }
    }

    @ViewBuilder
    private var footer: some View {
        if status.allGranted {
            Button(action: onContinue) {
                Text("Continue")
                    .frame(minWidth: 120)
            }
            .keyboardShortcut(.return)
            .controlSize(.large)
        } else {
            // Plain helper text while the user is mid-flow. Tells them
            // explicitly to come back, since otherwise it's easy to assume
            // System Settings is where the app lives now.
            Text("After toggling LangFlip on, this window will update automatically. You don't have to come back manually.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }

    // MARK: Step rendering

    private enum Step {
        case accessibility, inputMonitoring

        var title: String {
            switch self {
            case .accessibility:   return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var rationale: String {
            switch self {
            case .accessibility:
                return "Lets LangFlip see the keys you press, so it can detect a wrong-layout word."
            case .inputMonitoring:
                return "Lets LangFlip rewrite the word and switch your input source for you."
            }
        }

        var stepNumber: Int {
            self == .accessibility ? 1 : 2
        }

        func openSettings() {
            switch self {
            case .accessibility:
                PermissionStatus.openAccessibilityPane()
            case .inputMonitoring:
                // The first call to IOHIDRequestAccess shows the system
                // dialog and adds us to the Input Monitoring list, so the
                // user has something to toggle when the pane opens.
                PermissionStatus.requestInputMonitoring()
                PermissionStatus.openInputMonitoringPane()
            }
        }
    }

    @ViewBuilder
    private func activeStep(_ step: Step) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "\(step.stepNumber).circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text(step.title)
                    .font(.headline)
                Text("(step \(step.stepNumber) of 2)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(step.rationale)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Click below, find **LangFlip** in the list and toggle it on.")
                .font(.callout)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: step.openSettings) {
                    Text("Open System Settings")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.08))
                )
        )
    }

    @ViewBuilder
    private func completedStep(_ step: Step) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundColor(.green)
            Text(step.title)
                .font(.body)
            Spacer()
            Text("Granted")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func upcomingStep(_ step: Step) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "\(step.stepNumber).circle")
                .font(.title3)
                .foregroundColor(.secondary)
            Text(step.title)
                .font(.body)
                .foregroundColor(.secondary)
            Spacer()
            Text("Step \(step.stepNumber)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
