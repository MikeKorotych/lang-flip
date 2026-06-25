import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Hotkeys section: global shortcuts for the AI, voice, and dictation actions.
/// Moved out of Settings into its own sidebar tab (the layout-flip gestures live
/// in the LangFlip tab). Follows the primary-view pattern — no own ScrollView, the
/// outer one in MainWindow handles scrolling.
struct HotkeysView: View {
    @AppStorage("lf.translationHotkeyPreset") private var translationHotkeyPreset = GlobalShortcutPreset.shiftSpace.rawValue
    @AppStorage("lf.translationHotkeyCustom") private var translationHotkeyCustom = ""
    @AppStorage("lf.screenTextCaptureHotkeyPreset") private var screenTextCaptureHotkeyPreset = GlobalShortcutPreset.commandShiftS.rawValue
    @AppStorage("lf.screenTextCaptureHotkeyCustom") private var screenTextCaptureHotkeyCustom = ""
    @AppStorage("lf.readSelectionHotkeyPreset") private var readSelectionHotkeyPreset = GlobalShortcutPreset.commandShiftX.rawValue
    @AppStorage("lf.readSelectionHotkeyCustom") private var readSelectionHotkeyCustom = ""
    @AppStorage("lf.dictationPushToTalkEnabled") private var dictationPushToTalkEnabled = false
    @AppStorage("lf.dictationPushToTalkShortcut") private var dictationPushToTalkShortcut = DictationPushToTalkShortcut.anyShift.rawValue
    @AppStorage("lf.dictationHandsFreeEnabled") private var dictationHandsFreeEnabled = false
    @AppStorage("lf.dictationHandsFreeShortcut") private var dictationHandsFreeShortcut = DictationHandsFreeShortcut.leftOption.rawValue

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DisplayText("Hotkeys", size: 26)
                .appearStagger(0, appeared)

            FlowSettingsGroup("AI actions") {
                ShortcutRecorderRow(
                    title: "Translate selection",
                    preset: $translationHotkeyPreset,
                    custom: $translationHotkeyCustom,
                    choices: GlobalShortcutPreset.translationChoices
                )
                ShortcutRecorderRow(
                    title: "Capture text from screen",
                    preset: $screenTextCaptureHotkeyPreset,
                    custom: $screenTextCaptureHotkeyCustom,
                    choices: GlobalShortcutPreset.screenCaptureChoices
                )
                helpText("These shortcuts work globally. Turn each feature on or off in AI settings without losing the shortcut you picked here.")
            }
            .appearStagger(1, appeared)

            FlowSettingsGroup("Voice") {
                ShortcutRecorderRow(
                    title: "Read selected text aloud",
                    preset: $readSelectionHotkeyPreset,
                    custom: $readSelectionHotkeyCustom,
                    choices: GlobalShortcutPreset.readAloudChoices
                )
                helpText("Reads the current text selection with the voice backend selected in Voice settings.")
            }
            .appearStagger(2, appeared)

            FlowSettingsGroup("Dictation") {
                FlowToggleRow(title: "Push-to-talk dictation",
                              detail: "Hold the key to record, release to transcribe and insert.",
                              isOn: $dictationPushToTalkEnabled)
                FlowPickerRow(title: "Push-to-talk key",
                              selection: $dictationPushToTalkShortcut,
                              options: DictationPushToTalkShortcut.allCases.map { (value: $0.rawValue, label: $0.displayName) })

                Divider().overlay(FlowTheme.cardStroke)

                FlowToggleRow(title: "Hands-free dictation",
                              detail: "Press the key once to start, again to stop and transcribe.",
                              isOn: $dictationHandsFreeEnabled)
                FlowPickerRow(title: "Hands-free key",
                              selection: $dictationHandsFreeShortcut,
                              options: DictationHandsFreeShortcut.allCases.map { (value: $0.rawValue, label: $0.displayName) })

                helpText("Turn each mode on and pick its key here. Both can be enabled at once.")
            }
            .appearStagger(3, appeared)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appearTrigger($appeared)
    }

    @ViewBuilder
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(FlowTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row that shows a preset shortcut picker plus a "Record" button to capture a
/// custom global shortcut (modifiers + a normal key).
private struct ShortcutRecorderRow: View {
    let title: String
    @Binding var preset: String
    @Binding var custom: String
    let choices: [GlobalShortcutPreset]

    @State private var isRecording = false
    @State private var warning = ""
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 14)).foregroundColor(FlowTheme.ink)
                Spacer(minLength: 12)
                Picker("", selection: $preset) {
                    ForEach(choices) { shortcut in
                        Text(shortcut.displayName).tag(shortcut.rawValue)
                    }
                }
                .labelsHidden().pickerStyle(.menu).tint(FlowTheme.ink).fixedSize()
                .disabled(hasCustom || isRecording)

                FlowSmallButton(title: isRecording ? "Press keys…" : "Record") {
                    startRecording()
                }
                .disabled(isRecording)

                if hasCustom {
                    FlowSmallButton(title: "Use preset") {
                        custom = ""
                        warning = ""
                    }
                }
            }

            if hasCustom || isRecording || !warning.isEmpty {
                HStack(spacing: 8) {
                    if let shortcut = GlobalShortcut.decode(custom) {
                        Text("Custom: \(shortcut.displayName)")
                            .foregroundColor(FlowTheme.accent)
                    } else if isRecording {
                        Text("Press modifiers plus a normal key. Esc cancels.")
                            .foregroundColor(FlowTheme.inkSecondary)
                    }
                    if !warning.isEmpty {
                        Text(warning)
                            .foregroundColor(.orange)
                    }
                }
                .font(.system(size: 12))
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var hasCustom: Bool {
        GlobalShortcut.decode(custom) != nil
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        ShortcutRecordingState.isRecording = true
        warning = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event: event)
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        ShortcutRecordingState.isRecording = false
    }

    private func handle(event: NSEvent) -> NSEvent? {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return nil
        }
        guard let shortcut = GlobalShortcut.from(event: event) else {
            warning = "Use at least one modifier plus a normal key."
            return nil
        }
        if shortcut.modifiers == GlobalShortcut.shift && shortcut.keyCode != CGKeyCode(kVK_Space) {
            warning = "Shift-only shortcuts are too easy to trigger. Add Control, Option, or Command."
            return nil
        }
        custom = shortcut.encoded
        warning = ""
        stopRecording()
        return nil
    }
}
