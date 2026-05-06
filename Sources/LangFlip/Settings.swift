import Foundation

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
    }

    var enabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    /// Off by default — the embedded UK / RU word lists are still small and
    /// the heuristic produces false positives outside the top-N most common
    /// words. Manual hotkey is the recommended trigger until the dicts grow.
    var autoFlip: Bool {
        get { defaults.object(forKey: Keys.autoFlip) as? Bool ?? false }
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
