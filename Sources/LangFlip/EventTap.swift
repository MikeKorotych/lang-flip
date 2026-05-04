import Foundation
import CoreGraphics
import Carbon.HIToolbox

final class EventTap {
    private let buffer = WordBuffer()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Magic value stamped on every synthesized event so we can recognise our
    /// own keystrokes when they round-trip through the tap and ignore them.
    /// Without this we get a feedback loop because `event.post` is async and
    /// any boolean "isSimulating" flag has already flipped back by the time
    /// the events reach our callback.
    private static let userDataMagic: Int64 = 0x1A4C46_4C49 // "LFLI"

    /// Set LANG_FLIP_DEBUG=1 in the environment to log every keystroke seen.
    private let debug = ProcessInfo.processInfo.environment["LANG_FLIP_DEBUG"] == "1"

    // MARK: - Double-shift hotkey state

    /// Maximum gap between the two Shift releases for them to count as a
    /// double-tap (matches Caramba's feel — ~300–400ms).
    private static let doubleShiftWindow: TimeInterval = 0.40

    /// Time of the most recent "clean" Shift release (one where Shift wasn't
    /// used as a modifier on another key). nil means no pending tap.
    private var lastCleanShiftRelease: Date?

    /// Set true on any non-shift keyDown event while Shift is held — it means
    /// the user used Shift as a real modifier, not as a hotkey tap.
    private var shiftUsedAsModifier = false

    /// Whether a Shift key is currently held.
    private var shiftCurrentlyHeld = false

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

        // Reliably ignore our own synthesized events — see comment on userDataMagic.
        if event.getIntegerValueField(.eventSourceUserData) == Self.userDataMagic {
            return Unmanaged.passUnretained(event)
        }

        // Master kill-switch from menubar.
        guard Settings.shared.enabled else { return Unmanaged.passUnretained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if type == .flagsChanged {
            handleFlagsChanged(keyCode: keyCode, flags: flags)
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if debug {
            let masked = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            FileHandle.standardError.write(Data("lang-flip[debug]: keyDown keyCode=\(keyCode) flags=\(String(masked.rawValue, radix: 16))\n".utf8))
        }

        // Any keypress while Shift is held disqualifies the current Shift
        // press from being interpreted as a hotkey tap.
        if shiftCurrentlyHeld {
            shiftUsedAsModifier = true
        }
        // Cancel any pending double-tap if the user typed something between taps.
        lastCleanShiftRelease = nil

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

    private func handleFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) {
        let isShiftKey = (keyCode == CGKeyCode(kVK_Shift) || keyCode == CGKeyCode(kVK_RightShift))
        guard isShiftKey else {
            // Some other modifier changed — cancel pending double-tap.
            lastCleanShiftRelease = nil
            return
        }

        let nowDown = flags.contains(.maskShift)

        if nowDown {
            // Shift just went down.
            shiftCurrentlyHeld = true
            shiftUsedAsModifier = false
        } else {
            // Shift just went up.
            shiftCurrentlyHeld = false
            defer { shiftUsedAsModifier = false }

            // If Shift was used as a real modifier (e.g. Shift+a → "A"),
            // it doesn't count as a tap.
            guard !shiftUsedAsModifier else {
                lastCleanShiftRelease = nil
                return
            }

            let now = Date()
            if let last = lastCleanShiftRelease,
               now.timeIntervalSince(last) <= Self.doubleShiftWindow {
                // Second tap inside the window → DOUBLE-SHIFT.
                lastCleanShiftRelease = nil
                if debug { FileHandle.standardError.write(Data("lang-flip[debug]: double-shift detected\n".utf8)) }
                // Defer to the next runloop tick so the Shift release event
                // settles before we start posting synthesized events.
                DispatchQueue.main.async { [weak self] in
                    self?.convertLastWord()
                }
            } else {
                lastCleanShiftRelease = now
            }
        }
    }

    /// Called right after the user typed a boundary char (space, punctuation).
    /// At this point the boundary char has already reached the focused app, so
    /// we erase `word.count + 1` characters before retyping.
    private func autoFlipIfNeeded(completedWord: String) {
        guard let current = InputSource.currentLayout() else { return }
        guard let target = AutoFlip.shared.suggestedFlip(for: completedWord, currentLayout: current) else { return }
        let converted = convert(completedWord, from: current, to: target)
        guard converted != completedWord else { return }

        let eraseCount = completedWord.count + 1
        for _ in 0..<eraseCount { postKey(virtualKey: CGKeyCode(kVK_Delete)) }
        InputSource.switchTo(target)
        for ch in converted { postUnicode(String(ch)) }
        postUnicode(" ")
    }

    private func convertLastWord() {
        let word = buffer.current
        guard !word.isEmpty else { return }
        guard let from = detectLayout(word) else { return }
        let to: Layout = (from == .en) ? .uk : .en

        let converted = convert(word, from: from, to: to)
        guard converted != word else { return }

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: converting '\(word)' (\(from)) → '\(converted)' (\(to))\n".utf8)) }

        for _ in 0..<word.count { postKey(virtualKey: CGKeyCode(kVK_Delete)) }
        InputSource.switchTo(to)
        for ch in converted { postUnicode(String(ch)) }

        buffer.reset()
        buffer.feed(converted)
    }

    // MARK: - Posting synthesized events

    /// Build a fresh event source. We avoid `.combinedSessionState` because it
    /// inherits the user's currently-pressed modifier flags, which is exactly
    /// what we don't want.
    private func makeSource() -> CGEventSource? {
        return CGEventSource(stateID: .privateState)
    }

    private func stamp(_ event: CGEvent) {
        // Erase any inherited modifier flags AND tag the event so we recognise
        // it on round-trip.
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: Self.userDataMagic)
    }

    private func postKey(virtualKey: CGKeyCode) {
        let src = makeSource()
        if let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true) {
            stamp(down)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) {
            stamp(up)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postUnicode(_ s: String) {
        let src = makeSource()
        let chars = Array(s.utf16)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            chars.withUnsafeBufferPointer { ptr in
                down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            stamp(down)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            chars.withUnsafeBufferPointer { ptr in
                up.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            stamp(up)
            up.post(tap: .cghidEventTap)
        }
    }
}
