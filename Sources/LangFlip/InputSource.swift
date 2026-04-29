import Foundation
import Carbon

enum InputSource {
    /// Selects the first enabled keyboard input source whose ID contains
    /// any of the given substrings (e.g. "ABC", "Ukrainian", "Russian").
    static func selectMatching(_ needles: [String]) {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        for src in list {
            guard let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            for needle in needles where id.localizedCaseInsensitiveContains(needle) {
                TISSelectInputSource(src)
                return
            }
        }
    }

    static func currentLayout() -> Layout? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        let lower = id.lowercased()
        if lower.contains("ukrainian") { return .uk }
        if lower.contains("russian") { return .ru }
        if lower.contains("abc") || lower.contains("us") || lower.contains("english") { return .en }
        return nil
    }

    static func switchTo(_ layout: Layout) {
        switch layout {
        case .en: selectMatching(["com.apple.keylayout.ABC", "com.apple.keylayout.US", "ABC", "US"])
        case .uk: selectMatching(["Ukrainian"])
        case .ru: selectMatching(["Russian"])
        }
    }
}
