import Foundation
import Carbon.HIToolbox
import AppKit

/// User-selectable hotkey gestures. We deliberately keep the list short
/// and limited to "safe" keys — any modifier that's heavily used in
/// system shortcuts (left Cmd, plain Option) would false-fire on rapid
/// shortcut sequences (Cmd+C, Cmd+V…) and ruin the experience. The
/// default `.doubleShift` is what Caramba and most muscle memory
/// expects.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case doubleShift
    case doubleRightCmd
    case doubleRightOption

    var id: Self { self }

    var displayName: String {
        switch self {
        case .doubleShift:       return "Double-tap Shift (any side)"
        case .doubleRightCmd:    return "Double-tap right Command"
        case .doubleRightOption: return "Double-tap right Option"
        }
    }

    /// The physical keys the tap-counter watches for this preset, paired
    /// with the NX device-flag bit that says "this key is currently held"
    /// inside CGEventFlags.rawValue. Multiple entries mean either key
    /// counts toward a tap (the default `.doubleShift` accepts left or
    /// right Shift indifferently).
    var watchedKeys: [(keyCode: CGKeyCode, bitMask: UInt64)] {
        switch self {
        case .doubleShift:
            return [
                (CGKeyCode(kVK_Shift),         0x2),  // NX_DEVICELSHIFTKEYMASK
                (CGKeyCode(kVK_RightShift),    0x4),  // NX_DEVICERSHIFTKEYMASK
            ]
        case .doubleRightCmd:
            return [(CGKeyCode(kVK_RightCommand), 0x10)] // NX_DEVICERCMDKEYMASK
        case .doubleRightOption:
            return [(CGKeyCode(kVK_RightOption), 0x40)]  // NX_DEVICERALTKEYMASK
        }
    }
}

enum TextToSpeechBackend: String, CaseIterable, Identifiable {
    case system
    case omniVoice

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system: return "System voices"
        case .omniVoice: return "OmniVoice local"
        }
    }
}

enum DictationPushToTalkShortcut: String, CaseIterable, Identifiable {
    case anyShift
    case leftShift
    case rightShift

    var id: Self { self }

    var displayName: String {
        switch self {
        case .anyShift: return "Hold Shift"
        case .leftShift: return "Hold left Shift"
        case .rightShift: return "Hold right Shift"
        }
    }

    func isWatchedKey(_ keyCode: CGKeyCode) -> Bool {
        switch self {
        case .anyShift:
            return keyCode == CGKeyCode(kVK_Shift) || keyCode == CGKeyCode(kVK_RightShift)
        case .leftShift:
            return keyCode == CGKeyCode(kVK_Shift)
        case .rightShift:
            return keyCode == CGKeyCode(kVK_RightShift)
        }
    }
}

enum DictationHandsFreeShortcut: String, CaseIterable, Identifiable {
    case commandShift
    case controlShift
    case optionShift

    var id: Self { self }

    var displayName: String {
        switch self {
        case .commandShift: return "Command+Shift"
        case .controlShift: return "Control+Shift"
        case .optionShift: return "Option+Shift"
        }
    }

    func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let isShiftKey = keyCode == CGKeyCode(kVK_Shift) || keyCode == CGKeyCode(kVK_RightShift)
        switch self {
        case .commandShift:
            let isCommandKey = keyCode == CGKeyCode(kVK_Command) || keyCode == CGKeyCode(kVK_RightCommand)
            return flags.contains(.maskShift) &&
                   flags.contains(.maskCommand) &&
                   !flags.contains(.maskAlternate) &&
                   !flags.contains(.maskControl) &&
                   (isShiftKey || isCommandKey)
        case .controlShift:
            let isControlKey = keyCode == CGKeyCode(kVK_Control) || keyCode == CGKeyCode(kVK_RightControl)
            return flags.contains(.maskShift) &&
                   flags.contains(.maskControl) &&
                   !flags.contains(.maskAlternate) &&
                   !flags.contains(.maskCommand) &&
                   (isShiftKey || isControlKey)
        case .optionShift:
            let isOptionKey = keyCode == CGKeyCode(kVK_Option) || keyCode == CGKeyCode(kVK_RightOption)
            return flags.contains(.maskShift) &&
                   flags.contains(.maskAlternate) &&
                   !flags.contains(.maskCommand) &&
                   !flags.contains(.maskControl) &&
                   (isShiftKey || isOptionKey)
        }
    }

    func isReleased(flags: CGEventFlags) -> Bool {
        switch self {
        case .commandShift:
            return !flags.contains(.maskShift) && !flags.contains(.maskCommand)
        case .controlShift:
            return !flags.contains(.maskShift) && !flags.contains(.maskControl)
        case .optionShift:
            return !flags.contains(.maskShift) && !flags.contains(.maskAlternate)
        }
    }
}

enum GlobalShortcutPreset: String, CaseIterable, Identifiable {
    case shiftSpace
    case commandShiftS
    case controlOptionX
    case controlOptionR
    case controlOptionT
    case controlOptionS
    case controlOptionO
    case commandOptionT
    case commandOptionS
    case commandOptionO

    var id: Self { self }

    static let translationChoices: [GlobalShortcutPreset] = [
        .shiftSpace, .controlOptionT, .commandOptionT
    ]

    static let screenCaptureChoices: [GlobalShortcutPreset] = [
        .commandShiftS, .controlOptionS, .commandOptionS, .controlOptionO, .commandOptionO
    ]

    static let readAloudChoices: [GlobalShortcutPreset] = [
        .controlOptionX, .controlOptionR, .controlOptionT, .commandOptionT
    ]

    var displayName: String {
        switch self {
        case .shiftSpace: return "Shift+Space"
        case .commandShiftS: return "Shift+Command+S"
        case .controlOptionX: return "Control+Option+X"
        case .controlOptionR: return "Control+Option+R"
        case .controlOptionT: return "Control+Option+T"
        case .controlOptionS: return "Control+Option+S"
        case .controlOptionO: return "Control+Option+O"
        case .commandOptionT: return "Command+Option+T"
        case .commandOptionS: return "Command+Option+S"
        case .commandOptionO: return "Command+Option+O"
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .shiftSpace: return CGKeyCode(kVK_Space)
        case .commandShiftS, .controlOptionS, .commandOptionS: return CGKeyCode(kVK_ANSI_S)
        case .controlOptionX: return CGKeyCode(kVK_ANSI_X)
        case .controlOptionR: return CGKeyCode(kVK_ANSI_R)
        case .controlOptionT, .commandOptionT: return CGKeyCode(kVK_ANSI_T)
        case .controlOptionO, .commandOptionO: return CGKeyCode(kVK_ANSI_O)
        }
    }

    var requiredFlags: CGEventFlags {
        switch self {
        case .shiftSpace: return [.maskShift]
        case .commandShiftS: return [.maskCommand, .maskShift]
        case .controlOptionX, .controlOptionR, .controlOptionT, .controlOptionS, .controlOptionO:
            return [.maskControl, .maskAlternate]
        case .commandOptionT, .commandOptionS, .commandOptionO:
            return [.maskCommand, .maskAlternate]
        }
    }

    var keyEquivalent: String {
        switch self {
        case .shiftSpace: return " "
        case .commandShiftS, .controlOptionS, .commandOptionS: return "s"
        case .controlOptionX: return "x"
        case .controlOptionR: return "r"
        case .controlOptionT, .commandOptionT: return "t"
        case .controlOptionO, .commandOptionO: return "o"
        }
    }

    var menuModifierFlags: NSEvent.ModifierFlags {
        shortcut.menuModifierFlags
    }

    func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        shortcut.matches(keyCode: keyCode, flags: flags)
    }

    var shortcut: GlobalShortcut {
        GlobalShortcut(
            keyCode: keyCode,
            modifiers: GlobalShortcut.modifierMask(from: requiredFlags),
            displayName: displayName,
            keyEquivalent: keyEquivalent
        )
    }
}

struct GlobalShortcut: Equatable {
    static let command = 1
    static let option = 2
    static let control = 4
    static let shift = 8

    let keyCode: CGKeyCode
    let modifiers: Int
    let displayName: String
    let keyEquivalent: String

    var menuModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & Self.command != 0 { flags.insert(.command) }
        if modifiers & Self.option != 0 { flags.insert(.option) }
        if modifiers & Self.control != 0 { flags.insert(.control) }
        if modifiers & Self.shift != 0 { flags.insert(.shift) }
        return flags
    }

    func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && Self.modifierMask(from: flags) == modifiers
    }

    var encoded: String {
        [
            String(keyCode),
            String(modifiers),
            displayName.replacingOccurrences(of: "|", with: "/"),
            keyEquivalent.replacingOccurrences(of: "|", with: "/")
        ].joined(separator: "|")
    }

    static func decode(_ raw: String?) -> GlobalShortcut? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4,
              let key = UInt16(parts[0]),
              let modifiers = Int(parts[1]),
              modifiers != 0
        else { return nil }
        return GlobalShortcut(
            keyCode: CGKeyCode(key),
            modifiers: modifiers,
            displayName: parts[2],
            keyEquivalent: parts[3]
        )
    }

    static func from(event: NSEvent) -> GlobalShortcut? {
        let modifiers = modifierMask(from: event.modifierFlags)
        guard modifiers != 0 else { return nil }
        let keyCode = CGKeyCode(event.keyCode)
        guard !isModifierOnlyKey(keyCode) else { return nil }
        let keyName = displayName(for: keyCode, event: event)
        guard !keyName.isEmpty else { return nil }
        return GlobalShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            displayName: modifierPrefix(modifiers) + keyName,
            keyEquivalent: keyEquivalent(for: keyCode, event: event)
        )
    }

    static func modifierMask(from flags: CGEventFlags) -> Int {
        var value = 0
        if flags.contains(.maskCommand) { value |= command }
        if flags.contains(.maskAlternate) { value |= option }
        if flags.contains(.maskControl) { value |= control }
        if flags.contains(.maskShift) { value |= shift }
        return value
    }

    static func modifierMask(from flags: NSEvent.ModifierFlags) -> Int {
        var value = 0
        if flags.contains(.command) { value |= command }
        if flags.contains(.option) { value |= option }
        if flags.contains(.control) { value |= control }
        if flags.contains(.shift) { value |= shift }
        return value
    }

    private static func modifierPrefix(_ modifiers: Int) -> String {
        var parts: [String] = []
        if modifiers & control != 0 { parts.append("Control") }
        if modifiers & option != 0 { parts.append("Option") }
        if modifiers & shift != 0 { parts.append("Shift") }
        if modifiers & command != 0 { parts.append("Command") }
        return parts.isEmpty ? "" : parts.joined(separator: "+") + "+"
    }

    private static func isModifierOnlyKey(_ keyCode: CGKeyCode) -> Bool {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift, kVK_Command, kVK_RightCommand, kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl:
            return true
        default:
            return false
        }
    }

    private static func displayName(for keyCode: CGKeyCode, event: NSEvent) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Escape"
        case kVK_LeftArrow: return "Left Arrow"
        case kVK_RightArrow: return "Right Arrow"
        case kVK_UpArrow: return "Up Arrow"
        case kVK_DownArrow: return "Down Arrow"
        default:
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                return chars.uppercased()
            }
            return ""
        }
    }

    private static func keyEquivalent(for keyCode: CGKeyCode, event: NSEvent) -> String {
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Delete: return "\u{8}"
        default:
            guard let chars = event.charactersIgnoringModifiers, chars.count == 1 else { return "" }
            return chars.lowercased()
        }
    }
}

enum ShortcutRecordingState {
    static var isRecording = false
}

enum OmniVoiceLanguage: String, CaseIterable, Identifiable {
    case auto
    case english
    case ukrainian
    case russian

    var id: Self { self }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .english: return "English"
        case .ukrainian: return "Українська"
        case .russian: return "Русский"
        }
    }

    var cliValue: String? {
        switch self {
        case .auto: return nil
        case .english: return "English"
        case .ukrainian: return "Ukrainian"
        case .russian: return "Russian"
        }
    }
}

enum OmniVoiceGenderStyle: String, CaseIterable, Identifiable {
    case none = ""
    case female
    case male

    var id: Self { self }

    var displayName: String {
        switch self {
        case .none: return "Default"
        case .female: return "Female"
        case .male: return "Male"
        }
    }
}

enum OmniVoiceAgeStyle: String, CaseIterable, Identifiable {
    case none = ""
    case child
    case teenager
    case youngAdult = "young adult"
    case middleAged = "middle-aged"
    case elderly

    var id: Self { self }

    var displayName: String {
        switch self {
        case .none: return "Default"
        case .child: return "Child"
        case .teenager: return "Teenager"
        case .youngAdult: return "Young adult"
        case .middleAged: return "Middle-aged"
        case .elderly: return "Elderly"
        }
    }
}

enum OmniVoicePitchStyle: String, CaseIterable, Identifiable {
    case none = ""
    case veryLow = "very low pitch"
    case low = "low pitch"
    case moderate = "moderate pitch"
    case high = "high pitch"
    case veryHigh = "very high pitch"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .none: return "Default"
        case .veryLow: return "Very low"
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .veryHigh: return "Very high"
        }
    }
}

enum OmniVoiceAccentStyle: String, CaseIterable, Identifiable {
    case none = ""
    case american = "american accent"
    case british = "british accent"
    case australian = "australian accent"
    case canadian = "canadian accent"
    case indian = "indian accent"
    case japanese = "japanese accent"
    case korean = "korean accent"
    case russian = "russian accent"
    case portuguese = "portuguese accent"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .none: return "Default"
        case .american: return "American"
        case .british: return "British"
        case .australian: return "Australian"
        case .canadian: return "Canadian"
        case .indian: return "Indian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .russian: return "Russian"
        case .portuguese: return "Portuguese"
        }
    }
}

/// User-facing toggles persisted in UserDefaults. Read by EventTap on each event,
/// so changes from the menubar take effect immediately without restart.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "lf.enabled"
        static let autoFlip = "lf.autoFlip"
        static let primary = "lf.primaryLanguage"
        static let secondary = "lf.secondaryLanguage"
        static let userBlacklist = "lf.userBlacklist"
        static let suppressInFullscreen = "lf.suppressInFullscreen"
        static let doubleCapsFix = "lf.doubleCapsFix"
        static let soundEnabled = "lf.soundEnabled"
        static let onboardingDone = "lf.onboardingDone"
        static let showOverlay = "lf.showOverlay"
        static let crossLayoutFix = "lf.crossLayoutFix"
        static let hotkeyPreset = "lf.hotkeyPreset"
        static let aiMode = "lf.aiMode"
        static let activeModelID = "lf.activeModelID"
        static let grammarCheckOnSingleShift = "lf.grammarCheckOnSingleShift"
        static let fixLastSentenceOnSingleShift = "lf.fixLastSentenceOnSingleShift"
        static let flipLastWordsOnDoubleShift = "lf.flipLastWordsOnDoubleShift"
        static let translationHotkeyEnabled = "lf.translationHotkeyEnabled"
        static let translationHotkeyPreset = "lf.translationHotkeyPreset"
        static let translationHotkeyCustom = "lf.translationHotkeyCustom"
        static let screenTextCaptureHotkeyEnabled = "lf.screenTextCaptureHotkeyEnabled"
        static let screenTextCaptureHotkeyPreset = "lf.screenTextCaptureHotkeyPreset"
        static let screenTextCaptureHotkeyCustom = "lf.screenTextCaptureHotkeyCustom"
        static let translationTarget = "lf.translationTarget"
        static let ollamaModel = "lf.ollamaModel"
        static let openaiModel = "lf.openaiModel"
        static let openaiBaseURL = "lf.openaiBaseURL"
        static let ttsBackend = "lf.ttsBackend"
        static let speechVoiceIdentifier = "lf.speechVoiceIdentifier"
        static let speechRate = "lf.speechRate"
        static let omniVoiceLanguage = "lf.omniVoiceLanguage"
        static let omniVoiceGender = "lf.omniVoiceGender"
        static let omniVoiceAge = "lf.omniVoiceAge"
        static let omniVoicePitch = "lf.omniVoicePitch"
        static let omniVoiceAccent = "lf.omniVoiceAccent"
        static let omniVoiceWhisper = "lf.omniVoiceWhisper"
        static let omniVoiceSpeed = "lf.omniVoiceSpeed"
        static let omniVoiceDuration = "lf.omniVoiceDuration"
        static let omniVoiceSentencePause = "lf.omniVoiceSentencePause"
        static let omniVoiceLinePause = "lf.omniVoiceLinePause"
        static let omniVoiceNumSteps = "lf.omniVoiceNumSteps"
        static let omniVoiceGuidanceScale = "lf.omniVoiceGuidanceScale"
        static let omniVoiceDenoise = "lf.omniVoiceDenoise"
        static let omniVoicePostprocessOutput = "lf.omniVoicePostprocessOutput"
        static let omniVoiceTShift = "lf.omniVoiceTShift"
        static let omniVoiceLayerPenaltyFactor = "lf.omniVoiceLayerPenaltyFactor"
        static let omniVoicePositionTemperature = "lf.omniVoicePositionTemperature"
        static let omniVoiceClassTemperature = "lf.omniVoiceClassTemperature"
        static let omniVoiceReferenceAudioPath = "lf.omniVoiceReferenceAudioPath"
        static let omniVoiceReferenceText = "lf.omniVoiceReferenceText"
        static let readSelectionHotkeyEnabled = "lf.readSelectionHotkeyEnabled"
        static let readSelectionHotkeyPreset = "lf.readSelectionHotkeyPreset"
        static let readSelectionHotkeyCustom = "lf.readSelectionHotkeyCustom"
        static let microphoneDeviceID = "lf.microphoneDeviceID"
        static let whisperModelPath = "lf.whisperModelPath"
        static let whisperLanguage = "lf.whisperLanguage"
        static let dictationPushToTalkEnabled = "lf.dictationPushToTalkEnabled"
        static let dictationPushToTalkShortcut = "lf.dictationPushToTalkShortcut"
        static let dictationHandsFreeEnabled = "lf.dictationHandsFreeEnabled"
        static let dictationHandsFreeShortcut = "lf.dictationHandsFreeShortcut"
    }

    var enabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    /// On by default. With the bundled ~45 k-word UK / RU lists plus
    /// /usr/share/dict/words for English, plus the BackspaceLearner
    /// safety net for any false positive that slips through, auto-flip
    /// is safe to ship enabled out of the box.
    var autoFlip: Bool {
        get { defaults.object(forKey: Keys.autoFlip) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoFlip) }
    }

    /// The non-English language that double-tap Shift swaps with. Always
    /// .uk or .ru — never .en (English is the implicit "other side").
    var primaryLanguage: Layout {
        get {
            guard let raw = defaults.string(forKey: Keys.primary),
                  let layout = Layout(rawValue: raw),
                  layout != .en
            else { return .uk }
            return layout
        }
        set {
            guard newValue != .en else { return }
            defaults.set(newValue.rawValue, forKey: Keys.primary)
            // If secondary now matches primary, clear it.
            if secondaryLanguage == newValue {
                secondaryLanguage = nil
            }
        }
    }

    /// Set to true once the user has completed the welcome / permissions
    /// wizard. Fresh installs land here at false → wizard shows. We also
    /// re-show the wizard on launch when permissions are missing,
    /// regardless of this flag, so users who revoke a permission later
    /// don't end up with a silently-broken app.
    var onboardingDone: Bool {
        get { defaults.object(forKey: Keys.onboardingDone) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.onboardingDone) }
    }

    /// Bouncy app-icon flourish at the bottom of the screen on every
    /// rewrite. On by default, matching the Preferences UI; users who
    /// find it distracting can turn it off in Preferences > Behavior.
    var showOverlay: Bool {
        get { defaults.object(forKey: Keys.showOverlay) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showOverlay) }
    }

    /// Plays a short system tick on every text rewrite (auto-flip, manual
    /// flip, sticky-shift fix, rollback). Off by default — sound feedback
    /// is divisive; users who like it can opt in.
    var soundEnabled: Bool {
        get { defaults.object(forKey: Keys.soundEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.soundEnabled) }
    }

    var ttsBackend: TextToSpeechBackend {
        get {
            guard let raw = defaults.string(forKey: Keys.ttsBackend),
                  let backend = TextToSpeechBackend(rawValue: raw)
            else { return .system }
            return backend
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.ttsBackend) }
    }

    var speechVoiceIdentifier: String {
        get { defaults.string(forKey: Keys.speechVoiceIdentifier) ?? "" }
        set { defaults.set(newValue, forKey: Keys.speechVoiceIdentifier) }
    }

    var speechRate: Double {
        get { defaults.object(forKey: Keys.speechRate) as? Double ?? 190 }
        set { defaults.set(newValue, forKey: Keys.speechRate) }
    }

    var omniVoiceLanguage: OmniVoiceLanguage {
        get {
            guard let raw = defaults.string(forKey: Keys.omniVoiceLanguage),
                  let value = OmniVoiceLanguage(rawValue: raw)
            else { return .auto }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.omniVoiceLanguage) }
    }

    var omniVoiceGender: OmniVoiceGenderStyle {
        get {
            guard let raw = defaults.string(forKey: Keys.omniVoiceGender),
                  let value = OmniVoiceGenderStyle(rawValue: raw)
            else { return .none }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.omniVoiceGender) }
    }

    var omniVoiceAge: OmniVoiceAgeStyle {
        get {
            guard let raw = defaults.string(forKey: Keys.omniVoiceAge),
                  let value = OmniVoiceAgeStyle(rawValue: raw)
            else { return .none }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.omniVoiceAge) }
    }

    var omniVoicePitch: OmniVoicePitchStyle {
        get {
            guard let raw = defaults.string(forKey: Keys.omniVoicePitch),
                  let value = OmniVoicePitchStyle(rawValue: raw)
            else { return .none }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.omniVoicePitch) }
    }

    var omniVoiceAccent: OmniVoiceAccentStyle {
        get {
            guard let raw = defaults.string(forKey: Keys.omniVoiceAccent),
                  let value = OmniVoiceAccentStyle(rawValue: raw)
            else { return .none }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.omniVoiceAccent) }
    }

    var omniVoiceWhisper: Bool {
        get { defaults.object(forKey: Keys.omniVoiceWhisper) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.omniVoiceWhisper) }
    }

    var omniVoiceSpeed: Double {
        get { defaults.object(forKey: Keys.omniVoiceSpeed) as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: Keys.omniVoiceSpeed) }
    }

    /// 0 means "let OmniVoice estimate duration". Positive values are
    /// passed as --duration and override speed, matching OmniVoice's CLI.
    var omniVoiceDuration: Double {
        get { defaults.object(forKey: Keys.omniVoiceDuration) as? Double ?? 0.0 }
        set { defaults.set(newValue, forKey: Keys.omniVoiceDuration) }
    }

    var omniVoiceSentencePause: Double {
        get { defaults.object(forKey: Keys.omniVoiceSentencePause) as? Double ?? 0.35 }
        set { defaults.set(newValue, forKey: Keys.omniVoiceSentencePause) }
    }

    var omniVoiceLinePause: Double {
        get { defaults.object(forKey: Keys.omniVoiceLinePause) as? Double ?? 0.75 }
        set { defaults.set(newValue, forKey: Keys.omniVoiceLinePause) }
    }

    var omniVoiceNumSteps: Int {
        get { defaults.object(forKey: Keys.omniVoiceNumSteps) as? Int ?? 32 }
        set { defaults.set(newValue, forKey: Keys.omniVoiceNumSteps) }
    }

    var omniVoiceGuidanceScale: Double {
        get { defaults.object(forKey: Keys.omniVoiceGuidanceScale) as? Double ?? 2.0 }
        set { defaults.set(newValue, forKey: Keys.omniVoiceGuidanceScale) }
    }

    var omniVoiceDenoise: Bool {
        get { defaults.object(forKey: Keys.omniVoiceDenoise) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.omniVoiceDenoise) }
    }

    var omniVoicePostprocessOutput: Bool {
        get { defaults.object(forKey: Keys.omniVoicePostprocessOutput) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.omniVoicePostprocessOutput) }
    }

    var omniVoiceTShift: Double {
        get { defaults.object(forKey: Keys.omniVoiceTShift) as? Double ?? 0.1 }
        set { defaults.set(newValue, forKey: Keys.omniVoiceTShift) }
    }

    var omniVoiceLayerPenaltyFactor: Double {
        get { defaults.object(forKey: Keys.omniVoiceLayerPenaltyFactor) as? Double ?? 5.0 }
        set { defaults.set(newValue, forKey: Keys.omniVoiceLayerPenaltyFactor) }
    }

    var omniVoicePositionTemperature: Double {
        get { defaults.object(forKey: Keys.omniVoicePositionTemperature) as? Double ?? 5.0 }
        set { defaults.set(newValue, forKey: Keys.omniVoicePositionTemperature) }
    }

    var omniVoiceClassTemperature: Double {
        get { defaults.object(forKey: Keys.omniVoiceClassTemperature) as? Double ?? 0.0 }
        set { defaults.set(newValue, forKey: Keys.omniVoiceClassTemperature) }
    }

    func resetOmniVoiceGenerationSettings() {
        defaults.set(1.0, forKey: Keys.omniVoiceSpeed)
        defaults.set(0.0, forKey: Keys.omniVoiceDuration)
        defaults.set(0.35, forKey: Keys.omniVoiceSentencePause)
        defaults.set(0.75, forKey: Keys.omniVoiceLinePause)
        defaults.set(32, forKey: Keys.omniVoiceNumSteps)
        defaults.set(2.0, forKey: Keys.omniVoiceGuidanceScale)
        defaults.set(true, forKey: Keys.omniVoiceDenoise)
        defaults.set(true, forKey: Keys.omniVoicePostprocessOutput)
        defaults.set(0.1, forKey: Keys.omniVoiceTShift)
        defaults.set(5.0, forKey: Keys.omniVoiceLayerPenaltyFactor)
        defaults.set(5.0, forKey: Keys.omniVoicePositionTemperature)
        defaults.set(0.0, forKey: Keys.omniVoiceClassTemperature)
    }

    var omniVoiceReferenceAudioPath: String {
        get { defaults.string(forKey: Keys.omniVoiceReferenceAudioPath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.omniVoiceReferenceAudioPath) }
    }

    var omniVoiceReferenceText: String {
        get { defaults.string(forKey: Keys.omniVoiceReferenceText) ?? "" }
        set { defaults.set(newValue, forKey: Keys.omniVoiceReferenceText) }
    }

    var readSelectionHotkeyEnabled: Bool {
        get { defaults.object(forKey: Keys.readSelectionHotkeyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.readSelectionHotkeyEnabled) }
    }

    var readSelectionHotkeyPreset: GlobalShortcutPreset {
        get {
            guard let raw = defaults.string(forKey: Keys.readSelectionHotkeyPreset),
                  let preset = GlobalShortcutPreset(rawValue: raw)
            else { return .controlOptionX }
            return preset
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.readSelectionHotkeyPreset) }
    }

    var readSelectionShortcut: GlobalShortcut {
        GlobalShortcut.decode(defaults.string(forKey: Keys.readSelectionHotkeyCustom))
            ?? readSelectionHotkeyPreset.shortcut
    }

    var microphoneDeviceID: String {
        get { defaults.string(forKey: Keys.microphoneDeviceID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.microphoneDeviceID) }
    }

    var whisperModelPath: String {
        get { defaults.string(forKey: Keys.whisperModelPath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.whisperModelPath) }
    }

    var whisperLanguage: String {
        get { defaults.string(forKey: Keys.whisperLanguage) ?? "auto" }
        set { defaults.set(newValue, forKey: Keys.whisperLanguage) }
    }

    var dictationPushToTalkEnabled: Bool {
        get { defaults.object(forKey: Keys.dictationPushToTalkEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.dictationPushToTalkEnabled) }
    }

    var dictationPushToTalkShortcut: DictationPushToTalkShortcut {
        get {
            guard let raw = defaults.string(forKey: Keys.dictationPushToTalkShortcut),
                  let shortcut = DictationPushToTalkShortcut(rawValue: raw)
            else { return .anyShift }
            return shortcut
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.dictationPushToTalkShortcut) }
    }

    var dictationHandsFreeEnabled: Bool {
        get { defaults.object(forKey: Keys.dictationHandsFreeEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.dictationHandsFreeEnabled) }
    }

    var dictationHandsFreeShortcut: DictationHandsFreeShortcut {
        get {
            guard let raw = defaults.string(forKey: Keys.dictationHandsFreeShortcut),
                  let shortcut = DictationHandsFreeShortcut(rawValue: raw)
            else { return .commandShift }
            return shortcut
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.dictationHandsFreeShortcut) }
    }

    /// Optional AI assistant mode. `.off` keeps the app entirely rules-
    /// based (default and minimum-surprise behaviour); `.appleFoundation`
    /// uses the macOS-26 system model; `.bundledModel` runs a downloaded
    /// MLX model whose identifier is in `activeModelID`.
    var aiMode: AIMode {
        get {
            guard let raw = defaults.string(forKey: Keys.aiMode),
                  let value = AIMode(rawValue: raw)
            else { return .off }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.aiMode) }
    }

    private init() {}

    /// When true, a single clean Shift tap (no other key in between, no
    /// second tap within the window) fires an AI grammar / typo pass on
    /// the current selection and silently applies the result. LangFlip
    /// enables this automatically after a local Ollama model is ready.
    var grammarCheckOnSingleShift: Bool {
        get { defaults.object(forKey: Keys.grammarCheckOnSingleShift) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.grammarCheckOnSingleShift) }
    }

    /// If single Shift finds no selected text, read the focused text
    /// field through Accessibility, extract the last sentence before the
    /// cursor, and ask AI to clean only that range.
    var fixLastSentenceOnSingleShift: Bool {
        get { defaults.object(forKey: Keys.fixLastSentenceOnSingleShift) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.fixLastSentenceOnSingleShift) }
    }

    /// If double Shift finds no selected text, read the focused text
    /// field through Accessibility and flip the last wrong-layout word
    /// run before the cursor.
    var flipLastWordsOnDoubleShift: Bool {
        get { defaults.object(forKey: Keys.flipLastWordsOnDoubleShift) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.flipLastWordsOnDoubleShift) }
    }

    /// When true, ⇧Space (Shift+Space) translates the current text
    /// selection into `translationTarget`. LangFlip enables this
    /// automatically after a local Ollama model is ready. Users can
    /// still turn it off and that choice sticks.
    var translationHotkeyEnabled: Bool {
        get { defaults.object(forKey: Keys.translationHotkeyEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.translationHotkeyEnabled) }
    }

    var translationHotkeyPreset: GlobalShortcutPreset {
        get {
            guard let raw = defaults.string(forKey: Keys.translationHotkeyPreset),
                  let preset = GlobalShortcutPreset(rawValue: raw)
            else { return .shiftSpace }
            return preset
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.translationHotkeyPreset) }
    }

    var translationShortcut: GlobalShortcut {
        GlobalShortcut.decode(defaults.string(forKey: Keys.translationHotkeyCustom))
            ?? translationHotkeyPreset.shortcut
    }

    func applyRecommendedAIHotkeyDefaults(assistantReady: Bool) {
        guard aiMode == .ollama, assistantReady else { return }
        if defaults.object(forKey: Keys.grammarCheckOnSingleShift) == nil {
            defaults.set(true, forKey: Keys.grammarCheckOnSingleShift)
        }
        if defaults.object(forKey: Keys.translationHotkeyEnabled) == nil {
            defaults.set(true, forKey: Keys.translationHotkeyEnabled)
        }
    }

    var hasStoredTranslationHotkeyPreference: Bool {
        defaults.object(forKey: Keys.translationHotkeyEnabled) != nil
    }

    /// When true, ⇧⌘S starts the screen-region OCR flow for vision-capable
    /// local models. On by default because it is explicit and fast, but
    /// users can disable it if it conflicts with Save As / Duplicate in
    /// their day-to-day apps.
    var screenTextCaptureHotkeyEnabled: Bool {
        get { defaults.object(forKey: Keys.screenTextCaptureHotkeyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.screenTextCaptureHotkeyEnabled) }
    }

    var screenTextCaptureHotkeyPreset: GlobalShortcutPreset {
        get {
            guard let raw = defaults.string(forKey: Keys.screenTextCaptureHotkeyPreset),
                  let preset = GlobalShortcutPreset(rawValue: raw)
            else { return .commandShiftS }
            return preset
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.screenTextCaptureHotkeyPreset) }
    }

    var screenTextCaptureShortcut: GlobalShortcut {
        GlobalShortcut.decode(defaults.string(forKey: Keys.screenTextCaptureHotkeyCustom))
            ?? screenTextCaptureHotkeyPreset.shortcut
    }

    /// Default target language for the translate-selection feature.
    /// Used by Shift+Space and as the highlighted entry in the
    /// menubar submenu. Defaults to English — most non-English users
    /// most often translate INTO English for shared communication.
    var translationTarget: Layout {
        get {
            guard let raw = defaults.string(forKey: Keys.translationTarget),
                  let layout = Layout(rawValue: raw)
            else { return .en }
            return layout
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.translationTarget) }
    }

    /// Ollama model tag (e.g. "qwen3.5:2b", "qwen3.5:4b").
    /// Used only when `aiMode == .ollama`. Default `qwen3.5:2b` so
    /// new users get a fast, low-memory model that can handle both
    /// grammar fixes and screen-text capture. Users can switch to the
    /// heavier 4B quality option in Preferences.
    var ollamaModel: String {
        get {
            let raw = defaults.string(forKey: Keys.ollamaModel)?.trimmingCharacters(in: .whitespaces)
            return (raw?.isEmpty == false) ? raw! : "qwen3.5:2b"
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            defaults.set(trimmed, forKey: Keys.ollamaModel)
        }
    }

    /// API key for the OpenAI-compatible cloud backend. Persisted in
    /// Keychain (NOT UserDefaults) so it's encrypted at rest with the
    /// user's login key. Setting nil deletes the entry. Setting an
    /// empty string also deletes (so users can clear by erasing the
    /// field in Preferences).
    var openaiAPIKey: String? {
        get { KeychainStore.getString(account: KeychainStore.openAIAPIKey) }
        set { KeychainStore.setString(newValue, account: KeychainStore.openAIAPIKey) }
    }

    /// Model identifier sent in the chat-completions `model` field.
    /// Default `gpt-5-nano` works on api.openai.com out of the box;
    /// users on OpenRouter / Together / Groq paste their own value
    /// (e.g. `gpt-oss-120b`, `meta-llama/llama-3.2-90b-vision`,
    /// `anthropic/claude-3.7-sonnet`).
    var openaiModel: String {
        get {
            let raw = defaults.string(forKey: Keys.openaiModel)?.trimmingCharacters(in: .whitespaces)
            return (raw?.isEmpty == false) ? raw! : "gpt-5-nano"
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            defaults.set(trimmed, forKey: Keys.openaiModel)
        }
    }

    /// Base URL of the OpenAI-compatible endpoint. Default points at
    /// OpenAI direct. Common alternatives:
    ///   - https://openrouter.ai/api/v1
    ///   - https://api.together.xyz/v1
    ///   - https://api.fireworks.ai/inference/v1
    ///   - https://api.groq.com/openai/v1
    /// LangFlip appends `/chat/completions` to whatever you set here.
    var openaiBaseURL: String {
        get {
            let raw = defaults.string(forKey: Keys.openaiBaseURL)?.trimmingCharacters(in: .whitespaces)
            return (raw?.isEmpty == false) ? raw! : "https://api.openai.com/v1"
        }
        set {
            // Strip trailing slash to keep `<base>/chat/completions`
            // joining clean across URLComponents implementations.
            var trimmed = newValue.trimmingCharacters(in: .whitespaces)
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            defaults.set(trimmed, forKey: Keys.openaiBaseURL)
        }
    }

    /// When `aiMode == .bundledModel`, identifies which catalog entry to
    /// load. nil before the first download. See `ModelCatalog`.
    var activeModelID: String? {
        get { defaults.string(forKey: Keys.activeModelID) }
        set { defaults.set(newValue, forKey: Keys.activeModelID) }
    }

    /// Which gesture should trigger a flip. Default `.doubleShift` keeps
    /// the muscle memory most users expect.
    var hotkeyPreset: HotkeyPreset {
        get {
            guard let raw = defaults.string(forKey: Keys.hotkeyPreset),
                  let value = HotkeyPreset(rawValue: raw)
            else { return .doubleShift }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.hotkeyPreset) }
    }

    /// Catches single-letter mix-ups between Ukrainian-only and Russian-
    /// only letters (ы↔і, э↔є). On by default — strict dict check makes
    /// false positives rare. See CrossLayoutFix.swift.
    var crossLayoutFix: Bool {
        get { defaults.object(forKey: Keys.crossLayoutFix) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.crossLayoutFix) }
    }

    /// Sticky-shift correction. On by default — matches Caramba's behaviour
    /// and the cost of a false positive is low (DoubleCapsFix verifies the
    /// correction is a real dictionary word before applying).
    var doubleCapsFix: Bool {
        get { defaults.object(forKey: Keys.doubleCapsFix) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.doubleCapsFix) }
    }

    /// When true, auto-flip stays silent while the focused window is in
    /// true fullscreen mode (size matches a screen). Off by default —
    /// users may want to flip inside a fullscreen browser, slack, etc.
    var suppressInFullscreen: Bool {
        get { defaults.object(forKey: Keys.suppressInFullscreen) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.suppressInFullscreen) }
    }

    /// Bundle IDs the user has explicitly opted out of auto-flip for. The
    /// hard-coded blocklist in AppContext is separate; this is the set
    /// users grow themselves via the menubar's "Disable auto-flip in [App]"
    /// item.
    var userBlacklist: Set<String> {
        get {
            let arr = defaults.array(forKey: Keys.userBlacklist) as? [String] ?? []
            return Set(arr)
        }
        set {
            defaults.set(Array(newValue), forKey: Keys.userBlacklist)
        }
    }

    /// Optional second non-English language that triple-tap Shift swaps with.
    /// Fresh installs default to the opposite Slavic language so double Shift
    /// targets Ukrainian and triple Shift targets Russian out of the box.
    /// If the user explicitly picks None, the stored empty string keeps
    /// triple-tap as a no-op.
    var secondaryLanguage: Layout? {
        get {
            guard let raw = defaults.string(forKey: Keys.secondary) else {
                return primaryLanguage == .uk ? .ru : .uk
            }
            guard !raw.isEmpty,
                  let layout = Layout(rawValue: raw),
                  layout != .en,
                  layout != primaryLanguage
            else { return nil }
            return layout
        }
        set {
            if let newValue, newValue != .en, newValue != primaryLanguage {
                defaults.set(newValue.rawValue, forKey: Keys.secondary)
            } else {
                defaults.removeObject(forKey: Keys.secondary)
            }
        }
    }
}
