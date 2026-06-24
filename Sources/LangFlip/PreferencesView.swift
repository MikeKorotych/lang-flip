import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers
import Carbon.HIToolbox

// The settings tab views below were migrated out of a standalone Preferences
// window into the main window's Settings section (see SettingsHostView in
// MainWindow.swift). They keep their grouped-Form styling for now; restyling to
// the Flow aesthetic happens section by section.

// MARK: - General

struct GeneralTab: View {
    @AppStorage("lf.enabled") private var enabled = true
    @AppStorage("lf.soundEnabled") private var soundEnabled = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var permissions = PermissionStatus.current()
    @State private var hasScreenRecording = PermissionStatus.hasScreenRecording()
    @State private var microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FlowSettingsGroup {
                    FlowToggleRow(title: "LangFlip enabled", isOn: $enabled)
                    FlowToggleRow(title: "Launch at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            launchAtLogin = newValue
                            LaunchAtLogin.set(newValue)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    ))
                    FlowToggleRow(title: "Sound feedback", isOn: $soundEnabled)
                }

                FlowSettingsGroup("Permissions") {
                    FlowPermissionRow(title: "Accessibility",
                                      granted: permissions.accessibility,
                                      action: PermissionStatus.openAccessibilityPane)
                    FlowPermissionRow(title: "Input Monitoring",
                                      granted: permissions.inputMonitoring,
                                      action: PermissionStatus.openInputMonitoringPane)
                }

                FlowSettingsGroup("Optional permissions") {
                    FlowPermissionRow(title: "Screen Recording",
                                      granted: hasScreenRecording,
                                      detail: "Needed for Copy text from screenshot.",
                                      action: PermissionStatus.openScreenRecordingPane)
                    FlowPermissionRow(title: "Microphone",
                                      granted: microphoneStatus == .authorized,
                                      detail: "Needed only for speech-to-text dictation. Install and configure voice features in the Voice tab.",
                                      action: openMicrophonePermission)
                }

                FlowCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        gestureHint("1.circle", "Double-tap Shift flips selected text.")
                        gestureHint("2.circle", "Triple-tap Shift uses the secondary language.")
                        gestureHint("pause.circle", "Press both Shift keys to pause or resume.")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onReceive(timer) { _ in
            permissions = PermissionStatus.current()
            hasScreenRecording = PermissionStatus.hasScreenRecording()
            microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()
            launchAtLogin = LaunchAtLogin.isEnabled
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

    private func openMicrophonePermission() {
        switch microphoneStatus {
        case .notDetermined:
            PermissionStatus.requestMicrophone { _ in
                microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()
            }
        case .authorized, .denied, .restricted:
            PermissionStatus.openMicrophonePane()
        @unknown default:
            PermissionStatus.openMicrophonePane()
        }
    }
}

// MARK: - Voice

struct VoiceTab: View {
    @AppStorage("lf.ttsBackend") private var ttsBackend = TextToSpeechBackend.system.rawValue
    @AppStorage("lf.speechVoiceIdentifier") private var speechVoiceIdentifier = ""
    @AppStorage("lf.speechRate") private var speechRate = 190.0
    @AppStorage("lf.cloudTTSBaseURL") private var cloudTTSBaseURL = "https://openrouter.ai/api/v1"
    @AppStorage("lf.cloudTTSModel") private var cloudTTSModel = "openai/gpt-4o-mini-tts-2025-12-15"
    @AppStorage("lf.cloudTTSVoice") private var cloudTTSVoice = "nova"
    @AppStorage("lf.cloudTTSSpeed") private var cloudTTSSpeed = 1.0
    @AppStorage("lf.cloudTTSInstructions") private var cloudTTSInstructions = ""
    @AppStorage("lf.omniVoiceLanguage") private var omniVoiceLanguage = OmniVoiceLanguage.auto.rawValue
    @AppStorage("lf.omniVoiceGender") private var omniVoiceGender = OmniVoiceGenderStyle.none.rawValue
    @AppStorage("lf.omniVoiceAge") private var omniVoiceAge = OmniVoiceAgeStyle.none.rawValue
    @AppStorage("lf.omniVoicePitch") private var omniVoicePitch = OmniVoicePitchStyle.none.rawValue
    @AppStorage("lf.omniVoiceAccent") private var omniVoiceAccent = OmniVoiceAccentStyle.none.rawValue
    @AppStorage("lf.omniVoiceWhisper") private var omniVoiceWhisper = false
    @AppStorage("lf.omniVoiceSpeed") private var omniVoiceSpeed = 1.0
    @AppStorage("lf.omniVoiceDuration") private var omniVoiceDuration = 0.0
    @AppStorage("lf.omniVoiceSentencePause") private var omniVoiceSentencePause = 0.35
    @AppStorage("lf.omniVoiceLinePause") private var omniVoiceLinePause = 0.75
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
    @AppStorage("lf.readSelectionHotkeyPreset") private var readSelectionHotkeyPreset = GlobalShortcutPreset.controlOptionX.rawValue
    @AppStorage("lf.readSelectionHotkeyCustom") private var readSelectionHotkeyCustom = ""
    @AppStorage("lf.whisperModelPath") private var whisperModelPath = ""
    @AppStorage("lf.whisperLanguage") private var whisperLanguage = "auto"
    @AppStorage("lf.dictationPushToTalkEnabled") private var dictationPushToTalkEnabled = false
    @AppStorage("lf.dictationPushToTalkShortcut") private var dictationPushToTalkShortcut = DictationPushToTalkShortcut.anyShift.rawValue
    @AppStorage("lf.dictationHandsFreeEnabled") private var dictationHandsFreeEnabled = false
    @AppStorage("lf.dictationHandsFreeShortcut") private var dictationHandsFreeShortcut = DictationHandsFreeShortcut.fnOption.rawValue
    @AppStorage("lf.dictationTranscriptionBackend") private var dictationTranscriptionBackend = DictationTranscriptionBackend.localWhisper.rawValue
    @AppStorage("lf.cloudSTTBaseURL") private var cloudSTTBaseURL = "https://openrouter.ai/api/v1"
    @AppStorage("lf.cloudSTTModel") private var cloudSTTModel = "nvidia/parakeet-tdt-0.6b-v3"

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
    @State private var cloudTTSKeyDraft: String = KeychainStore.getString(account: KeychainStore.openAIAPIKey) ?? ""
    @State private var isGeneratingCloudTTS = false
    @State private var cloudTTSOutputURL = CloudSpeechSynthesizer.shared.lastOutputURL
    @State private var cloudTTSMessage: String?

    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    @State private var voiceTab: VoiceSubTab = .tts
    enum VoiceSubTab: String, CaseIterable, Identifiable {
        case tts = "Text to Speech", dictation = "Dictation"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $voiceTab) {
                ForEach(VoiceSubTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Form {
                if voiceTab == .tts {
            Section("Text to speech") {
                Picker(selection: $ttsBackend) {
                    ForEach(TextToSpeechBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend.rawValue)
                    }
                } label: {
                    settingLabel("Backend", help: "System voices start instantly. OmniVoice runs locally and gives more voice controls, but takes longer to generate audio.")
                }

                if activeTTSBackend == .system {
                    Picker(selection: $speechVoiceIdentifier) {
                        Text("System default").tag("")
                        ForEach(voices, id: \.self) { voice in
                            Text(SpeechReader.displayName(for: voice)).tag(voice)
                        }
                    } label: {
                        settingLabel("Voice", help: "Pick which macOS voice reads selected text aloud.")
                    }
                    .onChange(of: speechVoiceIdentifier) { _ in
                        SpeechReader.shared.applySettings()
                    }

                    HStack {
                        settingLabel("Speed", help: "Move right to read faster, left to read slower.")
                        Slider(value: $speechRate, in: 120...260, step: 5)
                            .onChange(of: speechRate) { _ in
                                SpeechReader.shared.applySettings()
                            }
                        Text("\(Int(speechRate))")
                            .foregroundColor(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                } else if activeTTSBackend == .cloud {
                    SecureField("OpenRouter or OpenAI API key", text: $cloudTTSKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: cloudTTSKeyDraft) { newValue in
                            KeychainStore.setString(newValue, account: KeychainStore.openAIAPIKey)
                        }
                    helpText("The key is stored in macOS Keychain. OpenRouter is recommended because it lets you switch TTS models without changing the app.")

                    HStack {
                        settingLabel("Base URL", help: "OpenRouter uses https://openrouter.ai/api/v1. OpenAI direct uses https://api.openai.com/v1.")
                        TextField("https://openrouter.ai/api/v1", text: $cloudTTSBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    if cloudTTSUsesOpenRouter {
                        OpenRouterSpeechModelPicker(selectedModel: $cloudTTSModel)
                            .onChange(of: cloudTTSModel) { _ in
                                syncCloudTTSVoiceForModel()
                            }
                    } else {
                        TextField("Model", text: $cloudTTSModel)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: cloudTTSModel) { _ in
                                syncCloudTTSVoiceForModel()
                            }
                    }

                    Picker(selection: $cloudTTSVoice) {
                        ForEach(cloudTTSVoiceOptions) { voice in
                            Text(voice.label).tag(voice.id)
                        }
                    } label: {
                        settingLabel("Voice", help: "Voice identifiers are model-specific. LangFlip shows known voices for the selected curated model.")
                    }

                    HStack {
                        settingLabel("Speed", help: "OpenAI TTS supports speed. Some OpenRouter providers silently ignore it.")
                        Slider(value: $cloudTTSSpeed, in: 0.5...1.5, step: 0.05)
                        Text(String(format: "%.2fx", cloudTTSSpeed))
                            .foregroundColor(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }

                    TextField("Optional voice instructions", text: $cloudTTSInstructions)
                        .textFieldStyle(.roundedBorder)
                        .help("Example: Warm, clear, natural pacing. For Gemini-style models, inline tags in the text may work better than instructions.")

                    if let cloudTTSMessage {
                        Text(cloudTTSMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let cloudTTSOutputURL {
                        HStack {
                            Text("Last cloud TTS output")
                            Spacer()
                            Text(cloudTTSOutputURL.lastPathComponent)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Button("Play") {
                                CloudSpeechSynthesizer.shared.play(cloudTTSOutputURL)
                            }
                            .controlSize(.small)
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([cloudTTSOutputURL])
                            }
                            .controlSize(.small)
                        }
                    }

                    helpText("Current practical default: OpenAI GPT-4o Mini TTS via OpenRouter for cost and compatibility. For richer multilingual or expressive output, try google/gemini-3.1-flash-tts-preview.")
                } else {
                    Picker(selection: $omniVoiceLanguage) {
                        ForEach(OmniVoiceLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    } label: {
                        settingLabel("Language", help: "Leave Auto for normal use. Choose a language manually if pronunciation sounds wrong.")
                    }

                    HStack {
                        settingLabel("OmniVoice", help: "Shows whether the local voice model is ready on this Mac.")
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
                        settingLabel("Voice", help: "Choose a more feminine or masculine voice character. Default lets the model decide.")
                    }

                    Picker(selection: $omniVoiceAge) {
                        ForEach(OmniVoiceAgeStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    } label: {
                        settingLabel("Age", help: "Changes the age character of the voice: younger, older, or neutral.")
                    }

                    Picker(selection: $omniVoicePitch) {
                        ForEach(OmniVoicePitchStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    } label: {
                        settingLabel("Pitch", help: "Move toward Low for a deeper voice, High for a brighter voice.")
                    }

                    Picker(selection: $omniVoiceAccent) {
                        ForEach(OmniVoiceAccentStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    } label: {
                        settingLabel("Accent", help: "Adds an accent flavor. It usually works best with English text.")
                    }

                    Toggle(isOn: $omniVoiceWhisper) {
                        settingLabel("Whispered voice", help: "Makes the voice sound quieter and breathier, like a whisper.")
                    }

                    Divider()

                    HStack {
                        settingLabel("Reference voice", help: "Optional voice sample. Add a short clean recording and OmniVoice will try to speak with a similar voice.")
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
                        .help("Optional: type what is said in the reference audio. This can make voice cloning more accurate.")

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            settingLabel("Speed", help: "Move right to speak faster, left to speak slower. Fixed Duration turns this off.")
                            Slider(value: $omniVoiceSpeed, in: 0.5...1.5, step: 0.05)
                            Text(String(format: "%.2fx", omniVoiceSpeed))
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                        .disabled(omniVoiceDuration > 0)

                        HStack {
                            settingLabel("Duration", help: "Keep Auto for natural timing. Set a number only when the audio must fit a fixed length.")
                            Slider(value: $omniVoiceDuration, in: 0...60, step: 0.5)
                            Text(omniVoiceDuration > 0 ? String(format: "%.1fs", omniVoiceDuration) : "Auto")
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            settingLabel("Sentence pause", help: "Adds a real pause after '.', '!', '?' and similar sentence endings. Increase it for jokes, stories, and dramatic reading.")
                            Slider(value: $omniVoiceSentencePause, in: 0...2, step: 0.05)
                            Text(String(format: "%.2fs", omniVoiceSentencePause))
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            settingLabel("Line pause", help: "Adds a longer pause after line breaks. Increase it when reading lists, poems, chat messages, or multi-line jokes.")
                            Slider(value: $omniVoiceLinePause, in: 0...3, step: 0.05)
                            Text(String(format: "%.2fs", omniVoiceLinePause))
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            settingLabel("Quality", help: "Move left for faster generation, right for better quality. 32 is a good everyday balance.")
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
                            settingLabel("Style strength", help: "Move right if the selected voice/style is too subtle. Move left if the result sounds forced or less natural.")
                            Slider(value: $omniVoiceGuidanceScale, in: 0...4, step: 0.1)
                            Text(String(format: "%.1f", omniVoiceGuidanceScale))
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }

                    DisclosureGroup("Advanced generation") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $omniVoiceDenoise) {
                                settingLabel("Cleaner voice", help: "Usually keep this on. Turn it off only if the voice starts sounding too processed.")
                            }
                            Toggle(isOn: $omniVoicePostprocessOutput) {
                                settingLabel("Trim awkward silence", help: "Usually keep this on. It removes overly long silent parts from the generated audio.")
                            }
                            advancedOmniVoiceSlider("Timing stability", value: $omniVoiceTShift, range: 0...2, step: 0.05, help: "Leave near the default unless speech timing sounds strange. Moving it can change rhythm and stability.")
                            advancedOmniVoiceSlider("Voice smoothness", value: $omniVoiceLayerPenaltyFactor, range: 0...10, step: 0.5, help: "Higher can make the voice more controlled. Lower can make it looser, but sometimes less stable.")
                            advancedOmniVoiceSlider("Rhythm variety", value: $omniVoicePositionTemperature, range: 0...10, step: 0.5, help: "Higher adds more variation to rhythm. Lower is more predictable.")
                            advancedOmniVoiceSlider("Voice variety", value: $omniVoiceClassTemperature, range: 0...2, step: 0.05, help: "0 is safest and most stable. Increase only if you want more variation and can accept occasional odd results.")
                            Button("Reset generation settings") {
                                Settings.shared.resetOmniVoiceGenerationSettings()
                                syncOmniVoiceGenerationSettingsFromDefaults()
                            }
                            .controlSize(.small)
                            .help("Restore speed, pauses, quality, and advanced generation settings to LangFlip defaults.")
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
                    Button(ttsSampleButtonTitle) {
                        readTTSSample()
                    }
                    .disabled(ttsSampleDisabled)

                    Button("Stop") {
                        SpeechReader.shared.stop()
                        OmniVoiceSynthesizer.shared.stop()
                        CloudSpeechSynthesizer.shared.stop()
                        isGeneratingOmniVoice = false
                        isGeneratingCloudTTS = false
                    }
                    Spacer()
                }
                .controlSize(.small)

                helpText("Use the menu bar action to read the current text selection aloud. System voices are instant; OmniVoice is local and heavier; Cloud TTS sends selected text to your chosen API provider.")
            }

            Section("Read aloud shortcut") {
                Toggle("Read selected text with \(readSelectionShortcutName)", isOn: $readSelectionHotkeyEnabled)
                helpText("Select text in any app and press \(readSelectionShortcutName). Change this shortcut in Hotkeys.")
            }
                } else {
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

                Toggle("Push-to-talk dictation", isOn: $dictationPushToTalkEnabled)
                helpText(dictationPushToTalkEnabled
                         ? "Hold \(dictationPushToTalkName) to record, then release to transcribe and insert text."
                         : "Push-to-talk dictation is off. Hands-free dictation can stay enabled below.")

                Toggle("Hands-free dictation", isOn: $dictationHandsFreeEnabled)
                helpText(dictationHandsFreeEnabled
                         ? "Press \(dictationHandsFreeName) once to start recording, then press it again to stop and transcribe."
                         : "Hands-free dictation is off. Push-to-talk can stay enabled above.")

                if dictationHandsFreeEnabled {
                    Picker("Hands-free toggle", selection: $dictationHandsFreeShortcut) {
                        ForEach(DictationHandsFreeShortcut.allCases) { shortcut in
                            Text(shortcut.displayName).tag(shortcut.rawValue)
                        }
                    }
                    helpText("Fn+Option works as a tap toggle: press and release once to start, then press and release again to stop.")
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

                Picker(selection: $dictationTranscriptionBackend) {
                    ForEach(DictationTranscriptionBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend.rawValue)
                    }
                } label: {
                    settingLabel("Transcription", help: "Local Whisper keeps audio on this Mac. Cloud STT sends only recorded dictation audio to your selected provider.")
                }

                if activeDictationBackend == .cloud {
                    SecureField("OpenRouter or OpenAI API key", text: $cloudTTSKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: cloudTTSKeyDraft) { newValue in
                            KeychainStore.setString(newValue, account: KeychainStore.openAIAPIKey)
                        }

                    HStack {
                        settingLabel("Base URL", help: "OpenRouter uses https://openrouter.ai/api/v1. Use a compatible endpoint only if it supports /audio/transcriptions.")
                        TextField("https://openrouter.ai/api/v1", text: $cloudSTTBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    OpenRouterTranscriptionModelPicker(selectedModel: $cloudSTTModel)
                    helpText("Best default: NVIDIA Parakeet TDT 0.6B v3 for very low cost and strong multilingual STT. Qwen3 ASR Flash is a good noisy/mixed-language fallback.")
                    helpText("Cloud STT always lets the provider auto-detect the spoken language from audio. LangFlip does not send the current keyboard layout or a language override.")
                } else {
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
                    .disabled(testTranscriptionDisabled)

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

                helpText(activeDictationBackend == .cloud
                         ? "Cloud STT transcribes the last recording here for testing. Dictation shortcuts can be changed in Hotkeys."
                         : "Whisper transcribes the last recording here for testing. Dictation shortcuts can be changed in Hotkeys.")
            }
                }
            }
        .formStyle(.grouped)
        .onAppear {
            voices = SpeechReader.availableVoices
            cloudTTSKeyDraft = KeychainStore.getString(account: KeychainStore.openAIAPIKey) ?? ""
            syncCloudTTSVoiceForModel()
            microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()
            refreshRecorderState()
            refreshOmniVoiceState()
            refreshCloudTTSState()
        }
        .onReceive(timer) { _ in
            microphoneStatus = PermissionStatus.microphoneAuthorizationStatus()
            refreshRecorderState()
            refreshOmniVoiceState()
            refreshCloudTTSState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .langFlipVoiceRecorderChanged)) { _ in
            refreshRecorderState()
        }
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

    private var activeDictationBackend: DictationTranscriptionBackend {
        DictationTranscriptionBackend(rawValue: dictationTranscriptionBackend) ?? .localWhisper
    }

    private var readSelectionShortcutName: String {
        GlobalShortcut.decode(readSelectionHotkeyCustom)?.displayName
            ?? (GlobalShortcutPreset(rawValue: readSelectionHotkeyPreset) ?? .controlOptionX).displayName
    }

    private var dictationPushToTalkName: String {
        (DictationPushToTalkShortcut(rawValue: dictationPushToTalkShortcut) ?? .anyShift).displayName
    }

    private var dictationHandsFreeName: String {
        (DictationHandsFreeShortcut(rawValue: dictationHandsFreeShortcut) ?? .fnOption).displayName
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

    private var cloudTTSUsesOpenRouter: Bool {
        cloudTTSBaseURL.localizedCaseInsensitiveContains("openrouter.ai")
    }

    private var cloudTTSVoiceOptions: [CloudVoiceOption] {
        CuratedSpeechModel.voiceOptions(for: cloudTTSModel)
    }

    private var hasCloudTTSKey: Bool {
        !cloudTTSKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var ttsSampleButtonTitle: String {
        if activeTTSBackend == .omniVoice && isGeneratingOmniVoice { return "Generating…" }
        if activeTTSBackend == .cloud && isGeneratingCloudTTS { return "Generating…" }
        return "Read sample"
    }

    private var ttsSampleDisabled: Bool {
        switch activeTTSBackend {
        case .system:
            return false
        case .omniVoice:
            return !omniVoiceAvailability.isReady || isGeneratingOmniVoice
        case .cloud:
            return !hasCloudTTSKey ||
                cloudTTSModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                cloudTTSVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                isGeneratingCloudTTS
        }
    }

    private var testTranscriptionDisabled: Bool {
        if isTranscribing || lastRecordingURL == nil { return true }
        switch activeDictationBackend {
        case .localWhisper:
            return !whisperAvailability.isReady
        case .cloud:
            return !hasCloudTTSKey || cloudSTTModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func refreshOmniVoiceState() {
        omniVoiceAvailability = OmniVoiceSynthesizer.availability()
        omniVoiceOutputURL = OmniVoiceSynthesizer.shared.lastOutputURL
    }

    private func refreshCloudTTSState() {
        cloudTTSOutputURL = CloudSpeechSynthesizer.shared.lastOutputURL
    }

    private func syncCloudTTSVoiceForModel() {
        let options = cloudTTSVoiceOptions
        guard !options.isEmpty else { return }
        if !options.contains(where: { $0.id == cloudTTSVoice }) {
            cloudTTSVoice = options[0].id
        }
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
        let sample = """
        LangFlip can read selected text aloud. Sentence pauses make stories easier to follow.
        A new line can pause a little longer.
        """
        if activeTTSBackend == .system {
            SpeechReader.shared.speak(sample)
            return
        }

        if activeTTSBackend == .cloud {
            isGeneratingCloudTTS = true
            cloudTTSMessage = "Generating cloud TTS sample..."
            Task {
                do {
                    let url = try await CloudSpeechSynthesizer.shared.generate(text: sample)
                    await MainActor.run {
                        isGeneratingCloudTTS = false
                        cloudTTSOutputURL = url
                        cloudTTSMessage = "Generated \(url.lastPathComponent)."
                        CloudSpeechSynthesizer.shared.play(url)
                    }
                } catch {
                    await MainActor.run {
                        isGeneratingCloudTTS = false
                        cloudTTSMessage = "Cloud TTS failed: \(error.localizedDescription)"
                    }
                }
            }
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
        omniVoiceSentencePause = Settings.shared.omniVoiceSentencePause
        omniVoiceLinePause = Settings.shared.omniVoiceLinePause
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
            HelpPopoverButton(text: help)
        }
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
                let text = try await transcribeWithSelectedBackend(audioURL: lastRecordingURL)
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

    private func transcribeWithSelectedBackend(audioURL: URL) async throws -> String {
        if activeDictationBackend == .cloud {
            return try await CloudTranscriber.transcribe(audioURL: audioURL)
        }
        return try await WhisperTranscriber.transcribe(
            audioURL: audioURL,
            language: whisperLanguage
        )
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

private struct HelpPopoverButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            isPresented = hovering
        }
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

// MARK: - Hotkeys

struct HotkeysTab: View {
    @AppStorage("lf.hotkeyPreset") private var hotkeyPreset = HotkeyPreset.doubleShift.rawValue
    @AppStorage("lf.translationHotkeyPreset") private var translationHotkeyPreset = GlobalShortcutPreset.shiftSpace.rawValue
    @AppStorage("lf.translationHotkeyCustom") private var translationHotkeyCustom = ""
    @AppStorage("lf.screenTextCaptureHotkeyPreset") private var screenTextCaptureHotkeyPreset = GlobalShortcutPreset.commandShiftS.rawValue
    @AppStorage("lf.screenTextCaptureHotkeyCustom") private var screenTextCaptureHotkeyCustom = ""
    @AppStorage("lf.readSelectionHotkeyPreset") private var readSelectionHotkeyPreset = GlobalShortcutPreset.controlOptionX.rawValue
    @AppStorage("lf.readSelectionHotkeyCustom") private var readSelectionHotkeyCustom = ""
    @AppStorage("lf.dictationPushToTalkShortcut") private var dictationPushToTalkShortcut = DictationPushToTalkShortcut.anyShift.rawValue
    @AppStorage("lf.dictationHandsFreeShortcut") private var dictationHandsFreeShortcut = DictationHandsFreeShortcut.fnOption.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: $hotkeyPreset) {
                    ForEach(HotkeyPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset.rawValue)
                    }
                }
                helpText("Flips selected text between keyboard layouts. If no text is selected and the Behavior toggle is on, the same gesture can try the last words before the cursor.")
            }
            Section("AI actions") {
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
            Section("Voice") {
                ShortcutRecorderRow(
                    title: "Read selected text aloud",
                    preset: $readSelectionHotkeyPreset,
                    custom: $readSelectionHotkeyCustom,
                    choices: GlobalShortcutPreset.readAloudChoices
                )
                helpText("Reads the current text selection with the voice backend selected in Voice settings.")
            }
            Section("Dictation") {
                Picker("Push-to-talk", selection: $dictationPushToTalkShortcut) {
                    ForEach(DictationPushToTalkShortcut.allCases) { shortcut in
                        Text(shortcut.displayName).tag(shortcut.rawValue)
                    }
                }
                Picker("Hands-free toggle", selection: $dictationHandsFreeShortcut) {
                    ForEach(DictationHandsFreeShortcut.allCases) { shortcut in
                        Text(shortcut.displayName).tag(shortcut.rawValue)
                    }
                }
                helpText("Push-to-talk records while held. Hands-free starts and stops recording with the same modifier chord. Enable or disable each mode in Voice.")
            }
            Section("Modifier gestures") {
                Text("Single Shift fixes selected text or the last sentence.")
                Text("Double Shift flips selected text or the last words.")
                helpText("Single and double Shift depend on press timing, so they stay as fixed gestures for now. Dictation modifier gestures are configurable above.")
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
            HStack {
                Picker(title, selection: $preset) {
                    ForEach(choices) { shortcut in
                        Text(shortcut.displayName).tag(shortcut.rawValue)
                    }
                }
                .disabled(hasCustom || isRecording)

                Button(isRecording ? "Press keys..." : "Record") {
                    startRecording()
                }
                .disabled(isRecording)

                if hasCustom {
                    Button("Use preset") {
                        custom = ""
                        warning = ""
                    }
                }
            }

            if hasCustom || isRecording || !warning.isEmpty {
                HStack(spacing: 8) {
                    if let shortcut = GlobalShortcut.decode(custom) {
                        Text("Custom: \(shortcut.displayName)")
                            .foregroundColor(.green)
                    } else if isRecording {
                        Text("Press modifiers plus a normal key. Esc cancels.")
                            .foregroundColor(.secondary)
                    }
                    if !warning.isEmpty {
                        Text(warning)
                            .foregroundColor(.orange)
                    }
                }
                .font(.caption)
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

// MARK: - Behavior

struct BehaviorTab: View {
    @AppStorage("lf.autoFlip") private var autoFlip = true
    @AppStorage("lf.doubleCapsFix") private var doubleCapsFix = true
    @AppStorage("lf.crossLayoutFix") private var crossLayoutFix = true
    @AppStorage("lf.suppressInFullscreen") private var suppressInFullscreen = false
    @AppStorage("lf.showOverlay") private var showOverlay = true
    @AppStorage("lf.fixLastSentenceOnSingleShift") private var fixLastSentenceOnSingleShift = true
    @AppStorage("lf.flipLastWordsOnDoubleShift") private var flipLastWordsOnDoubleShift = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FlowSettingsGroup {
                    FlowToggleRow(title: "Auto-flip at word end",
                                  detail: "After Space or punctuation, LangFlip can fix a word that was typed in the wrong layout. Press Backspace right away to undo and remember an exception.",
                                  isOn: $autoFlip)
                }

                FlowSettingsGroup("No-selection actions") {
                    FlowToggleRow(title: "Single Shift fixes last sentence", isOn: $fixLastSentenceOnSingleShift)
                    FlowToggleRow(title: "Double Shift flips last words",
                                  detail: "When no text is selected, LangFlip reads the focused text field through Accessibility and rewrites only the text before the cursor. Turn this off if a specific app behaves unpredictably.",
                                  isOn: $flipLastWordsOnDoubleShift)
                }

                FlowSettingsGroup("Corrections") {
                    FlowToggleRow(title: "Fix sticky-shift typos (WOrld → World)",
                                  detail: "Fixes accidental double-capital starts when the corrected word is clearly safe.",
                                  isOn: $doubleCapsFix)
                    FlowToggleRow(title: "Fix UK ↔ RU letter slips (ы ↔ і, э ↔ є)",
                                  detail: "Fixes common Ukrainian/Russian letter slips when the corrected word is in the target dictionary.",
                                  isOn: $crossLayoutFix)
                }

                FlowSettingsGroup("Overlay & focus") {
                    overlayRow
                    FlowToggleRow(title: "Pause auto-flip in fullscreen apps",
                                  detail: "Useful for games, video players, and other fullscreen apps where automatic changes may be distracting.",
                                  isOn: $suppressInFullscreen)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
            Text("Shows a small visual confirmation whenever LangFlip rewrites text.")
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
}

// MARK: - Models (AI)

struct ModelsTab: View {
    private let releaseAIModes: [AIMode] = [.off, .appleFoundation, .ollama, .openai]

    @AppStorage("lf.aiMode") private var aiMode = AIMode.off.rawValue
    @AppStorage("lf.grammarCheckOnSingleShift") private var grammarOnSingleShift = true
    @AppStorage("lf.translationHotkeyEnabled") private var translationHotkeyEnabled = false
    @AppStorage("lf.translationHotkeyPreset") private var translationHotkeyPreset = GlobalShortcutPreset.shiftSpace.rawValue
    @AppStorage("lf.translationHotkeyCustom") private var translationHotkeyCustom = ""
    @AppStorage("lf.screenTextCaptureHotkeyEnabled") private var screenTextCaptureHotkeyEnabled = true
    @AppStorage("lf.screenTextCaptureHotkeyPreset") private var screenTextCaptureHotkeyPreset = GlobalShortcutPreset.commandShiftS.rawValue
    @AppStorage("lf.screenTextCaptureHotkeyCustom") private var screenTextCaptureHotkeyCustom = ""
    @AppStorage("lf.translationTarget") private var translationTarget = Layout.en.rawValue
    @AppStorage("lf.ollamaModel") private var ollamaModel = "qwen3.5:2b"
    @AppStorage("lf.cloudProvider") private var cloudProvider = AICloudProvider.openRouter.rawValue
    @AppStorage("lf.openaiModel") private var openaiModel = "gpt-5-nano"
    @AppStorage("lf.openaiBaseURL") private var openaiBaseURL = "https://api.openai.com/v1"
    @AppStorage("lf.cloudOCRModel") private var cloudOCRModel = "google/gemini-3.1-flash-lite"

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
                    helpText("AI is optional. Ollama with Qwen 3.5 2B is the default local setup for fast grammar fixes and screen text capture.")
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
                        OpenRouterTextCorrectionModelPicker(selectedModel: $openaiModel)
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
                    if AIMode(rawValue: aiMode) == .ollama || AIMode(rawValue: aiMode) == .openai {
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
                helpText("Used by the menu bar Translate action. The Shift+Space hotkey translates into the language of your current keyboard layout.")

                Toggle("Translate with \(translationShortcutName)", isOn: Binding(
                    get: { aiReadyForHotkeys && translationHotkeyEnabled },
                    set: { translationHotkeyEnabled = $0 }
                ))
                .disabled(!aiReadyForHotkeys)
                helpText(aiReadyForHotkeys
                         ? "When AI is on, \(translationShortcutName) translates the current selection into the language of your active keyboard layout."
                         : "Install and select a local model to enable this shortcut.")
            }

            if AIMode(rawValue: aiMode) == .ollama {
                Section("Screen text capture") {
                    Toggle("Capture text with \(screenCaptureShortcutName)", isOn: $screenTextCaptureHotkeyEnabled)
                    helpText("Select a screen region and copy recognized text to the clipboard. Requires a vision-capable Ollama model.")
                }
            } else if AIMode(rawValue: aiMode) == .openai {
                Section("Screen text capture") {
                    Toggle("Capture text with \(screenCaptureShortcutName)", isOn: $screenTextCaptureHotkeyEnabled)

                    if AICloudProvider(rawValue: cloudProvider) == .openRouter {
                        OpenRouterOCRModelPicker(selectedModel: $cloudOCRModel)
                    } else {
                        TextField("Vision model", text: $cloudOCRModel)
                            .textFieldStyle(.roundedBorder)
                    }

                    helpText("Cloud OCR sends only the screenshot region you select. Best default: Gemini 3.1 Flash Lite for fast low-cost OCR; Qwen 3.6 Flash is the cheaper experiment.")
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
            return "Bundled MLX models are not part of this release. Use Ollama with Qwen 3.5 2B for fast local grammar fixes and screen text capture."
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
            return "This model is used by Single Shift fixes, Fix Selected Text, translation, and short AI tests. The default is chosen for fast, low-cost proofreading."
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

    private var translationShortcutName: String {
        GlobalShortcut.decode(translationHotkeyCustom)?.displayName
            ?? (GlobalShortcutPreset(rawValue: translationHotkeyPreset) ?? .shiftSpace).displayName
    }

    private var screenCaptureShortcutName: String {
        GlobalShortcut.decode(screenTextCaptureHotkeyCustom)?.displayName
            ?? (GlobalShortcutPreset(rawValue: screenTextCaptureHotkeyPreset) ?? .commandShiftS).displayName
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
        case .openRouter: return "google/gemini-3.1-flash-lite"
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

    private let sample = "I dont know why this app works so well but it realy helps me every day"

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

    private let sample = "SCAN THIS TEXT"

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
                .help("Test copy text from screenshot with the selected Ollama model")
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
            Text("Checks that the selected Ollama model can read text from screenshots.")
        case .running:
            Text("Running screenshot text test...")
        case .success(_, let seconds):
            Text(String(format: "Copied text in %.1f s.", seconds))
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
                    let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(clean, forType: .string)
                    state = .success(
                        output: clean,
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

    private struct RecommendedModel: Identifiable {
        let tag: String
        let menuLabel: String
        let displayName: String
        let detail: String

        var id: String { tag }
    }

    private let recommendedModels: [RecommendedModel] = [
        RecommendedModel(
            tag: "qwen3.5:2b",
            menuLabel: "Qwen 3.5 2B Default (vision)",
            displayName: "Qwen 3.5 2B",
            detail: "Default fast option for short text fixes, screenshots, and lower memory use."
        ),
        RecommendedModel(
            tag: "qwen3.5:4b",
            menuLabel: "Qwen 3.5 4B Quality (vision)",
            displayName: "Qwen 3.5 4B",
            detail: "Use on Macs with 16 GB+ RAM if the default 2B model makes mistakes."
        )
    ]

    @Binding var selectedModel: String
    let onSelectedModelAvailabilityChanged: (Bool) -> Void

    @State private var installedModels: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var installState: InstallState = .idle
    @State private var installingModel: String?
    @State private var failedModel: String?
    @State private var installMessage: String?
    @State private var installProgress: Double?

    private var dropdownModels: [String] {
        var models: [String] = []
        for model in recommendedModels.map(\.tag) + installedModels {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = canonicalModelTag(trimmed)
            let alreadyIncluded = models.contains { canonicalModelTag($0) == canonical }
            if isAllowedDropdownModel(trimmed), !alreadyIncluded {
                models.append(trimmed)
            }
        }
        return models
    }

    private var isInstalling: Bool {
        installingModel != nil
    }

    private var supportedInstalledModels: [String] {
        installedModels.filter(isAllowedDropdownModel)
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

            VStack(alignment: .leading, spacing: 6) {
                ForEach(recommendedModels) { model in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button(installButtonTitle(for: model.tag)) {
                            Task { await installModel(model.tag) }
                        }
                        .disabled(isModelInstalled(model.tag) || isInstalling)
                        .frame(width: 218, alignment: .leading)

                        Text(modelStatusText(for: model))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }

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
                if let installProgress {
                    ProgressView(value: installProgress)
                        .progressViewStyle(.linear)
                }
            } else if !supportedInstalledModels.isEmpty {
                Text("Found \(supportedInstalledModels.count) supported Qwen 3.5 model\(supportedInstalledModels.count == 1 ? "" : "s").")
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
        .onChange(of: installedModels) { _ in
            selectSupportedModelIfNeeded()
        }
    }

    private func installButtonTitle(for model: String) -> String {
        if isModelInstalled(model) {
            return "\(displayName(for: model)) installed"
        }
        if installingModel == model {
            return "Downloading \(displayName(for: model))..."
        }
        if failedModel == model {
            return "Try \(displayName(for: model)) again"
        }
        switch installState {
        case .idle, .installing, .finished: return "Download \(displayName(for: model))"
        case .failed: return "Download \(displayName(for: model))"
        }
    }

    private func label(for model: String) -> String {
        if let recommended = recommendedModel(for: model) {
            return recommended.menuLabel
        }
        return model
    }

    private func displayName(for model: String) -> String {
        if let recommended = recommendedModel(for: model) {
            return recommended.displayName
        }
        return model
    }

    private func modelStatusText(for model: RecommendedModel) -> String {
        if isModelInstalled(model.tag) {
            return "Installed. \(model.detail)"
        }
        return model.detail
    }

    private func recommendedModel(for model: String) -> RecommendedModel? {
        let canonical = canonicalModelTag(model)
        return recommendedModels.first { canonicalModelTag($0.tag) == canonical }
    }

    private func isAllowedDropdownModel(_ model: String) -> Bool {
        let canonical = canonicalModelTag(model)
        return canonical.contains("qwen3.5")
    }

    private func isModelInstalled(_ model: String) -> Bool {
        let canonical = canonicalModelTag(model)
        return installedModels.contains { canonicalModelTag($0) == canonical }
    }

    private func notifySelectedModelAvailability() {
        onSelectedModelAvailabilityChanged(isModelInstalled(selectedModel))
    }

    private func selectSupportedModelIfNeeded() {
        guard !isAllowedDropdownModel(selectedModel) else { return }
        let fallback = installedModels.first { canonicalModelTag($0) == "qwen3.5:2b" }
            ?? installedModels.first { canonicalModelTag($0) == "qwen3.5:4b" }
            ?? dropdownModels.first
        guard let fallback else { return }
        selectedModel = fallback
        notifySelectedModelAvailability()
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
        failedModel = nil
        loadError = nil
        installMessage = "Downloading \(displayName(for: model)). This can take a few minutes."
        installProgress = nil
        defer { installingModel = nil }

        if Self.ollamaExecutableURL() == nil {
            openOllamaOrDownloadPage()
            installState = .failed
            failedModel = model
            installProgress = nil
            installMessage = "Ollama was not found. Install Ollama, open it once, then try again."
            return
        }

        if let failure = await Self.pullOllamaModel(model, progress: { message, progress in
            installMessage = message
            installProgress = progress
        }) {
            installState = .failed
            failedModel = model
            installProgress = nil
            installMessage = failure
        } else {
            installState = .finished
            failedModel = nil
            installProgress = nil
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
            selectSupportedModelIfNeeded()
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

    nonisolated private static func pullOllamaModel(
        _ model: String,
        progress: @escaping @MainActor (String, Double?) -> Void
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let executableURL = ollamaExecutableURL() else {
                return "Ollama was not found. Install Ollama, open it once, then try again."
            }

            let process = Process()
            let pipe = Pipe()
            let outputBuffer = PreferencesLockedOutputBuffer()
            process.executableURL = executableURL
            process.arguments = ["pull", model]
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }
                let snapshot = outputBuffer.appendAndRead(chunk)
                if let update = Self.ollamaProgress(from: snapshot, model: model) {
                    Task { @MainActor in
                        progress(update.message, update.fraction)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                return "Could not open Ollama: \(error.localizedDescription)"
            }

            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            let output = outputBuffer.read()
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .suffix(2)
                .joined(separator: " ")

            guard process.terminationStatus == 0 else {
                let detail = output.isEmpty ? "" : " \(output)"
                return "Ollama could not download \(model).\(detail)"
            }
            return nil
        }.value
    }

    nonisolated private static func ollamaProgress(from output: String, model: String) -> (message: String, fraction: Double?)? {
        let lines = output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }

        let display = displayName(forModelTag: model)
        if let percentRange = last.range(of: #"\d{1,3}%"#, options: .regularExpression) {
            let percentText = String(last[percentRange]).replacingOccurrences(of: "%", with: "")
            let percent = min(max((Double(percentText) ?? 0) / 100, 0), 1)
            return ("Downloading \(display)... \(Int(percent * 100))%", percent)
        }

        let lower = last.lowercased()
        if lower.contains("pulling manifest") { return ("Preparing \(display) download...", nil) }
        if lower.contains("verifying") { return ("Verifying \(display)...", nil) }
        if lower.contains("writing manifest") { return ("Finishing \(display) install...", nil) }
        if lower.contains("success") { return ("\(display) downloaded.", 1) }

        return ("Downloading \(display)...", nil)
    }

    nonisolated private static func displayName(forModelTag model: String) -> String {
        let tag = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag == "qwen3.5:2b" { return "Qwen 3.5 2B" }
        if tag == "qwen3.5:4b" { return "Qwen 3.5 4B" }
        return tag
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

private final class PreferencesLockedOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func appendAndRead(_ chunk: String) -> String {
        lock.lock()
        storage += chunk
        let snapshot = storage
        lock.unlock()
        return snapshot
    }

    func read() -> String {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return snapshot
    }
}

private struct CuratedTextCorrectionModel: Identifiable {
    let id: String
    let label: String
    let note: String

    static let curated: [CuratedTextCorrectionModel] = [
        .init(
            id: "google/gemini-3.1-flash-lite",
            label: "Google: Gemini 3.1 Flash Lite - $0.25 / $1.50 per 1M",
            note: "Best default: fast, low-cost, strong multilingual proofreading, and useful for both selected text and last-sentence fixes."
        ),
        .init(
            id: "openai/gpt-5-nano",
            label: "OpenAI: GPT-5 Nano - $0.05 / $0.40 per 1M",
            note: "Cheapest OpenAI option; good for short typo and punctuation cleanup when you want predictable OpenAI behavior."
        ),
        .init(
            id: "deepseek/deepseek-v4-flash",
            label: "DeepSeek: V4 Flash - $0.10 / $0.20 per 1M",
            note: "Lowest output cost in the curated set; strong budget option for frequent text cleanup."
        ),
        .init(
            id: "qwen/qwen3.6-flash",
            label: "Qwen: Qwen3.6 Flash - $0.19 / $1.13 per 1M",
            note: "Very good price/quality candidate for multilingual text, especially mixed Ukrainian/Russian/English snippets."
        ),
        .init(
            id: "openai/gpt-5-mini",
            label: "OpenAI: GPT-5 Mini - $0.25 / $2.00 per 1M",
            note: "Higher-quality OpenAI fallback when Nano misses nuance; still cheap enough for daily proofreading."
        ),
        .init(
            id: "mistralai/mistral-medium-3-5",
            label: "Mistral: Medium 3.5 - $1.50 / $7.50 per 1M",
            note: "Quality comparison model for harder rewrites; not the cheapest, but useful when style matters."
        ),
    ]
}

private struct OpenRouterTextCorrectionModelPicker: View {
    @Binding var selectedModel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Text correction model", selection: $selectedModel) {
                ForEach(CuratedTextCorrectionModel.curated) { model in
                    Text(model.label).tag(model.id)
                }
            }

            if let selected = CuratedTextCorrectionModel.curated.first(where: { $0.id == selectedModel }) {
                Text(selected.note)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Custom model id", text: $selectedModel)
                .textFieldStyle(.roundedBorder)
                .help("Use another OpenRouter model id if you want to experiment outside the curated list.")
        }
    }
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

private struct CloudVoiceOption: Identifiable {
    let id: String
    let label: String
}

private struct CuratedSpeechModel: Identifiable {
    let id: String
    let label: String
    let note: String
    let voices: [CloudVoiceOption]

    static let openAIVoices: [CloudVoiceOption] = [
        .init(id: "nova", label: "nova - balanced"),
        .init(id: "alloy", label: "alloy - neutral"),
        .init(id: "ash", label: "ash - calm"),
        .init(id: "ballad", label: "ballad - expressive"),
        .init(id: "coral", label: "coral - bright"),
        .init(id: "echo", label: "echo - clear"),
        .init(id: "fable", label: "fable - storytelling"),
        .init(id: "onyx", label: "onyx - deep"),
        .init(id: "sage", label: "sage - composed"),
        .init(id: "shimmer", label: "shimmer - light"),
    ]

    static let geminiVoices: [CloudVoiceOption] = [
        .init(id: "Kore", label: "Kore - firm"),
        .init(id: "Puck", label: "Puck - upbeat"),
        .init(id: "Zephyr", label: "Zephyr - bright"),
        .init(id: "Charon", label: "Charon - steady"),
        .init(id: "Fenrir", label: "Fenrir - deeper"),
        .init(id: "Leda", label: "Leda - youthful"),
        .init(id: "Aoede", label: "Aoede - smooth"),
        .init(id: "Orus", label: "Orus - grounded"),
    ]

    static let kokoroVoices: [CloudVoiceOption] = [
        .init(id: "af_heart", label: "af_heart - warm"),
        .init(id: "af_bella", label: "af_bella - expressive"),
        .init(id: "af_nova", label: "af_nova - balanced"),
        .init(id: "af_sky", label: "af_sky - bright"),
        .init(id: "am_adam", label: "am_adam - male"),
        .init(id: "am_echo", label: "am_echo - clear"),
        .init(id: "bf_emma", label: "bf_emma - British"),
        .init(id: "bm_daniel", label: "bm_daniel - British male"),
    ]

    static let curated: [CuratedSpeechModel] = [
        .init(
            id: "openai/gpt-4o-mini-tts-2025-12-15",
            label: "OpenAI: GPT-4o Mini TTS - $0.60/M chars",
            note: "Best default: cheap, stable, OpenAI-compatible, supports instructions.",
            voices: openAIVoices
        ),
        .init(
            id: "google/gemini-3.1-flash-tts-preview",
            label: "Google: Gemini 3.1 Flash TTS Preview - $1/M input + $20/M output",
            note: "Best quality/multilingual experiment: 70+ languages and inline audio tags.",
            voices: geminiVoices
        ),
        .init(
            id: "hexgrad/kokoro-82m",
            label: "hexgrad: Kokoro 82M - $0.62/M chars",
            note: "Tiny low-cost TTS; 8 languages, best for cheap lightweight playback.",
            voices: kokoroVoices
        ),
    ]

    static func voiceOptions(for modelID: String) -> [CloudVoiceOption] {
        curated.first(where: { $0.id == modelID })?.voices ?? openAIVoices
    }
}

private struct OpenRouterSpeechModelPicker: View {
    @Binding var selectedModel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: $selectedModel) {
                ForEach(CuratedSpeechModel.curated) { model in
                    Text(model.label).tag(model.id)
                }
            }

            if let selected = CuratedSpeechModel.curated.first(where: { $0.id == selectedModel }) {
                Text(selected.note)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CuratedTranscriptionModel: Identifiable {
    let id: String
    let label: String
    let note: String

    static let defaultID = "nvidia/parakeet-tdt-0.6b-v3"

    static let curated: [CuratedTranscriptionModel] = [
        .init(
            id: "nvidia/parakeet-tdt-0.6b-v3",
            label: "NVIDIA: Parakeet TDT 0.6B v3 - $0.0015/min",
            note: "Best default: very cheap, multilingual EU coverage, punctuation and timestamps."
        ),
        .init(
            id: "qwen/qwen3-asr-flash-2026-02-10",
            label: "Qwen: Qwen3 ASR Flash - $0.000035/sec (~$0.0021/min)",
            note: "Strong noisy/mixed-language option; supports Russian and several major languages."
        ),
        .init(
            id: "mistralai/voxtral-mini-transcribe",
            label: "Mistral: Voxtral Mini Transcribe - $0.003/min",
            note: "Good comparison point for multilingual dictation."
        ),
        .init(
            id: "openai/gpt-4o-transcribe",
            label: "OpenAI: GPT-4o Transcribe - $2.50/M input + $10/M output",
            note: "Higher-cost OpenAI transcription model; compare quality before daily use."
        ),
        .init(
            id: "google/chirp-3",
            label: "Google: Chirp 3 - $0.016/min",
            note: "Google STT option; currently much pricier than Parakeet/Qwen/Whisper V3."
        ),
    ]

    static func normalizedID(_ id: String) -> String {
        curated.contains(where: { $0.id == id }) ? id : defaultID
    }
}

private struct OpenRouterTranscriptionModelPicker: View {
    @Binding var selectedModel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: $selectedModel) {
                ForEach(CuratedTranscriptionModel.curated) { model in
                    Text(model.label).tag(model.id)
                }
            }

            if let selected = CuratedTranscriptionModel.curated.first(where: { $0.id == selectedModel }) {
                Text(selected.note)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            selectedModel = CuratedTranscriptionModel.normalizedID(selectedModel)
        }
        .onChange(of: selectedModel) { newValue in
            selectedModel = CuratedTranscriptionModel.normalizedID(newValue)
        }
    }
}

private struct CuratedOCRModel: Identifiable {
    let id: String
    let label: String
    let note: String

    static let curated: [CuratedOCRModel] = [
        .init(
            id: "google/gemini-3.1-flash-lite",
            label: "Google: Gemini 3.1 Flash Lite - $0.25 / $1.50 per 1M",
            note: "Best default: fast, strong OCR, image input, low cost; OpenRouter also lists image input at $0.25/M."
        ),
        .init(
            id: "qwen/qwen3.6-flash",
            label: "Qwen: Qwen3.6 Flash - $0.19 / $1.13 per 1M",
            note: "Cheapest serious cloud OCR candidate right now; good to compare for short screenshot snippets."
        ),
        .init(
            id: "qwen/qwen3.5-plus-20260420",
            label: "Qwen: Qwen3.5 Plus - $0.30 / $1.80 per 1M",
            note: "Slightly pricier Qwen vision option with a large context window; useful for denser screenshots."
        ),
        .init(
            id: "google/gemma-4-26b-a4b-it",
            label: "Google: Gemma 4 26B - $0.06 / $0.33 per 1M",
            note: "Very cheap open model with image input; quality may vary more, but worth testing for simple UI text."
        ),
        .init(
            id: "perceptron/perceptron-mk1",
            label: "Perceptron: Mk1 - $0.15 / $1.50 per 1M",
            note: "Low-cost multimodal model; good fallback if Gemini or Qwen routing is unavailable."
        ),
    ]
}

private struct OpenRouterOCRModelPicker: View {
    @Binding var selectedModel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Vision model", selection: $selectedModel) {
                ForEach(CuratedOCRModel.curated) { model in
                    Text(model.label).tag(model.id)
                }
            }

            if let selected = CuratedOCRModel.curated.first(where: { $0.id == selectedModel }) {
                Text(selected.note)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    var supportsSpeechOutput: Bool {
        architecture?.outputModalities?.contains("speech") ?? false
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

    static func isBetterForSpeech(_ lhs: OpenRouterModel, _ rhs: OpenRouterModel) -> Bool {
        let pinned = [
            "openai/gpt-4o-mini-tts-2025-12-15",
            "google/gemini-3.1-flash-tts-preview",
        ]
        let lhsPinned = pinned.firstIndex(of: lhs.id)
        let rhsPinned = pinned.firstIndex(of: rhs.id)
        if lhsPinned != rhsPinned {
            return (lhsPinned ?? Int.max) < (rhsPinned ?? Int.max)
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Apps

struct AppsTab: View {
    @State private var userBlocked = Array(Settings.shared.userBlacklist).sorted()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FlowSettingsGroup("App exclusions") {
                    if userBlocked.isEmpty {
                        Text("No apps are excluded. LangFlip automatically avoids sensitive app types like terminals and password managers.")
                            .font(.system(size: 13))
                            .foregroundColor(FlowTheme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(userBlocked, id: \.self) { bundleID in
                            HStack {
                                Text(bundleID)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(FlowTheme.ink)
                                Spacer(minLength: 12)
                                FlowSmallButton(title: "Remove") { remove(bundleID) }
                            }
                        }
                    }
                }

                FlowSettingsGroup("Built-in blocks") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Auto-flip stays off in apps where automatic rewriting could damage commands or credentials.")
                        Text("Terminals: Terminal, iTerm2, Warp, Ghostty, Alacritty, Kitty, Hyper, Tabby")
                        Text("Password managers: 1Password, LastPass, Dashlane, Bitwarden, KeePassXC, and similar apps.")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func remove(_ bundleID: String) {
        var set = Settings.shared.userBlacklist
        set.remove(bundleID)
        Settings.shared.userBlacklist = set
        userBlocked = Array(set).sorted()
    }
}

// MARK: - About

struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 88, height: 88)
                }
                Text("LangFlip")
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundColor(FlowTheme.ink)
                Text("Version \(version)")
                    .font(.system(size: 13))
                    .foregroundColor(FlowTheme.inkSecondary)

                Text("A macOS writing assistant for wrong-layout fixes, selected-text cleanup, translation, and screen text capture.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundColor(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)

                HStack(spacing: 10) {
                    FlowSmallButton(title: "GitHub") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/MikeKorotych/lang-flip")!)
                    }
                    FlowSmallButton(title: "MIT License") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/MikeKorotych/lang-flip/blob/main/LICENSE")!)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.top, 40)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
    }
}
