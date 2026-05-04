import Foundation

/// User-facing toggles persisted in UserDefaults. Read by EventTap on each event,
/// so changes from the menubar take effect immediately without restart.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "lf.enabled"
        static let autoFlip = "lf.autoFlip"
    }

    var enabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    var autoFlip: Bool {
        get { defaults.object(forKey: Keys.autoFlip) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoFlip) }
    }
}
