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
    /// Eager-init the updater so Sparkle starts its scheduled-check timer
    /// immediately. Held by the delegate so it lives for the app's lifetime.
    private let updater = Updater.shared

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

        let tap = EventTap()
        do {
            try tap.start()
            self.tap = tap
            log("event tap started successfully")
        } catch {
            log("event tap FAILED: \(error.localizedDescription)")
        }

        // Menubar gets a reference to the tap so its "Translate selection"
        // submenu can dispatch into it.
        menubar = MenubarController(eventTap: tap)
        log("menubar ready (look for ⌥ icon in menu bar)")

        // Diagnostic: surface the AI assistant's readiness at launch
        // so users can tell why grammar / fix / translate features stay
        // silent. Foundation Models reports `.unavailable(reason)` for
        // states like Apple Intelligence-disabled, model-not-downloaded,
        // unsupported-region — easier to read here than to chase via
        // feature-trigger debug logs.
        let assistant = AIAssistantManager.shared.current
        log("AI mode = \(Settings.shared.aiMode.rawValue), isReady = \(assistant.isReady)")
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
    }
}
