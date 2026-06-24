import Foundation
import AppKit
import SwiftUI

private func log(_ s: String) {
    AppLog.write(s)
}

@main
struct LangFlipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings is the only Scene we declare — the actual UI lives in
        // hand-rolled NSWindow controllers (Onboarding, Main) so we have
        // full control over activation policy. The Settings scene here is
        // intentionally empty: macOS hooks Cmd+, to it for free, but we
        // never present its window — the menubar's Preferences… item opens
        // the main window's Settings section instead.
        SwiftUI.Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController?
    private var tap: EventTap?
    /// Polls for Accessibility + Input Monitoring while the event tap isn't
    /// running yet, so granting them at runtime (from the LangFlip tab) starts
    /// the flip/dictation hotkeys immediately — no relaunch needed. Invalidated
    /// the moment the tap comes up.
    private var permissionWatch: Timer?
    /// Eager-init the updater so Sparkle starts its scheduled-check timer
    /// immediately. Held by the delegate so it lives for the app's lifetime.
    private let updater = Updater.shared

    /// Called when the user re-launches a running instance — most often
    /// by double-clicking /Applications/LangFlip.app while the app is
    /// already in the menubar. With LSUIElement = true the default
    /// behaviour is silent (no Dock icon to bounce, no main window to
    /// raise), which looks identical to a launch failure. Open
    /// Preferences instead so the click gets visible feedback and the
    /// user can confirm the app is alive.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            MainWindowController.shared.show()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Identity rename (LangFlip → Sayful): carry over the previous install's
        // settings + data before anything reads UserDefaults or writes a log.
        IdentityMigration.runIfNeeded()

        // Status-bar accessory: no Dock icon, no main menu.
        // OnboardingWindowController and MainWindowController flip this to
        // .regular while their window is on screen, then back to .accessory
        // when it closes.
        NSApp.setActivationPolicy(.accessory)

        log("startup, pid=\(getpid())")

        // Cheap, prompt-free permission read. We deliberately do NOT
        // pass prompt=true here, and we do NOT call
        // requestInputMonitoring() yet. Either of those would surface
        // a system modal ("LangFlip would like to control this
        // computer…") that would race our onboarding window. The
        // onboarding window's per-step "Open System Settings" buttons
        // open the right Privacy & Security pane and the IOHID
        // request fires from there.
        let perms = PermissionStatus.current(prompt: false)
        log("Accessibility permission: \(perms.accessibility ? "GRANTED" : "MISSING")")
        log("Input Monitoring permission: \(perms.inputMonitoring ? "GRANTED" : "MISSING / NOT YET REQUESTED")")

        let shouldReturnToSetup = Settings.shared.returnToOnboardingAfterScreenRecording

        // Onboarding is now first-launch only and asks for the microphone
        // alone (dictation is the hero). Accessibility + Input Monitoring,
        // which power the flip/hotkey features, are granted from the LangFlip
        // tab's Permissions section instead — so we no longer gate startup on
        // them or re-show onboarding when they're missing. The event tap below
        // simply stays inert until those are granted, then works on the next
        // launch (or immediately, since the tap is created lazily here).
        if !Settings.shared.onboardingDone || shouldReturnToSetup {
            log("showing onboarding window — deferring tap/menubar startup until Continue")
            OnboardingWindowController.shared.show(onComplete: { [weak self] in
                self?.startServices()
            })
            return
        }

        startServices()
    }

    /// Spin up the parts of the app that depend on system permissions.
    /// Called either directly when permissions were already granted at
    /// launch, or from the onboarding window's Continue callback after
    /// the user has finished granting them.
    ///
    /// Splitting this out is what stops macOS from showing its built-in
    /// "would like to control your computer" dialog on top of our
    /// onboarding window — CGEvent.tapCreate() is the call that
    /// triggers that dialog, and we now postpone it until the user has
    /// already toggled the right switches in System Settings.
    private func startServices() {
        // The event tap needs Accessibility + Input Monitoring, which onboarding
        // no longer asks for (it's mic-only now). Start it if those are already
        // granted; otherwise the watcher below brings it up the moment the user
        // grants them in the LangFlip tab — so the hotkeys work without a relaunch.
        startEventTapIfNeeded()
        startPermissionWatchIfNeeded()

        // The menubar no longer dispatches per-action commands (those run via
        // global hotkeys handled by the event tap), so it doesn't need a tap
        // reference — it's a thin launcher/settings menu now.
        menubar = MenubarController()
        log("menubar ready (look for ⌥ icon in menu bar)")

        // Extended dictionaries install themselves on first launch — no manual
        // step required (the Dictionary tab just shows status afterwards).
        DictionaryManager.autoInstallExtendedPacksIfNeeded()

        // Always-on dictation island (Wispr-style) at the bottom of the screen.
        DictationIslandController.shared.startIfEnabled()

        // If already signed in to the backend, load the account (role/quota) now
        // so the profile menu is correct from launch — not only after opening AI settings.
        if SupabaseBackendAuth.shared.isSignedIn {
            Task { @MainActor in _ = try? await SupabaseBackendAuth.shared.refreshUser() }
        }

        // Diagnostic: surface the AI assistant's readiness at launch
        // so users can tell why grammar / fix / translate features stay
        // silent. Foundation Models reports `.unavailable(reason)` for
        // states like Apple Intelligence-disabled, model-not-downloaded,
        // unsupported-region — easier to read here than to chase via
        // feature-trigger debug logs.
        let assistant = AIAssistantManager.shared.current
        let assistantReady = assistant.isReady
        Settings.shared.applyRecommendedAIHotkeyDefaults(assistantReady: assistantReady)
        log("AI mode = \(Settings.shared.aiMode.rawValue), isReady = \(assistantReady)")
        if #available(macOS 26.0, *), Settings.shared.aiMode == .appleFoundation {
            if let fm = assistant as? FoundationModelsAssistant {
                log("Foundation Models availability: \(fm.availabilityDescription)")
            }
        }
        if Settings.shared.aiMode == .ollama {
            log("Ollama model: '\(Settings.shared.ollamaModel)' (daemon expected at http://localhost:11434)")
        }
        if Settings.shared.aiMode == .openai {
            let hasKey = !(Settings.shared.openaiAPIKey?.isEmpty ?? true)
            log("OpenAI mode: model='\(Settings.shared.openaiModel)' base='\(Settings.shared.openaiBaseURL)' key=\(hasKey ? "present" : "MISSING — set in Preferences")")
        }
        if assistantReady {
            DispatchQueue.global(qos: .utility).async {
                assistant.warmUp()
            }
        }
    }

    /// Create + start the keyboard event tap if it isn't running and the two
    /// permissions it needs are granted. Idempotent and safe to call repeatedly.
    private func startEventTapIfNeeded() {
        guard tap == nil, PermissionStatus.current(prompt: false).allGranted else { return }
        let tap = EventTap()
        do {
            try tap.start()
            self.tap = tap
            log("event tap started successfully")
        } catch {
            self.tap = nil
            log("event tap FAILED: \(error.localizedDescription)")
        }
    }

    /// While the tap is down, poll for the flip/hotkey permissions so it comes up
    /// as soon as the user grants them — then stop polling.
    private func startPermissionWatchIfNeeded() {
        guard tap == nil, permissionWatch == nil else { return }
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.startEventTapIfNeeded()
            if self.tap != nil {
                timer.invalidate()
                self.permissionWatch = nil
                log("event tap started after permissions were granted at runtime")
            }
        }
    }
}
