import Foundation
import Carbon.HIToolbox

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
        static let grammarCheckOnSentenceEnd = "lf.grammarCheckOnSentenceEnd"
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
    /// rewrite. Off by default — pure delight, can be distracting if
    /// flipping happens often. Opt in via Preferences > Behavior.
    var showOverlay: Bool {
        get { defaults.object(forKey: Keys.showOverlay) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showOverlay) }
    }

    /// Plays a short system tick on every text rewrite (auto-flip, manual
    /// flip, sticky-shift fix, rollback). Off by default — sound feedback
    /// is divisive; users who like it can opt in.
    var soundEnabled: Bool {
        get { defaults.object(forKey: Keys.soundEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.soundEnabled) }
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

    /// When true, a single clean Shift tap (no other key in between, no
    /// second tap within the window) fires an AI grammar / typo pass on
    /// the last sentence and silently applies the result. Speculative
    /// inference starts at the moment Shift is released so the felt
    /// latency is just the tap window. Default OFF — single Shift is
    /// too low-friction to ship enabled out of the box.
    var grammarCheckOnSingleShift: Bool {
        get { defaults.object(forKey: Keys.grammarCheckOnSingleShift) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.grammarCheckOnSingleShift) }
    }

    /// When true, typing a sentence-ending punctuation mark (`.`, `!`, `?`)
    /// kicks off an AI grammar / typo pass on the just-completed sentence
    /// and silently applies the result. The fix is dropped if the user
    /// kept typing past the next sentence boundary while the model was
    /// thinking, so fast typists never get the rug pulled out from under
    /// them. Default OFF — auto-rewriting prose without an explicit
    /// gesture is high-impact and we want users to opt in.
    var grammarCheckOnSentenceEnd: Bool {
        get { defaults.object(forKey: Keys.grammarCheckOnSentenceEnd) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.grammarCheckOnSentenceEnd) }
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
    /// nil means triple-tap is a no-op (and double-tap fires without grace
    /// delay, since there's nothing to wait for).
    var secondaryLanguage: Layout? {
        get {
            guard let raw = defaults.string(forKey: Keys.secondary),
                  !raw.isEmpty,
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
