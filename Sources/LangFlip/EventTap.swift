import Foundation
import CoreGraphics
import Carbon.HIToolbox

final class EventTap {
    private let buffer = WordBuffer()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Flag set while we synthesize keystrokes ourselves, so we ignore the
    /// events we just posted and don't feed them back into the buffer.
    private var isSimulating = false

    /// Hotkey: ⌃⌥⌘ + Backslash (kVK_ANSI_Backslash). Unique enough not to clash.
    private let hotkeyKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_Backslash)
    private let hotkeyMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    func start() throws {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let opaque = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: opaque
        ) else {
            throw NSError(domain: "lang-flip", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create event tap. Grant Accessibility + Input Monitoring permission to this binary."])
        }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if isSimulating { return Unmanaged.passUnretained(event) }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Master kill-switch from menubar.
        guard Settings.shared.enabled else { return Unmanaged.passUnretained(event) }

        if keyCode == hotkeyKeyCode && flags.intersection(hotkeyMask) == hotkeyMask {
            convertLastWord(force: true)
            return nil // swallow the hotkey
        }

        // Track what the user types into the word buffer.
        if keyCode == CGKeyCode(kVK_Delete) {
            buffer.backspace()
        } else {
            var len = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &len, unicodeString: &chars)
            if len > 0 {
                let s = String(utf16CodeUnits: chars, count: len)
                if let completed = buffer.feedReturningCompleted(s),
                   Settings.shared.autoFlip {
                    autoFlipIfNeeded(completedWord: completed)
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Called right after the user typed a boundary char (space, punctuation).
    /// `completedWord` is whatever was in the buffer before the boundary.
    /// At this point the boundary char has already been emitted to the focused
    /// app and the word is N characters back behind that boundary.
    private func autoFlipIfNeeded(completedWord: String) {
        guard let current = InputSource.currentLayout() else { return }
        guard let target = AutoFlip.shared.suggestedFlip(for: completedWord, currentLayout: current) else { return }
        let converted = convert(completedWord, from: current, to: target)
        guard converted != completedWord else { return }

        isSimulating = true
        defer { isSimulating = false }

        // Erase: word + the boundary char that came after it.
        let eraseCount = completedWord.count + 1
        for _ in 0..<eraseCount {
            postKey(virtualKey: CGKeyCode(kVK_Delete))
        }

        InputSource.switchTo(target)
        for ch in converted { postUnicode(String(ch)) }
        // Re-emit the original boundary (space) — keeps the user's flow intact.
        postUnicode(" ")
    }

    private func convertLastWord(force: Bool = false) {
        let word = buffer.current
        guard !word.isEmpty else { return }
        guard let from = detectLayout(word) else { return }

        // Target layout: anything non-EN converts to EN; EN converts to UK by default.
        // Quick heuristic — works for most "I typed in the wrong layout" cases.
        let to: Layout = (from == .en) ? .uk : .en
        _ = force // currently unused; kept for future "always flip" semantics

        let converted = convert(word, from: from, to: to)
        guard converted != word else { return }

        isSimulating = true
        defer { isSimulating = false }

        // Erase the typed word.
        let count = word.count
        for _ in 0..<count {
            postKey(virtualKey: CGKeyCode(kVK_Delete))
        }

        // Switch system input source.
        InputSource.switchTo(to)

        // Type the converted string. Use unicode string injection so we don't
        // depend on knowing the keycode for every char in every layout.
        for ch in converted {
            postUnicode(String(ch))
        }

        // Update buffer to reflect the new state.
        buffer.reset()
        buffer.feed(converted)
    }

    private func postKey(virtualKey: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func postUnicode(_ s: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let chars = Array(s.utf16)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            chars.withUnsafeBufferPointer { ptr in
                down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            chars.withUnsafeBufferPointer { ptr in
                up.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            up.post(tap: .cghidEventTap)
        }
    }
}
