import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

/// Top-level Preferences view: 5 sections covering everything that used to
/// live in the menubar. The menubar keeps only quick toggles + the
/// "Preferences…" entry point.
///
/// Uses a segmented Picker rather than SwiftUI's `TabView` because the
/// macOS TabView styling pads the selected tab's highlight more than the
/// label requires, so labels and the blue selection rect don't visually
/// line up (especially noticeable on short tab names like "General").
struct PreferencesView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case languages = "Languages"
        case behavior = "Behavior"
        case models = "AI"
        case voice = "Voice"
        case apps = "Apps"
        case about = "About"

        var id: Self { self }
    }

    @State private var section: Section = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch section {
                case .general:   GeneralTab()
                case .languages: LanguagesTab()
                case .behavior:  BehaviorTab()
                case .models:    ModelsTab()
                case .voice:     VoiceTab()
                case .apps:      AppsTab()
                case .about:     AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 440)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage("lf.enabled") private var enabled = true
    @AppStorage("lf.soundEnabled") private var soundEnabled = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var permissions = PermissionStatus.current()
    @State private var learnedExceptions = GeneralTab.sortedExceptions()
    @State private var newException = ""

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("LangFlip enabled", isOn: $enabled)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        launchAtLogin = newValue
                        LaunchAtLogin.set(newValue)
                        // Re-read in case the system rejected the change.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                Toggle("Sound feedback", isOn: $soundEnabled)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    granted: permissions.accessibility,
                    open: PermissionStatus.openAccessibilityPane
                )
                permissionRow(
                    title: "Input Monitoring",
                    granted: permissions.inputMonitoring,
                    open: PermissionStatus.openInputMonitoringPane
                )
            }

            Section("Learning") {
                HStack {
                    Text("Remembered exceptions")
                    Spacer()
                    Text("\(learnedExceptions.count)").foregroundColor(.secondary)
                    Button("Forget all") {
                        BackspaceLearner.shared.clearExceptions()
                        refreshLearning()
                    }
                    .disabled(learnedExceptions.isEmpty)
                }

                HStack {
                    TextField("Add word to never auto-flip", text: $newException)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        BackspaceLearner.shared.addException(newException)
                        newException = ""
                        refreshLearning()
                    }
                    .disabled(newException.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)

                if learnedExceptions.isEmpty {
                    Text("No learned exceptions yet. When you undo a bad auto-flip with Backspace, LangFlip remembers that word here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(learnedExceptions, id: \.self) { word in
                            HStack {
                                Text(word)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    BackspaceLearner.shared.removeException(word)
                                    refreshLearning()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                .help("Remove \(word) from learned exceptions")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshLearning()
        }
        .onReceive(timer) { _ in
            permissions = PermissionStatus.current()
            refreshLearning()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    private func refreshLearning() {
        learnedExceptions = Self.sortedExceptions()
    }

    private static func sortedExceptions() -> [String] {
        BackspaceLearner.shared.exceptions.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(granted ? .green : .orange)
            Text(title)
            Spacer()
            Button("Open System Settings", action: open)
                .controlSize(.small)
        }
    }
}

// MARK: - Voice

private struct VoiceTab: View {
    @AppStorage("lf.ttsBackend") private var ttsBackend = TextToSpeechBackend.system.rawValue
    @AppStorage("lf.speechVoiceIdentifier") private var speechVoiceIdentifier = ""
    @AppStorage("lf.speechRate") private var speechRate = 190.0
    @AppStorage("lf.omniVoiceLanguage") private var omniVoiceLanguage = OmniVoiceLanguage.auto.rawValue
    @AppStorage("lf.omniVoiceGender") private var omniVoiceGender = OmniVoiceGenderStyle.none.rawValue
    @AppStorage("lf.omniVoiceAge") private var omniVoiceAge = OmniVoiceAgeStyle.none.rawValue
    @AppStorage("lf.omniVoicePitch") private var omniVoicePitch = OmniVoicePitchStyle.none.rawValue
    @AppStorage("lf.omniVoiceAccent") private var omniVoiceAccent = OmniVoiceAccentStyle.none.rawValue
    @AppStorage("lf.omniVoiceWhisper") private var omniVoiceWhisper = false
    @AppStorage("lf.omniVoiceSpeed") private var omniVoiceSpeed = 1.0
    @AppStorage("lf.omniVoiceDuration") private var omniVoiceDuration = 0.0
    @AppStorage("lf.omniVoiceNumSteps") private var omniVoiceNumSteps = 32
    @AppStorage("lf.omniVoiceGuidanceScale") private var omniVoiceGuidanceScale = 2.0
    @AppStorage("lf.omniVoiceDenoise") private var omniVoiceDenoise = true
    @AppStorage("lf.omniVoicePostprocessOutput") private var omniVoicePostprocessOutput = true
    @AppStorage("lf.omniVoiceTShift") private var omniVoiceTShift = 0.1
    @AppStorage("lf.omniVoiceLayerPenaltyFactor") private var omniVoiceLayerPenaltyFactor = 5.0
    @AppStorage("lf.omniVoicePositionTemperature") private var omniVoicePositionTemperature = 5.0
    @AppStorage("lf.omniVoiceClassTemperature") private var omniVoiceClassTemperature = 0.0
    @AppStorage("lf.omniVoiceReferenceAudioPath") private var omniVoiceReferenceAudioPath = ""
    @AppStorage("lf.omniVoiceReferenceText") private var omniVoiceReferenceText = ""
    @AppStorage("lf.readSelectionHotkeyEnabled") private var readSelectionHotkeyEnabled = true
    @AppStorage("lf.whisperModelPath") private var whisperModelPath = ""
    @AppStorage("lf.whisperLanguage") private var whisperLanguage = "auto"

    @State private var microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()
    @State private var voices = SpeechReader.availableVoices
    @State private var recorderIsRecording = VoiceRecorder.shared.isRecording
    @State private var recorderElapsed = VoiceRecorder.shared.elapsed
    @State private var recorderAverageLevel = VoiceRecorder.shared.normalizedAveragePower
    @State private var recorderPeakLevel = VoiceRecorder.shared.normalizedPeakPower
    @State private var activeInputName = VoiceRecorder.shared.activeInputName
    @State private var inputDevices = VoiceRecorder.inputDevices
    @State private var lastRecordingURL = VoiceRecorder.shared.lastRecordingURL
    @State private var recorderError = VoiceRecorder.shared.lastError
    @State private var whisperAvailability = WhisperTranscriber.availability()
    @State private var isTranscribing = false
    @State private var transcriptionText = ""
    @State private var transcriptionError: String?
    @State private var downloadingWhisperModel: WhisperTranscriber.Model?
    @State private var downloadProgress: Double?
    @State private var whisperDownloadMessage: String?
    @State private var omniVoiceAvailability = OmniVoiceSynthesizer.availability()
    @State private var isGeneratingOmniVoice = false
    @State private var omniVoiceOutputURL = OmniVoiceSynthesizer.shared.lastOutputURL
    @State private var omniVoiceMessage: String?

    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Text to speech") {
                Picker(selection: $ttsBackend) {
                    ForEach(TextToSpeechBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend.rawValue)
                    }
                } label: {
                    settingLabel("Backend", help: "Choose between the built-in macOS voices and the local OmniVoice model.")
                }

                if activeTTSBackend == .system {
                    Picker(selection: $speechVoiceIdentifier) {
                        Text("System default").tag("")
                        ForEach(voices, id: \.self) { voice in
                            Text(SpeechReader.displayName(for: voice)).tag(voice)
                        }
                    } label: {
                        settingLabel("Voice", help: "The macOS system voice used when Backend is set to System voices.")
                    }
                    .onChange(of: speechVoiceIdentifier) { _ in
                        SpeechReader.shared.applySettings()
                    }

                    HStack {
                        settingLabel("Speed", help: "Speech rate for macOS system voices. Higher numbers speak faster.")
                        Slider(value: $speechRate, in: 120...260, step: 5)
                            .onChange(of: speechRate) { _ in
                                SpeechReader.shared.applySettings()
                            }
                        Text("\(Int(speechRate))")
                            .foregroundColor(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                } else {
                    Picker(selection: $omniVoiceLanguage) {
                        ForEach(OmniVoiceLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    } label: {
                        settingLabel("Language", help: "Language hint passed to OmniVoice. Auto guesses English, Ukrainian, or Russian from the selected text.")
                    }

                    HStack {
                        settingLabel("OmniVoice", help: "Runtime status for the local OmniVoice text-to-speech model.")
                        Spacer()
                        Text(omniVoiceStatusLabel)
                            .foregroundColor(omniVoiceAvailability.isReady ? .green : .orange)
                            .lineLimit(1)
                    }

                    Picker(selection: $omniVoiceGender) {
                        ForEach(OmniVoiceGenderStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    } label: {
                        settingLabel("Voice", help: "High-level voice identity hint. OmniVoice supports male and female voice design tags.")
                    }

                    Picker(selection: $omniVoiceAge) {
                        ForEach(OmniVoiceAgeStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    } label: {
                        settingLabel("Age", help: "Age-style hint for voice design. It changes the character of the generated voice, not the text.")
                    }

                    Picker(selection: $omniVoicePitch) {
                        ForEach(OmniVoicePitchStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    } label: {
                        settingLabel("Pitch", help: "Voice pitch hint. Lower sounds deeper; higher sounds brighter.")
                    }

                    Picker(selection: $omniVoiceAccent) {
                        ForEach(OmniVoiceAccentStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    } label: {
                        settingLabel("Accent", help: "Accent hint for voice design. Most useful for English speech.")
                    }

                    Toggle(isOn: $omniVoiceWhisper) {
                        settingLabel("Whispered voice", help: "Adds OmniVoice's whisper style tag, making the generated voice sound quieter and breathier.")
                    }

                    Divider()

                    HStack {
                        settingLabel("Reference voice", help: "Optional audio sample for voice cloning. OmniVoice will try to imitate the speaker from this file.")
                        Spacer()
                        Text(omniVoiceReferenceAudioLabel)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Button("Choose Audio") {
                            chooseOmniVoiceReferenceAudio()
                        }
                        .controlSize(.small)
                        Button("Clear") {
                            omniVoiceReferenceAudioPath = ""
                            omniVoiceReferenceText = ""
                        }
                        .disabled(omniVoiceReferenceAudioPath.isEmpty)
                        .controlSize(.small)
                    }

                    TextField("Reference transcript (optional)", text: $omniVoiceReferenceText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .disabled(omniVoiceReferenceAudioPath.isEmpty)
                        .help("Optional transcript of the reference audio. Providing it can improve voice cloning quality.")

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            settingLabel("Speed", help: "Playback speed multiplier. 1.0 is normal; lower is slower, higher is faster. Disabled when fixed Duration is set.")
                            Slider(value: $omniVoiceSpeed, in: 0.5...1.5, step: 0.05)
                            Text(String(format: "%.2fx", omniVoiceSpeed))
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                        .disabled(omniVoiceDuration > 0)

                        HStack {
                            settingLabel("Duration", help: "Fixed output length in seconds. Auto lets OmniVoice estimate natural duration. Any fixed value overrides Speed.")
                            Slider(value: $omniVoiceDuration, in: 0...60, step: 0.5)
                            Text(omniVoiceDuration > 0 ? String(format: "%.1fs", omniVoiceDuration) : "Auto")
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            settingLabel("Inference steps", help: "Generation quality budget. Fewer steps are faster; more steps can improve quality but take longer.")
                            Slider(
                                value: Binding(
                                    get: { Double(omniVoiceNumSteps) },
                                    set: { omniVoiceNumSteps = Int($0.rounded()) }
                                ),
                                in: 4...64,
                                step: 1
                            )
                            Text("\(omniVoiceNumSteps)")
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            settingLabel("Guidance", help: "How strongly the model follows the language, style, and voice conditions. Higher can be more controlled but less natural.")
                            Slider(value: $omniVoiceGuidanceScale, in: 0...4, step: 0.1)
                            Text(String(format: "%.1f", omniVoiceGuidanceScale))
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }

                    DisclosureGroup("Advanced generation") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $omniVoiceDenoise) {
                                settingLabel("Denoise", help: "Adds OmniVoice's denoise conditioning. Usually best left on for cleaner speech.")
                            }
                            Toggle(isOn: $omniVoicePostprocessOutput) {
                                settingLabel("Postprocess output", help: "Trims long silences and applies small audio cleanup after generation. Usually best left on.")
                            }
                            advancedOmniVoiceSlider("T-shift", value: $omniVoiceTShift, range: 0...2, step: 0.05, help: "Sampling timestep shift. The default is conservative; changing it can alter timing and stability.")
                            advancedOmniVoiceSlider("Layer penalty", value: $omniVoiceLayerPenaltyFactor, range: 0...10, step: 0.5, help: "Penalty used during token/codebook selection. Higher values push the model toward earlier layers.")
                            advancedOmniVoiceSlider("Position temperature", value: $omniVoicePositionTemperature, range: 0...10, step: 0.5, help: "Randomness for position selection. Higher values can add variety but may reduce consistency.")
                            advancedOmniVoiceSlider("Class temperature", value: $omniVoiceClassTemperature, range: 0...2, step: 0.05, help: "Randomness for token sampling. 0 is greedy and most stable; higher values can be more varied.")
                            Button("Reset generation settings") {
                                Settings.shared.resetOmniVoiceGenerationSettings()
                                syncOmniVoiceGenerationSettingsFromDefaults()
                            }
                            .controlSize(.small)
                            .help("Restore OmniVoice generation settings to the model defaults used by LangFlip.")
                        }
                        .padding(.top, 6)
                    }

                    if let omniVoiceMessage {
                        Text(omniVoiceMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let omniVoiceOutputURL {
                        HStack {
                            Text("Last OmniVoice output")
                            Spacer()
                            Text(omniVoiceOutputURL.lastPathComponent)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Button("Play") {
                                OmniVoiceSynthesizer.shared.play(omniVoiceOutputURL)
                            }
                            .controlSize(.small)
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([omniVoiceOutputURL])
                            }
                            .controlSize(.small)
                        }
                    }
                }

                HStack {
                    Button(activeTTSBackend == .omniVoice && isGeneratingOmniVoice ? "Generating…" : "Read sample") {
                        readTTSSample()
                    }
                    .disabled(activeTTSBackend == .omniVoice && (!omniVoiceAvailability.isReady || isGeneratingOmniVoice))

                    Button("Stop") {
                        SpeechReader.shared.stop()
                        OmniVoiceSynthesizer.shared.stop()
                        isGeneratingOmniVoice = false
                    }
                    Spacer()
                }
                .controlSize(.small)

                helpText("Use the menu bar action to read the current text selection aloud. System voices are instant; OmniVoice is local, higher quality, and heavier.")
            }

            Section("Read aloud shortcut") {
                Toggle("Read selected text with Control+Option+X", isOn: $readSelectionHotkeyEnabled)
                helpText("Select text in any app and press Control+Option+X. LangFlip copies the selection briefly, restores your clipboard, and reads it with the selected text-to-speech backend.")
            }

            Section("Dictation") {
                HStack {
                    Image(systemName: microphoneStatus == .authorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(microphoneStatus == .authorized ? .green : .orange)
                    Text("Microphone")
                    Text(microphoneStatusLabel)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(microphoneButtonTitle) {
                        switch microphoneStatus {
                        case .authorized:
                            PermissionStatus.openMicrophonePane()
                        case .notDetermined:
                            PermissionStatus.requestMicrophone { granted in
                                microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()
                            }
                        case .denied, .restricted:
                            PermissionStatus.openMicrophonePane()
                        @unknown default:
                            PermissionStatus.openMicrophonePane()
                        }
                    }
                    .controlSize(.small)
                }

                Divider()

                HStack {
                    Text("Input")
                    Spacer()
                    Text(activeInputName)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button("Sound Settings") {
                        PermissionStatus.openSoundInputPane()
                    }
                    .controlSize(.small)
                }

                if !inputDevices.isEmpty {
                    Text("Detected: \(inputDevices.map(\.localizedName).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack {
                    Button(recorderIsRecording ? "Stop test recording" : "Start test recording") {
                        if recorderIsRecording {
                            VoiceRecorder.shared.stop()
                        } else if microphoneStatus == .authorized {
                            _ = VoiceRecorder.shared.start()
                        } else if microphoneStatus == .notDetermined {
                            PermissionStatus.requestMicrophone { _ in
                                microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()
                                if microphoneStatus == .authorized {
                                    _ = VoiceRecorder.shared.start()
                                }
                            }
                        } else {
                            PermissionStatus.openMicrophonePane()
                        }
                        refreshRecorderState()
                    }
                    .disabled(microphoneStatus == .restricted)

                    if recorderIsRecording {
                        Text(formatDuration(recorderElapsed))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .controlSize(.small)

                if recorderIsRecording {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Input level")
                            Spacer()
                            Text(recorderPeakLevel > 0.04 ? "hearing you" : "quiet")
                                .foregroundColor(.secondary)
                        }
                        ProgressView(value: recorderAverageLevel)
                        ProgressView(value: recorderPeakLevel)
                            .tint(.green)
                    }
                    .font(.caption)
                }

                if let lastRecordingURL {
                    HStack {
                        Text("Last recording")
                        Spacer()
                        Text(lastRecordingURL.lastPathComponent)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
                        }
                        .controlSize(.small)
                    }
                }

                Divider()

                Picker("Language", selection: $whisperLanguage) {
                    Text("Auto").tag("auto")
                    Text("Українська").tag("uk")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }

                HStack {
                    Text("Speech model")
                    Spacer()
                    Text(activeSpeechModelLabel)
                        .foregroundColor(.green)
                        .lineLimit(1)
                }

                ForEach(WhisperTranscriber.Model.allCases) { model in
                    HStack {
                        Image(systemName: isSelectedWhisperModel(model) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelectedWhisperModel(model) ? .green : .secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.displayName)
                                if isSelectedWhisperModel(model) {
                                    Text("Selected")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            Text("\(model.approximateSize) · \(model.note)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if WhisperTranscriber.isInstalled(model) {
                            Button(isSelectedWhisperModel(model) ? "Test" : "Use") {
                                if isSelectedWhisperModel(model) {
                                    transcribeLastRecording()
                                } else {
                                    whisperModelPath = model.localURL.path
                                    whisperAvailability = WhisperTranscriber.availability()
                                    whisperDownloadMessage = "\(model.displayName) selected."
                                }
                            }
                            .disabled(isSelectedWhisperModel(model) && (lastRecordingURL == nil || isTranscribing))
                            .controlSize(.small)
                        } else {
                            Button(downloadingWhisperModel == model ? "Downloading…" : "Download") {
                                downloadWhisperModel(model)
                            }
                            .disabled(downloadingWhisperModel != nil)
                            .controlSize(.small)
                        }
                    }
                }

                if let whisperDownloadMessage {
                    Text(whisperDownloadMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let downloadProgress {
                    ProgressView(value: downloadProgress)
                    Text(downloadPercentLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("Models folder: \(WhisperTranscriber.modelsDirectory.path)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack {
                    Button(isTranscribing ? "Testing…" : "Test selected model") {
                        transcribeLastRecording()
                    }
                    .disabled(isTranscribing || lastRecordingURL == nil || !whisperAvailability.isReady)

                    if let lastRecordingURL {
                        Button("Copy result") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcriptionText, forType: .string)
                        }
                        .disabled(transcriptionText.isEmpty)
                        .controlSize(.small)

                        Text(lastRecordingURL.pathExtension.uppercased())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .controlSize(.small)

                if !transcriptionText.isEmpty {
                    Text(transcriptionText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let transcriptionError {
                    Text("Transcription failed: \(transcriptionError)")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let recorderError {
                    Text("Recording failed: \(recorderError)")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                helpText("Hold Shift to dictate while pressed. Press Command+Shift to toggle hands-free dictation. Whisper transcribes the last recording here for testing.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            voices = SpeechReader.availableVoices
            microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()
            refreshRecorderState()
            refreshOmniVoiceState()
        }
        .onReceive(timer) { _ in
            microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()
            refreshRecorderState()
            refreshOmniVoiceState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .langFlipVoiceRecorderChanged)) { _ in
            refreshRecorderState()
        }
    }

    private var microphoneStatusLabel: String {
        switch microphoneStatus {
        case .authorized: return "Granted"
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private var microphoneButtonTitle: String {
        switch microphoneStatus {
        case .authorized: return "Open System Settings"
        case .notDetermined: return "Request Access"
        case .denied, .restricted: return "Open System Settings"
        @unknown default: return "Open System Settings"
        }
    }

    private func refreshRecorderState() {
        recorderIsRecording = VoiceRecorder.shared.isRecording
        recorderElapsed = VoiceRecorder.shared.elapsed
        recorderAverageLevel = VoiceRecorder.shared.normalizedAveragePower
        recorderPeakLevel = VoiceRecorder.shared.normalizedPeakPower
        activeInputName = recorderIsRecording ? VoiceRecorder.shared.activeInputName : VoiceRecorder.defaultInputDeviceName()
        inputDevices = VoiceRecorder.inputDevices
        lastRecordingURL = VoiceRecorder.shared.lastRecordingURL
        recorderError = VoiceRecorder.shared.lastError
        whisperAvailability = WhisperTranscriber.availability()
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var activeTTSBackend: TextToSpeechBackend {
        TextToSpeechBackend(rawValue: ttsBackend) ?? .system
    }

    private var omniVoiceStatusLabel: String {
        if omniVoiceAvailability.executableURL == nil { return "Runtime missing" }
        if omniVoiceAvailability.ffmpegURL == nil { return "ffmpeg missing" }
        if !omniVoiceAvailability.modelCacheExists { return "Model will download on first use" }
        return "Ready"
    }

    private var omniVoiceReferenceAudioLabel: String {
        guard !omniVoiceReferenceAudioPath.isEmpty else { return "None" }
        return URL(fileURLWithPath: omniVoiceReferenceAudioPath).lastPathComponent
    }

    private func refreshOmniVoiceState() {
        omniVoiceAvailability = OmniVoiceSynthesizer.availability()
        omniVoiceOutputURL = OmniVoiceSynthesizer.shared.lastOutputURL
    }

    private func chooseOmniVoiceReferenceAudio() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            omniVoiceReferenceAudioPath = url.path
        }
    }

    private func readTTSSample() {
        let sample = "LangFlip can now read selected text aloud with the selected text to speech backend."
        if activeTTSBackend == .system {
            SpeechReader.shared.speak(sample)
            return
        }

        isGeneratingOmniVoice = true
        omniVoiceMessage = "Generating OmniVoice sample..."
        Task {
            do {
                let url = try await OmniVoiceSynthesizer.shared.generate(text: sample)
                await MainActor.run {
                    isGeneratingOmniVoice = false
                    omniVoiceOutputURL = url
                    omniVoiceMessage = "Generated \(url.lastPathComponent)."
                    OmniVoiceSynthesizer.shared.play(url)
                }
            } catch {
                await MainActor.run {
                    isGeneratingOmniVoice = false
                    omniVoiceMessage = "OmniVoice failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func syncOmniVoiceGenerationSettingsFromDefaults() {
        omniVoiceSpeed = Settings.shared.omniVoiceSpeed
        omniVoiceDuration = Settings.shared.omniVoiceDuration
        omniVoiceNumSteps = Settings.shared.omniVoiceNumSteps
        omniVoiceGuidanceScale = Settings.shared.omniVoiceGuidanceScale
        omniVoiceDenoise = Settings.shared.omniVoiceDenoise
        omniVoicePostprocessOutput = Settings.shared.omniVoicePostprocessOutput
        omniVoiceTShift = Settings.shared.omniVoiceTShift
        omniVoiceLayerPenaltyFactor = Settings.shared.omniVoiceLayerPenaltyFactor
        omniVoicePositionTemperature = Settings.shared.omniVoicePositionTemperature
        omniVoiceClassTemperature = Settings.shared.omniVoiceClassTemperature
    }

    @ViewBuilder
    private func settingLabel(_ title: String, help: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundColor(.secondary)
                .help(help)
        }
        .help(help)
    }

    @ViewBuilder
    private func advancedOmniVoiceSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        help: String
    ) -> some View {
        HStack {
            settingLabel(title, help: help)
            Slider(value: value, in: range, step: step)
            Text(String(format: "%.2f", value.wrappedValue))
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .help(help)
    }

    private var activeSpeechModelLabel: String {
        if let model = WhisperTranscriber.Model.allCases.first(where: { isSelectedWhisperModel($0) }) {
            return model.displayName
        }
        return whisperAvailability.modelURL?.lastPathComponent ?? "Whisper"
    }

    private func isSelectedWhisperModel(_ model: WhisperTranscriber.Model) -> Bool {
        let selected = whisperAvailability.modelURL?.standardizedFileURL.path
            ?? URL(fileURLWithPath: NSString(string: whisperModelPath).expandingTildeInPath).standardizedFileURL.path
        return selected == model.localURL.standardizedFileURL.path
    }

    private func transcribeLastRecording() {
        guard let lastRecordingURL else { return }
        isTranscribing = true
        transcriptionText = ""
        transcriptionError = nil

        Task {
            do {
                let text = try await WhisperTranscriber.transcribe(
                    audioURL: lastRecordingURL,
                    language: whisperLanguage
                )
                await MainActor.run {
                    transcriptionText = text
                    isTranscribing = false
                }
            } catch {
                await MainActor.run {
                    transcriptionError = error.localizedDescription
                    isTranscribing = false
                }
            }
        }
    }

    private func downloadWhisperModel(_ model: WhisperTranscriber.Model) {
        downloadingWhisperModel = model
        whisperDownloadMessage = "Downloading \(model.displayName) (\(model.approximateSize))…"

        Task {
            do {
                let url = try await WhisperTranscriber.download(model) { progress in
                    downloadProgress = progress.fraction
                    whisperDownloadMessage = "Downloading \(model.displayName): \(formatPercent(progress.fraction)) to \(WhisperTranscriber.modelsDirectory.path)"
                }
                await MainActor.run {
                    whisperModelPath = url.path
                    whisperAvailability = WhisperTranscriber.availability()
                    downloadingWhisperModel = nil
                    downloadProgress = nil
                    whisperDownloadMessage = "\(model.displayName) is ready."
                }
            } catch {
                await MainActor.run {
                    downloadingWhisperModel = nil
                    downloadProgress = nil
                    whisperDownloadMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private var downloadPercentLabel: String {
        guard let downloadProgress else { return "" }
        return "\(formatPercent(downloadProgress)) downloaded"
    }

    private func formatPercent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    @ViewBuilder
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Languages

private struct LanguagesTab: View {
    @AppStorage("lf.primaryLanguage") private var primary = "uk"
    @AppStorage("lf.secondaryLanguage") private var secondary = ""

    var body: some View {
        Form {
            Section {
                Picker("Primary language", selection: $primary) {
                    Text("Українська").tag("uk")
                    Text("Русский").tag("ru")
                }
                .onChange(of: primary) { newValue in
                    // Clearing the secondary if it now collides with the primary.
                    if secondary == newValue { secondary = "" }
                }

                Picker("Secondary language", selection: $secondary) {
                    Text("None").tag("")
                    if primary != "uk" { Text("Українська").tag("uk") }
                    if primary != "ru" { Text("Русский").tag("ru") }
                }
            }

            Section("Dictionaries") {
                DictionaryPackView()
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Double-tap Shift flips selected text.", systemImage: "1.circle")
                    Label("Triple-tap Shift uses the secondary language.", systemImage: "2.circle")
                    Label("Press both Shift keys to pause or resume.", systemImage: "pause.circle")
                }
                .font(.callout)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DictionaryPackView: View {
    private enum InstallState: Equatable {
        case idle
        case installing
        case installed(String)
        case failed(String)
    }

    @State private var stats = DictionaryManager.stats()
    @State private var state: InstallState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                dictionaryRow("English", layout: .en)
                dictionaryRow("Українська", layout: .uk)
                dictionaryRow("Русский", layout: .ru)
            }

            HStack {
                Button {
                    installExtendedPack()
                } label: {
                    Label(hasInstalledWords ? "Update extended dictionaries" : "Install extended dictionaries",
                          systemImage: hasInstalledWords ? "arrow.clockwise.circle" : "arrow.down.circle")
                }
                .disabled(isInstalling)

                Button("Reset") {
                    resetInstalledPack()
                }
                .disabled(isInstalling || !hasInstalledWords)

                Spacer()
            }
            .controlSize(.small)

            statusText
                .font(.caption)
                .foregroundColor(statusColor)
                .fixedSize(horizontal: false, vertical: true)

            Text("Uses \(DictionaryManager.extendedPackSource) (\(DictionaryManager.extendedPackLicense)). LangFlip keeps the most useful clean words for each language.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            refresh()
        }
    }

    private var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    private var hasInstalledWords: Bool {
        stats.values.contains { $0.installedCount > 0 }
    }

    @ViewBuilder
    private var statusText: some View {
        switch state {
        case .idle:
            if hasInstalledWords {
                Text("Extended dictionaries are active. You can update them anytime or reset to the smaller bundled set.")
            } else {
                Text("Bundled dictionaries work offline. Extended dictionaries improve auto-flip coverage.")
            }
        case .installing:
            Text("Downloading and cleaning dictionaries...")
        case .installed(let message):
            Text(message)
        case .failed(let reason):
            Text("Failed: \(reason)")
        }
    }

    private var statusColor: Color {
        switch state {
        case .installed:
            return .green
        case .failed:
            return .orange
        default:
            return .secondary
        }
    }

    private func dictionaryRow(_ title: String, layout: Layout) -> some View {
        let item = stats[layout] ?? .init(bundledCount: 0, installedCount: 0, effectiveCount: 0)
        return HStack {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(format(item.effectiveCount)) active words")
                    .foregroundColor(.secondary)
                if item.installedCount > 0 {
                    Text("extended pack installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private func installSummary(_ counts: [Layout: Int]) -> String {
        Layout.allCases
            .compactMap { layout in
                counts[layout].map { "\(layout.rawValue.uppercased()) \(format($0))" }
            }
            .joined(separator: ", ")
    }

    private func installExtendedPack() {
        state = .installing
        DictionaryManager.installExtendedFrequencyPack { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let counts):
                    refresh()
                    let summary = installSummary(counts)
                    state = .installed("Installed extended dictionaries: \(summary). Auto-flip reloaded.")
                case .failure(let error):
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func resetInstalledPack() {
        do {
            try DictionaryManager.resetInstalledDictionaries()
            refresh()
            state = .installed("Removed installed dictionaries. Bundled dictionaries are active again.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func refresh() {
        stats = DictionaryManager.stats()
    }

    private func format(_ value: Int) -> String {
        Self.formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

// MARK: - Behavior

private struct BehaviorTab: View {
    @AppStorage("lf.autoFlip") private var autoFlip = true
    @AppStorage("lf.doubleCapsFix") private var doubleCapsFix = true
    @AppStorage("lf.crossLayoutFix") private var crossLayoutFix = true
    @AppStorage("lf.suppressInFullscreen") private var suppressInFullscreen = false
    @AppStorage("lf.showOverlay") private var showOverlay = true
    @AppStorage("lf.hotkeyPreset") private var hotkeyPreset = HotkeyPreset.doubleShift.rawValue
    @AppStorage("lf.fixLastSentenceOnSingleShift") private var fixLastSentenceOnSingleShift = true
    @AppStorage("lf.flipLastWordsOnDoubleShift") private var flipLastWordsOnDoubleShift = true

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: $hotkeyPreset) {
                    ForEach(HotkeyPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset.rawValue)
                    }
                }
                helpText("This gesture flips selected text between keyboard layouts. An experimental fallback can also try the last words before the cursor. Pressing both Shift keys still pauses or resumes LangFlip.")
            }
            Section {
                Toggle("Auto-flip at word end", isOn: $autoFlip)
                helpText("After Space or punctuation, LangFlip can fix a word that was typed in the wrong layout. Press Backspace right away to undo and remember an exception.")
            }
            Section("No-selection actions") {
                Toggle("Single Shift fixes last sentence", isOn: $fixLastSentenceOnSingleShift)
                Toggle("Double Shift flips last words", isOn: $flipLastWordsOnDoubleShift)
                helpText("When no text is selected, LangFlip reads the focused text field through Accessibility and rewrites only the text before the cursor. Turn this off if a specific app behaves unpredictably.")
            }
            Section {
                Toggle("Fix sticky-shift typos (WOrld → World)", isOn: $doubleCapsFix)
                helpText("Fixes accidental double-capital starts when the corrected word is clearly safe.")
            }
            Section {
                Toggle("Fix UK ↔ RU letter slips (ы ↔ і, э ↔ є)", isOn: $crossLayoutFix)
                helpText("Fixes common Ukrainian/Russian letter slips when the corrected word is in the target dictionary.")
            }
            Section {
                HStack {
                    Toggle("Show flip overlay", isOn: $showOverlay)
                    Spacer()
                    Button("Preview") {
                        // Force the overlay to play even when the user has
                        // it toggled off, so they can see what they'd be
                        // opting into before flipping the switch.
                        let wasOn = Settings.shared.showOverlay
                        Settings.shared.showOverlay = true
                        FlipOverlay.shared.show()
                        if !wasOn {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                Settings.shared.showOverlay = false
                            }
                        }
                    }
                    .controlSize(.small)
                }
                helpText("Shows a small visual confirmation whenever LangFlip rewrites text.")
            }
            Section {
                Toggle("Pause auto-flip in fullscreen apps", isOn: $suppressInFullscreen)
                helpText("Useful for games, video players, and other fullscreen apps where automatic changes may be distracting.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Models (AI)

private struct ModelsTab: View {
    private let releaseAIModes: [AIMode] = [.off, .appleFoundation, .ollama, .openai]

    @AppStorage("lf.aiMode") private var aiMode = AIMode.off.rawValue
    @AppStorage("lf.grammarCheckOnSingleShift") private var grammarOnSingleShift = true
    @AppStorage("lf.translationHotkeyEnabled") private var translationHotkeyEnabled = false
    @AppStorage("lf.screenTextCaptureHotkeyEnabled") private var screenTextCaptureHotkeyEnabled = true
    @AppStorage("lf.translationTarget") private var translationTarget = Layout.en.rawValue
    @AppStorage("lf.ollamaModel") private var ollamaModel = "qwen3.5:4b"
    @AppStorage("lf.cloudProvider") private var cloudProvider = AICloudProvider.openRouter.rawValue
    @AppStorage("lf.openaiModel") private var openaiModel = "gpt-5-nano"
    @AppStorage("lf.openaiBaseURL") private var openaiBaseURL = "https://api.openai.com/v1"

    @State private var aiReadyForHotkeys = false

    /// API key kept in Keychain (NOT @AppStorage). Mirror it through
    /// @State so SwiftUI re-renders the SecureField properly. We
    /// write back on commit via .onSubmit / .onChange.
    @State private var openaiKeyDraft: String = KeychainStore.getString(account: KeychainStore.openAIAPIKey) ?? ""

    var body: some View {
        Form {
            Section("Mode") {
                Picker("AI assistant", selection: $aiMode) {
                    ForEach(releaseAIModes) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                    helpText("AI is optional. Ollama with Qwen 3.5 4B is the recommended local setup for grammar fixes and screen text capture.")
            }

            // Backend-specific config sits directly under Mode — that's
            // where the eye lands after switching modes. Burying these
            // blocks at the bottom of the form (where they were
            // initially placed) made it easy to pick e.g. Ollama and
            // never realize a model selection was needed too.
            if AIMode(rawValue: aiMode) == .ollama {
                Section("Ollama") {
                    OllamaModelPicker(
                        selectedModel: $ollamaModel,
                        onSelectedModelAvailabilityChanged: { ready in
                            syncAIHotkeyAvailability(assistantReady: ready)
                        }
                    )
                    helpText("Use a model already installed in Ollama, or download one here. Local AI stays on this Mac.")
                }
            }

            if AIMode(rawValue: aiMode) == .openai {
                Section("Cloud provider") {
                    Picker("Provider", selection: $cloudProvider) {
                        ForEach(AICloudProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .onChange(of: cloudProvider) { raw in
                        guard let provider = AICloudProvider(rawValue: raw) else { return }
                        if provider != .custom {
                            openaiBaseURL = provider.defaultBaseURL
                        }
                        if openaiModel.isEmpty || openaiModel == "gpt-5-nano" || openaiModel == "openrouter/auto" {
                            openaiModel = provider.defaultModel
                        }
                    }

                    SecureField(apiKeyPlaceholder, text: $openaiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: openaiKeyDraft) { newValue in
                            KeychainStore.setString(newValue, account: KeychainStore.openAIAPIKey)
                        }

                    if AICloudProvider(rawValue: cloudProvider) == .openRouter {
                        OpenRouterModelPicker(selectedModel: $openaiModel)
                    } else {
                        TextField("Model", text: $openaiModel)
                            .textFieldStyle(.roundedBorder)
                    }

                    if AICloudProvider(rawValue: cloudProvider) == .custom {
                        TextField("Base URL", text: $openaiBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    Link(cloudProviderLinkTitle, destination: cloudProviderLinkURL)

                    helpText(cloudHelpText)
                }
                .onAppear {
                    applyCloudProviderDefaultsIfNeeded()
                }
            }

            if AIMode(rawValue: aiMode) != .off {
                Section("Test") {
                    AIModelTestView()
                    if AIMode(rawValue: aiMode) == .ollama {
                        Divider()
                        AIOCRTestView()
                    }
                }
            }

            Section("Features") {
                Toggle("Fix selected text with single Shift", isOn: Binding(
                    get: { aiReadyForHotkeys && grammarOnSingleShift },
                    set: { grammarOnSingleShift = $0 }
                ))
                .disabled(!aiReadyForHotkeys)
                helpText(aiReadyForHotkeys
                         ? "A single clean Shift tap sends the selected text to the active AI model for typo, punctuation, and grammar cleanup. The experimental Behavior toggle can also try the last sentence before the cursor."
                         : "Install and select a local model to enable this shortcut.")
            }

            Section("Translate selection") {
                Picker("Default target", selection: $translationTarget) {
                    ForEach(Layout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout.rawValue)
                    }
                }
                helpText("Used by the menu bar Translate action and the optional Shift+Space hotkey.")

                Toggle("Translate with Shift+Space", isOn: Binding(
                    get: { aiReadyForHotkeys && translationHotkeyEnabled },
                    set: { translationHotkeyEnabled = $0 }
                ))
                .disabled(!aiReadyForHotkeys)
                helpText(aiReadyForHotkeys
                         ? "When AI is on, Shift+Space translates the current selection into the default target language."
                         : "Install and select a local model to enable this shortcut.")
            }

            if AIMode(rawValue: aiMode) == .ollama {
                Section("Screen text capture") {
                    Toggle("Capture text with Shift+Command+S", isOn: $screenTextCaptureHotkeyEnabled)
                    helpText("Select a screen region and copy recognized text to the clipboard. Requires a vision-capable Ollama model.")
                }
            }

            Section("Privacy") {
                Text(privacyDisclosure)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if aiMode == AIMode.bundledModel.rawValue {
                aiMode = AIMode.ollama.rawValue
            }
            refreshAIHotkeyAvailability()
        }
        .onChange(of: aiMode) { _ in
            refreshAIHotkeyAvailability()
        }
        .onChange(of: ollamaModel) { _ in
            refreshAIHotkeyAvailability()
        }
    }

    @ViewBuilder
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Disclosure copy that matches the chosen AI backend.
    private var privacyDisclosure: String {
        let mode = AIMode(rawValue: aiMode) ?? .off
        switch mode {
        case .off:
            return "AI is off. Layout correction runs locally on your Mac."
        case .appleFoundation:
            return "Apple Intelligence runs on-device when available. LangFlip does not send text to its own servers."
        case .ollama:
            return "Ollama mode sends selected text only to the local Ollama app on this Mac."
        case .bundledModel:
            return "Bundled MLX models are not part of this release. Use Ollama with Qwen 2.5 for local grammar fixes."
        case .openai:
            return "Cloud mode sends only the text or image you explicitly process to the selected provider. Your API key is stored in macOS Keychain. Layout correction still runs locally."
        }
    }

    private var selectedCloudProvider: AICloudProvider {
        AICloudProvider(rawValue: cloudProvider) ?? .openRouter
    }

    private var apiKeyPlaceholder: String {
        switch selectedCloudProvider {
        case .openRouter: return "OpenRouter API key"
        case .openAI:     return "OpenAI API key (sk-...)"
        case .custom:     return "API key"
        }
    }

    private var cloudProviderLinkTitle: String {
        switch selectedCloudProvider {
        case .openRouter: return "Open OpenRouter API keys..."
        case .openAI:     return "Open OpenAI API keys..."
        case .custom:     return "Open provider dashboard..."
        }
    }

    private var cloudProviderLinkURL: URL {
        switch selectedCloudProvider {
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")!
        case .openAI:     return URL(string: "https://platform.openai.com/api-keys")!
        case .custom:     return URL(string: "https://openrouter.ai/settings/keys")!
        }
    }

    private var cloudHelpText: String {
        switch selectedCloudProvider {
        case .openRouter:
            return "OpenRouter gives access to many models with one API key. Free models are shown first, followed by low-cost text models."
        case .openAI:
            return "Use your OpenAI API key directly. The key is stored in macOS Keychain."
        case .custom:
            return "Use any OpenAI-compatible provider by entering its base URL and model name."
        }
    }

    private func applyCloudProviderDefaultsIfNeeded() {
        let provider = selectedCloudProvider
        guard provider != .custom else { return }
        if openaiBaseURL.isEmpty ||
           (provider == .openRouter && openaiBaseURL == AICloudProvider.openAI.defaultBaseURL) ||
           (provider == .openAI && openaiBaseURL == AICloudProvider.openRouter.defaultBaseURL) {
            openaiBaseURL = provider.defaultBaseURL
        }
        if openaiModel.isEmpty ||
           (provider == .openRouter && openaiModel == AICloudProvider.openAI.defaultModel) ||
           (provider == .openAI && openaiModel == AICloudProvider.openRouter.defaultModel) {
            openaiModel = provider.defaultModel
        }
    }

    private func refreshAIHotkeyAvailability() {
        Task {
            let ready = await Task.detached(priority: .userInitiated) {
                AIAssistantManager.shared.isReady
            }.value
            await MainActor.run {
                syncAIHotkeyAvailability(assistantReady: ready)
            }
        }
    }

    private func syncAIHotkeyAvailability(assistantReady: Bool) {
        aiReadyForHotkeys = assistantReady
        Settings.shared.applyRecommendedAIHotkeyDefaults(assistantReady: assistantReady)
        grammarOnSingleShift = Settings.shared.grammarCheckOnSingleShift
        if Settings.shared.hasStoredTranslationHotkeyPreference {
            translationHotkeyEnabled = Settings.shared.translationHotkeyEnabled
        }
    }
}

private enum AICloudProvider: String, CaseIterable, Identifiable {
    case openRouter
    case openAI
    case custom

    var id: Self { self }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAI:     return "OpenAI direct"
        case .custom:     return "Custom compatible"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI:     return "https://api.openai.com/v1"
        case .custom:     return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: return "openrouter/auto"
        case .openAI:     return "gpt-5-nano"
        case .custom:     return ""
        }
    }
}

private struct AIModelTestView: View {
    private enum TestState: Equatable {
        case idle
        case running(Date)
        case success(output: String, seconds: TimeInterval)
        case unchanged(seconds: TimeInterval)
        case failed(String)
    }

    private let sample = "World is wery gandgerous plsce to leave in!"

    @State private var state: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sample)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    statusText
                        .font(.caption)
                        .foregroundColor(statusColor)
                }
                Spacer()
                Button {
                    runTest()
                } label: {
                    Image(systemName: isRunning ? "hourglass" : "play.fill")
                }
                .help("Run grammar test with the selected AI model")
                .disabled(isRunning)
            }

            if let output {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    @ViewBuilder
    private var statusText: some View {
        switch state {
        case .idle:
            Text("Checks that the selected AI model can clean up text.")
        case .running:
            Text("Running test...")
        case .success(_, let seconds):
            Text(String(format: "Model replied in %.1f s.", seconds))
        case .unchanged(let seconds):
            Text(String(format: "Model replied in %.1f s and returned unchanged text.", seconds))
        case .failed(let reason):
            Text("Failed: \(reason)")
        }
    }

    private var statusColor: Color {
        switch state {
        case .failed:
            return .orange
        case .success:
            return .green
        default:
            return .secondary
        }
    }

    private var output: String? {
        switch state {
        case .success(let output, _):
            return output
        default:
            return nil
        }
    }

    private func runTest() {
        let started = Date()
        state = .running(started)

        let request = AIFixRequest(
            text: sample,
            activeLayout: .en
        )
        AIAssistantManager.shared.current.fixSelection(request) { result in
            DispatchQueue.main.async {
                let seconds = Date().timeIntervalSince(started)
                switch result {
                case .fixed(let output):
                    state = .success(output: output, seconds: seconds)
                case .unchanged:
                    state = .unchanged(seconds: seconds)
                case .unsupported:
                    state = .failed("This AI mode does not support text fixes")
                case .failed(let reason):
                    state = .failed(reason)
                }
            }
        }
    }
}

private struct AIOCRTestView: View {
    private enum TestState: Equatable {
        case idle
        case running(Date)
        case success(output: String, seconds: TimeInterval)
        case failed(String)
    }

    private let sample = "LangFlip OCR test"

    @State private var state: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sample)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    statusText
                        .font(.caption)
                        .foregroundColor(statusColor)
                }
                Spacer()
                Button {
                    runTest()
                } label: {
                    Image(systemName: isRunning ? "hourglass" : "viewfinder")
                }
                .help("Run OCR test with the selected Ollama model")
                .disabled(isRunning)
            }

            if let output {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    @ViewBuilder
    private var statusText: some View {
        switch state {
        case .idle:
            Text("Checks that the selected Ollama model can read text from images.")
        case .running:
            Text("Running OCR test...")
        case .success(_, let seconds):
            Text(String(format: "OCR replied in %.1f s.", seconds))
        case .failed(let reason):
            Text("Failed: \(reason)")
        }
    }

    private var statusColor: Color {
        switch state {
        case .failed:
            return .orange
        case .success:
            return .green
        default:
            return .secondary
        }
    }

    private var output: String? {
        switch state {
        case .success(let output, _):
            return output
        default:
            return nil
        }
    }

    private func runTest() {
        guard let imageBase64 = makeOCRSampleImageBase64() else {
            state = .failed("could not create test image")
            return
        }

        let started = Date()
        state = .running(started)

        AIAssistantManager.shared.current.extractTextFromImage(
            AIOcrRequest(imageBase64: imageBase64)
        ) { result in
            DispatchQueue.main.async {
                let seconds = Date().timeIntervalSince(started)
                switch result {
                case .extracted(let output):
                    state = .success(
                        output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                        seconds: seconds
                    )
                case .unsupported:
                    state = .failed("selected model does not support image input")
                case .failed(let reason):
                    state = .failed(reason)
                }
            }
        }
    }

    private func makeOCRSampleImageBase64() -> String? {
        let image = NSImage(size: NSSize(width: 720, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 720, height: 180).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        sample.draw(
            in: NSRect(x: 36, y: 72, width: 650, height: 60),
            withAttributes: attrs
        )
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }
        return png.base64EncodedString()
    }
}

private struct OllamaModelPicker: View {
    private enum InstallState: Equatable {
        case idle
        case installing
        case finished
        case failed
    }

    private let grammarModel = "qwen2.5"
    private let visionModel = "qwen3.5:4b"

    @Binding var selectedModel: String
    let onSelectedModelAvailabilityChanged: (Bool) -> Void

    @State private var installedModels: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var installState: InstallState = .idle
    @State private var installingModel: String?
    @State private var installMessage: String?

    private var dropdownModels: [String] {
        var models: [String] = []
        for model in [selectedModel] + installedModels + [grammarModel, visionModel] {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = canonicalModelTag(trimmed)
            let alreadyIncluded = models.contains { canonicalModelTag($0) == canonical }
            if !trimmed.isEmpty && !alreadyIncluded {
                models.append(trimmed)
            }
        }
        return models
    }

    private var isInstalling: Bool {
        installingModel != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(dropdownModels, id: \.self) { model in
                        Text(label(for: model)).tag(model)
                    }
                }

                Button {
                    Task { await refreshInstalledModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh installed Ollama models")
                .disabled(isLoading)

                Button {
                    openOllamaOrDownloadPage()
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await refreshInstalledModels()
                    }
                } label: {
                    Image(systemName: "play.circle")
                }
                .help("Open Ollama")
            }

            HStack(spacing: 8) {
                Button(installButtonTitle(for: grammarModel)) {
                    Task { await installModel(grammarModel) }
                }
                .disabled(isModelInstalled(grammarModel) || isInstalling)

                Button(installButtonTitle(for: visionModel)) {
                    Task { await installModel(visionModel) }
                }
                .disabled(isModelInstalled(visionModel) || isInstalling)

                if isModelInstalled(grammarModel), isModelInstalled(visionModel) {
                    Text("Ready for text fixes and screen capture.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if isModelInstalled(grammarModel) {
                    Text("Ready for local text fixes.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if isModelInstalled(visionModel) {
                    Text("Ready for local text fixes and OCR.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            TextField("Custom model tag", text: $selectedModel)
                .textFieldStyle(.roundedBorder)

            if isLoading {
                Text("Refreshing Ollama models...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let installMessage {
                Text(installMessage)
                    .font(.caption)
                    .foregroundColor(installState == .failed ? .red : .secondary)
            } else if !installedModels.isEmpty {
                Text("Found \(installedModels.count) installed model\(installedModels.count == 1 ? "" : "s").")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await refreshInstalledModels()
        }
        .onChange(of: selectedModel) { _ in
            notifySelectedModelAvailability()
        }
    }

    private func installButtonTitle(for model: String) -> String {
        if isModelInstalled(model) {
            return "\(displayName(for: model)) installed"
        }
        if installingModel == model {
            return "Downloading \(displayName(for: model))..."
        }
        switch installState {
        case .failed: return "Try \(displayName(for: model)) again"
        case .idle, .installing, .finished: return "Download \(displayName(for: model))"
        }
    }

    private func label(for model: String) -> String {
        if canonicalModelTag(model) == grammarModel {
            return "Qwen 2.5 (recommended)"
        }
        if canonicalModelTag(model) == visionModel {
            return "Qwen 3.5 4B (vision)"
        }
        return model
    }

    private func displayName(for model: String) -> String {
        if canonicalModelTag(model) == grammarModel {
            return "Qwen 2.5"
        }
        if canonicalModelTag(model) == visionModel {
            return "Qwen 3.5 4B"
        }
        return model
    }

    private func isModelInstalled(_ model: String) -> Bool {
        let canonical = canonicalModelTag(model)
        return installedModels.contains { canonicalModelTag($0) == canonical }
    }

    private func notifySelectedModelAvailability() {
        onSelectedModelAvailabilityChanged(isModelInstalled(selectedModel))
    }

    private func canonicalModelTag(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(":latest") {
            return String(trimmed.dropLast(":latest".count))
        }
        return trimmed
    }

    @MainActor
    private func installModel(_ model: String) async {
        selectedModel = model
        installState = .installing
        installingModel = model
        loadError = nil
        installMessage = "Downloading \(displayName(for: model)). This can take a few minutes."
        defer { installingModel = nil }
        openOllamaOrDownloadPage()

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let failure = await Self.pullOllamaModel(model) {
            installState = .failed
            installMessage = failure
        } else {
            installState = .finished
            installMessage = "\(displayName(for: model)) is ready."
            await refreshInstalledModels()
        }
    }

    @MainActor
    private func refreshInstalledModels() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                loadError = "Ollama is reachable, but returned an unexpected response."
                installedModels = []
                return
            }
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            installedModels = decoded.models.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            notifySelectedModelAvailability()
        } catch {
            loadError = "Ollama is not running. Open Ollama, then refresh."
            installedModels = []
            notifySelectedModelAvailability()
        }
    }

    private func openOllamaOrDownloadPage() {
        let appURL = URL(fileURLWithPath: "/Applications/Ollama.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }

        if let downloadURL = URL(string: "https://ollama.com/download/mac") {
            NSWorkspace.shared.open(downloadURL)
        }
    }

    nonisolated private static func pullOllamaModel(_ model: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let executableURL = ollamaExecutableURL() else {
            return "Ollama was not found. Install Ollama, open it once, then try again."
            }

            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["pull", model]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return "Could not open Ollama: \(error.localizedDescription)"
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .suffix(2)
                .joined(separator: " ")

            guard process.terminationStatus == 0 else {
                let detail = output?.isEmpty == false ? " \(output!)" : ""
                return "Ollama could not download \(model).\(detail)"
            }
            return nil
        }.value
    }

    nonisolated private static func ollamaExecutableURL() -> URL? {
        let candidates = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
}

private struct OpenRouterModelPicker: View {
    @Binding var selectedModel: String

    @State private var models: [OpenRouterModel] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var dropdownModels: [OpenRouterModel] {
        var result: [OpenRouterModel] = [
            OpenRouterModel(
                id: "openrouter/auto",
                name: "OpenRouter Auto",
                pricing: .init(prompt: nil, completion: nil),
                architecture: nil
            )
        ]

        for model in models {
            if !result.contains(where: { $0.id == model.id }) {
                result.append(model)
            }
        }

        if !selectedModel.isEmpty && !result.contains(where: { $0.id == selectedModel }) {
            result.insert(
                OpenRouterModel(
                    id: selectedModel,
                    name: selectedModel,
                    pricing: .init(prompt: nil, completion: nil),
                    architecture: nil
                ),
                at: 0
            )
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(dropdownModels) { model in
                        Text(label(for: model)).tag(model.id)
                    }
                }

                Button {
                    Task { await refreshModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh OpenRouter models")
                .disabled(isLoading)
            }

            TextField("Custom model id", text: $selectedModel)
                .textFieldStyle(.roundedBorder)

            if isLoading {
                Text("Refreshing OpenRouter models...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !models.isEmpty {
                Text("Free models are listed first, followed by low-cost text models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await refreshModels()
        }
    }

    private func label(for model: OpenRouterModel) -> String {
        let price = model.priceLabel
        if price.isEmpty {
            return "\(model.name) - \(model.id)"
        }
        return "\(model.name) - \(price)"
    }

    @MainActor
    private func refreshModels() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        guard let url = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                loadError = "OpenRouter returned an unexpected response."
                models = []
                return
            }
            let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
            models = decoded.data
                .filter { $0.supportsTextOutput }
                .sorted(by: OpenRouterModel.isBetterForProofreading)
                .prefix(80)
                .map { $0 }
        } catch {
            loadError = "Could not load OpenRouter models. Check your internet connection."
            models = []
        }
    }
}

private struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterModel]
}

private struct OpenRouterModel: Decodable, Identifiable {
    struct Pricing: Decodable {
        let prompt: String?
        let completion: String?
    }

    struct Architecture: Decodable {
        let outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case outputModalities = "output_modalities"
        }
    }

    let id: String
    let name: String
    let pricing: Pricing
    let architecture: Architecture?

    var supportsTextOutput: Bool {
        architecture?.outputModalities?.contains("text") ?? true
    }

    var promptPrice: Double {
        Double(pricing.prompt ?? "") ?? .infinity
    }

    var completionPrice: Double {
        Double(pricing.completion ?? "") ?? .infinity
    }

    var isFree: Bool {
        promptPrice == 0 && completionPrice == 0
    }

    var priceLabel: String {
        if id == "openrouter/auto" { return "automatic routing" }
        if isFree { return "free" }
        guard promptPrice.isFinite, completionPrice.isFinite else { return "" }
        let input = promptPrice * 1_000_000
        let output = completionPrice * 1_000_000
        return String(format: "$%.2f / $%.2f per 1M", input, output)
    }

    static func isBetterForProofreading(_ lhs: OpenRouterModel, _ rhs: OpenRouterModel) -> Bool {
        if lhs.isFree != rhs.isFree { return lhs.isFree }
        let lhsCost = lhs.promptPrice + lhs.completionPrice
        let rhsCost = rhs.promptPrice + rhs.completionPrice
        if lhsCost != rhsCost { return lhsCost < rhsCost }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Apps

private struct AppsTab: View {
    @State private var userBlocked = Array(Settings.shared.userBlacklist).sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App exclusions")
                .font(.headline)
            if userBlocked.isEmpty {
                Text("No apps are excluded. LangFlip automatically avoids sensitive app types like terminals and password managers.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            } else {
                List {
                    ForEach(userBlocked, id: \.self) { bundleID in
                        HStack {
                            Text(bundleID).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("Remove") { remove(bundleID) }
                                .controlSize(.small)
                        }
                    }
                }
                .frame(minHeight: 100, maxHeight: 200)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Built-in blocks")
                    .font(.headline)
                Text("Auto-flip stays off in apps where automatic rewriting could damage commands or credentials.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Terminals: Terminal, iTerm2, Warp, Ghostty, Alacritty, Kitty, Hyper, Tabby")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Password managers: 1Password, LastPass, Dashlane, Bitwarden, KeePassXC, and similar apps.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func remove(_ bundleID: String) {
        var set = Settings.shared.userBlacklist
        set.remove(bundleID)
        Settings.shared.userBlacklist = set
        userBlocked = Array(set).sorted()
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("LangFlip")
                .font(.system(size: 24, weight: .semibold))
            Text("Version \(version)")
                .font(.callout)
                .foregroundColor(.secondary)

            Text("A macOS writing assistant for wrong-layout fixes, selected-text cleanup, translation, and screen text capture.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com/MikeKorotych/lang-flip")!)
                Link("MIT License", destination: URL(string: "https://github.com/MikeKorotych/lang-flip/blob/main/LICENSE")!)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
