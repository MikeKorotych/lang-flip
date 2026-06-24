import Foundation

/// One-time migration for the LangFlip → Sayful identity rename (new bundle id
/// + renamed data directories). Without it, existing dogfood installs would
/// look "reset": the new bundle id gets a fresh, empty UserDefaults domain and
/// the app would write to a brand-new `Application Support/Sayful` folder,
/// orphaning the user's settings, snippets, learned exceptions, dictionaries,
/// models, and recordings.
///
/// Best-effort and idempotent — guarded by a flag in the new defaults domain,
/// and never throws. Keychain is intentionally NOT migrated: `KeychainStore`
/// uses a fixed service string (the old bundle id), so stored API keys are
/// found unchanged regardless of the app's current bundle id.
enum IdentityMigration {
    private static let oldBundleID = "com.antonpinkevych.lang-flip"
    private static let migratedFlag = "lf.migratedFromLangFlip"

    /// Run once, as early as possible at launch — before any `Settings`/
    /// `@AppStorage` read and before the first log write (the Logs dir is one
    /// of the directories being moved).
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlag) else { return }

        migrateUserDefaults(into: defaults)
        migrateSupportDirectories()

        defaults.set(true, forKey: migratedFlag)
    }

    /// Copy our `lf.*` settings from the old bundle-id defaults domain into the
    /// current (new bundle id) domain. Only fills keys not already present, so
    /// re-runs and fresh installs are safe. Limited to the `lf.` prefix so we
    /// don't drag across AppKit window-frame / Sparkle bookkeeping keys.
    private static func migrateUserDefaults(into defaults: UserDefaults) {
        guard let oldDomain = defaults.persistentDomain(forName: oldBundleID),
              !oldDomain.isEmpty else { return }
        for (key, value) in oldDomain where key.hasPrefix("lf.") {
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }

    /// Move on-disk data dirs from the old name to the new one when the new one
    /// doesn't exist yet (a plain rename preserves dictionaries, models,
    /// recordings, generated audio, and runtimes).
    private static func migrateSupportDirectories() {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let moves = [
            ("\(home)/Library/Application Support/LangFlip", "\(home)/Library/Application Support/Sayful"),
            ("\(home)/Library/Logs/LangFlip", "\(home)/Library/Logs/Sayful"),
        ]
        for (old, new) in moves {
            guard fm.fileExists(atPath: old), !fm.fileExists(atPath: new) else { continue }
            try? fm.moveItem(atPath: old, toPath: new)
        }
    }
}
