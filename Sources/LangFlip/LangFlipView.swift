import SwiftUI

/// LangFlip section: all of the core layout-flip logic in one place. Gathers the
/// settings that used to live across the old Settings tabs — the enable toggle
/// and gesture hints (General), the flip behaviors and corrections (Behavior),
/// and the flip hotkey + modifier gestures (Hotkeys).
struct LangFlipView: View {
    @AppStorage("lf.enabled") private var enabled = true
    @AppStorage("lf.autoFlip") private var autoFlip = true
    @AppStorage("lf.doubleCapsFix") private var doubleCapsFix = true
    @AppStorage("lf.crossLayoutFix") private var crossLayoutFix = true
    @AppStorage("lf.suppressInFullscreen") private var suppressInFullscreen = false
    @AppStorage("lf.showOverlay") private var showOverlay = true
    @AppStorage("lf.flipLastWordsOnDoubleShift") private var flipLastWordsOnDoubleShift = true
    @AppStorage("lf.hotkeyPreset") private var hotkeyPreset = HotkeyPreset.doubleShift.rawValue

    @State private var appeared = false
    @State private var showingTutorial = false
    /// Live status for the two approvals the flip/hotkey features need. Onboarding
    /// no longer asks for these — the user grants them right here.
    @State private var permissions = PermissionStatus.current()

    private let permissionTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DisplayText("LangFlip", size: 26)
                .appearStagger(0, appeared)

            // Banner — entry point for the interactive onboarding tutorial we'll
            // build here next. "Try it out" opens the (placeholder) tutorial.
            FlowHero(
                titleLeading: "Never retype the",
                titleEmphasis: "wrong",
                titleTrailing: "layout.",
                subtitle: "Caught a sentence typed in the wrong keyboard layout? Select it and flip it in place — no deleting, no copy-paste.",
                ctaTitle: "Try it out",
                ctaAction: { showingTutorial = true }
            )
            .appearStagger(1, appeared)

            FlowSettingsGroup("Permissions") {
                FlowPermissionRow(title: "Accessibility",
                                  granted: permissions.accessibility,
                                  detail: "Lets Sayful insert the corrected text and read the focused field.",
                                  action: PermissionStatus.openAccessibilityPane)
                FlowPermissionRow(title: "Input Monitoring",
                                  granted: permissions.inputMonitoring,
                                  detail: "Lets Sayful see the flip hotkey and typed words across apps.",
                                  action: PermissionStatus.openInputMonitoringPane)
            }
            .appearStagger(2, appeared)

            // The flip settings only do anything once both permissions above are
            // granted — until then there's nothing useful to configure, so we hide
            // them behind a short notice and keep first-run focused on the grant.
            if permissions.allGranted {
            FlowSettingsGroup {
                FlowToggleRow(title: "Flip enabled", isOn: $enabled)
                FlowToggleRow(title: "Auto-flip at word end",
                              detail: "After Space or punctuation, Sayful can fix a word that was typed in the wrong layout. Press Backspace right away to undo and remember an exception.",
                              isOn: $autoFlip)
            }
            .appearStagger(3, appeared)

            FlowSettingsGroup("Flip hotkey") {
                FlowPickerRow(title: "Flip hotkey",
                              detail: "Flips selected text between keyboard layouts. If no text is selected and the no-selection toggle is on, the same gesture can try the last words before the cursor.",
                              selection: $hotkeyPreset,
                              options: HotkeyPreset.allCases.map { (value: $0.rawValue, label: $0.displayName) })
            }
            .appearStagger(4, appeared)

            FlowSettingsGroup("No-selection actions") {
                FlowToggleRow(title: "Double Shift flips last words",
                              detail: "When no text is selected, Sayful reads the focused text field through Accessibility and rewrites only the text before the cursor. Turn this off if a specific app behaves unpredictably.",
                              isOn: $flipLastWordsOnDoubleShift)
            }
            .appearStagger(5, appeared)

            FlowSettingsGroup("Corrections") {
                FlowToggleRow(title: "Fix sticky-shift typos (WOrld → World)",
                              detail: "Fixes accidental double-capital starts when the corrected word is clearly safe.",
                              isOn: $doubleCapsFix)
                FlowToggleRow(title: "Fix UK ↔ RU letter slips (ы ↔ і, э ↔ є)",
                              detail: "Fixes common Ukrainian/Russian letter slips when the corrected word is in the target dictionary.",
                              isOn: $crossLayoutFix)
            }
            .appearStagger(6, appeared)

            FlowSettingsGroup("Overlay & focus") {
                overlayRow
                FlowToggleRow(title: "Pause auto-flip in fullscreen apps",
                              detail: "Useful for games, video players, and other fullscreen apps where automatic changes may be distracting.",
                              isOn: $suppressInFullscreen)
            }
            .appearStagger(7, appeared)

            FlowSettingsGroup("Shift gestures") {
                gestureHint("1.circle", "Single Shift fixes selected text or the last sentence.")
                gestureHint("2.circle", "Double-tap Shift flips selected text or the last words.")
                gestureHint("3.circle", "Triple-tap Shift uses the secondary language.")
                gestureHint("wand.and.stars", "Press both Shift keys to run the Prompt Engineer transform. Pause/resume moved to the menu bar.")
                helpText("Single, double, and triple Shift depend on press timing, so they stay as fixed gestures for now.")
            }
            .appearStagger(8, appeared)
            } else {
                lockedNotice
                    .appearStagger(3, appeared)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appearTrigger($appeared)
        .onReceive(permissionTimer) { _ in permissions = PermissionStatus.current() }
        .sheet(isPresented: $showingTutorial) { LangFlipTutorialSheet() }
    }

    private var lockedNotice: some View {
        FlowCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock")
                    .font(.system(size: 15))
                    .foregroundColor(FlowTheme.accent)
                Text("Grant Accessibility and Input Monitoring above to finish setup. The flip and hotkey settings show up once both are on.")
                    .font(.system(size: 14))
                    .foregroundColor(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var overlayRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Show flip overlay").font(.system(size: 14)).foregroundColor(FlowTheme.ink)
                Spacer(minLength: 12)
                FlowSmallButton(title: "Preview") { previewOverlay() }
                Toggle("", isOn: $showOverlay)
                    .labelsHidden().toggleStyle(.switch).tint(FlowTheme.accent)
            }
            Text("Shows a small visual confirmation whenever Sayful rewrites text.")
                .font(.system(size: 12))
                .foregroundColor(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewOverlay() {
        // Force the overlay to play even when the user has it toggled off, so
        // they can see what they'd be opting into before flipping the switch.
        let wasOn = Settings.shared.showOverlay
        Settings.shared.showOverlay = true
        FlipOverlay.shared.show()
        if !wasOn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                Settings.shared.showOverlay = false
            }
        }
    }

    private func gestureHint(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(FlowTheme.accent)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(FlowTheme.inkSecondary)
        }
    }

    @ViewBuilder
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(FlowTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Placeholder for the interactive layout-flip tutorial. For now it explains how
/// to try the feature by hand; the live, step-by-step onboarding lands here next.
private struct LangFlipTutorialSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(icon: String, text: String)] = [
        ("text.cursor", "Type a sentence in the wrong keyboard layout (e.g. English while your layout is Ukrainian)."),
        ("selection.pin.in.out", "Select the garbled text."),
        ("arrow.2.squarepath", "Double-tap Shift — Sayful flips it to the right layout in place."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayText("Try a flip", size: 20)

            Text("An interactive walkthrough is coming here. For now, give it a go yourself:")
                .font(.system(size: 13))
                .foregroundColor(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: step.icon)
                            .font(.system(size: 15))
                            .foregroundColor(FlowTheme.accent)
                            .frame(width: 24)
                        Text(step.text)
                            .font(.system(size: 13))
                            .foregroundColor(FlowTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Spacer()
                FlowSmallButton(title: "Got it", prominent: true) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(FlowTheme.paper)
    }
}
