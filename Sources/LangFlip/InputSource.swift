import Foundation
import Carbon

/// Wrapper around the Text Input Source (TIS) API used to read and switch the
/// system keyboard layout.
///
/// Language detection uses the `kTISPropertyInputSourceLanguages` property
/// instead of substring-matching the bundle ID — much more robust because:
///   - bundle IDs like `com.apple.keylayout.RussianPhonetic` could once have
///     spuriously matched the legacy `"US"` needle (`russian` contains `us`)
///   - language codes are stable across macOS versions and third-party layouts
enum InputSource {

    /// Maps our `Layout` enum to the BCP-47 language code used by TIS.
    private static func languageCode(for layout: Layout) -> String {
        switch layout {
        case .en: return "en"
        case .uk: return "uk"
        case .ru: return "ru"
        }
    }

    private static let keyboardCategory = kTISCategoryKeyboardInputSource as String

    /// Reads the languages array of an input source. Returns an empty array
    /// if unavailable.
    private static func languages(of src: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
    }

    /// Returns true if `src` is a keyboard layout (not a handwriting / IME
    /// source — picking those would be wrong).
    private static func isKeyboardLayout(_ src: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory) else { return false }
        let category = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        return category == keyboardCategory
    }

    /// Layout currently selected by the user, or nil if it isn't one we know.
    static func currentLayout() -> Layout? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        for code in languages(of: src) {
            if let layout = Layout.allCases.first(where: { languageCode(for: $0) == code }) {
                return layout
            }
        }
        return nil
    }

    /// Switches the system input source to a keyboard layout whose primary
    /// language matches the requested `Layout`.
    static func switchTo(_ layout: Layout) {
        let target = languageCode(for: layout)
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return }

        // Prefer sources whose first (primary) language matches; fall back to
        // any source that lists the language at all.
        var primaryMatch: TISInputSource?
        var anyMatch: TISInputSource?

        for src in list where isKeyboardLayout(src) {
            let langs = languages(of: src)
            if langs.first == target {
                primaryMatch = src
                break
            }
            if anyMatch == nil, langs.contains(target) {
                anyMatch = src
            }
        }

        if let src = primaryMatch ?? anyMatch {
            TISSelectInputSource(src)
        }
    }
}
