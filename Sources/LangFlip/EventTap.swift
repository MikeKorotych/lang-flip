import Foundation
import AppKit
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

    // MARK: - Multi-tap Shift hotkey state

    /// Maximum gap between two consecutive Shift releases for them to count
    /// as part of the same tap sequence.
    private static let tapWindow: TimeInterval = 0.35

    /// After detecting a double-tap, wait this long before committing — gives
    /// the user time to add a third tap and trigger the secondary action.
    /// Only applied when a secondary language is configured; otherwise we
    /// fire double-tap immediately to keep latency identical to v0.1.
    private static let tripleGrace: TimeInterval = 0.20

    /// How long the polling loop waits for the focused app to update the
    /// pasteboard after we synthesize Cmd+C.
    private static let copyPollDeadline: TimeInterval = 0.25
    private static let copyPollInterval: TimeInterval = 0.015

    /// How long to wait after synthesizing Cmd+V before restoring the user's
    /// original clipboard. Some slow apps (Pages, MS Word) read the
    /// pasteboard with a debounce; if we restore too eagerly they consume
    /// the original text instead of our converted text.
    private static let pasteRestoreDelay: TimeInterval = 0.30

    private var tapCount = 0
    private var lastShiftReleaseTime: Date?
    private var pendingFire: DispatchWorkItem?

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
        // Any non-shift keypress cancels any pending tap sequence.
        cancelPendingTaps()

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
            // Some other modifier changed — cancel pending taps.
            cancelPendingTaps()
            return
        }

        let nowDown = flags.contains(.maskShift)

        if nowDown {
            shiftCurrentlyHeld = true
            shiftUsedAsModifier = false
        } else {
            shiftCurrentlyHeld = false
            defer { shiftUsedAsModifier = false }
            guard !shiftUsedAsModifier else {
                cancelPendingTaps()
                return
            }
            registerCleanShiftTap()
        }
    }

    // MARK: - Tap counting

    private func registerCleanShiftTap() {
        let now = Date()
        if let last = lastShiftReleaseTime, now.timeIntervalSince(last) > Self.tapWindow {
            tapCount = 0
        }
        lastShiftReleaseTime = now
        tapCount += 1

        // Cancel previous schedule — we'll either fire now or reschedule.
        pendingFire?.cancel()
        pendingFire = nil

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: shift tap #\(tapCount)\n".utf8)) }

        // Cap at 3 — anything beyond is treated as 3 (or ignored, see fire()).
        if tapCount >= 3 {
            let count = tapCount
            tapCount = 0
            lastShiftReleaseTime = nil
            fire(taps: count)
            return
        }

        if tapCount == 2 {
            // If no secondary configured, no need to wait for triple — fire now.
            if Settings.shared.secondaryLanguage == nil {
                let count = tapCount
                tapCount = 0
                lastShiftReleaseTime = nil
                fire(taps: count)
                return
            }
            // Otherwise wait briefly to see if the user is going for triple.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let count = self.tapCount
                self.tapCount = 0
                self.lastShiftReleaseTime = nil
                self.fire(taps: count)
            }
            pendingFire = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tripleGrace, execute: work)
        }
        // tapCount == 1: do nothing, wait for second tap (or timeout).
    }

    private func cancelPendingTaps() {
        pendingFire?.cancel()
        pendingFire = nil
        tapCount = 0
        lastShiftReleaseTime = nil
    }

    private func fire(taps: Int) {
        guard let target = chooseTarget(forTapCount: taps) else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: tap count \(taps) — no target configured\n".utf8)) }
            return
        }
        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: firing \(taps)-tap → target=\(target)\n".utf8)) }
        DispatchQueue.main.async { [weak self] in
            self?.handleHotkey(targetNonEnglish: target)
        }
    }

    /// Returns the configured non-English language for this tap count, or nil
    /// if nothing should happen (e.g. triple-tap with no secondary set).
    private func chooseTarget(forTapCount taps: Int) -> Layout? {
        switch taps {
        case 2: return Settings.shared.primaryLanguage
        case 3: return Settings.shared.secondaryLanguage
        default: return nil
        }
    }

    /// Hotkey entry point: try selection-based flip first, fall back to last
    /// word in the buffer. The "non-English target" comes from the user's
    /// primary/secondary choice based on tap count.
    private func handleHotkey(targetNonEnglish: Layout) {
        convertSelectionIfPresent(targetNonEnglish: targetNonEnglish) { [weak self] didConvertSelection in
            guard let self else { return }
            if !didConvertSelection {
                if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: no selection — falling back to last-word flip\n".utf8)) }
                self.convertLastWord(targetNonEnglish: targetNonEnglish)
            }
        }
    }

    /// Given the source layout detected from text, choose where to flip to.
    /// Rule: source==EN → target = configured non-English; source!=EN → EN.
    private func resolveTarget(source: Layout, configured: Layout) -> Layout {
        return (source == .en) ? configured : .en
    }

    // MARK: - Selection-based flip (Cmd+C / convert / Cmd+V)

    private func convertSelectionIfPresent(targetNonEnglish: Layout, completion: @escaping (Bool) -> Void) {
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)
        let countBefore = pb.changeCount

        postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_C))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.copyPollDeadline)
            while Date() < deadline && pb.changeCount == countBefore {
                Thread.sleep(forTimeInterval: Self.copyPollInterval)
            }

            DispatchQueue.main.async {
                guard pb.changeCount > countBefore,
                      let text = pb.string(forType: .string),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count >= 2
                else {
                    snapshot.restore(to: pb)
                    completion(false)
                    return
                }

                guard let from = detectLayout(text) else {
                    snapshot.restore(to: pb)
                    completion(false)
                    return
                }
                let to = self.resolveTarget(source: from, configured: targetNonEnglish)
                let converted = convert(text, from: from, to: to)

                guard converted != text else {
                    snapshot.restore(to: pb)
                    completion(false)
                    return
                }

                if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: selection \(from)→\(to), \(text.count) chars\n".utf8)) }

                pb.clearContents()
                pb.setString(converted, forType: .string)

                InputSource.switchTo(to)
                self.postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))

                DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteRestoreDelay) {
                    snapshot.restore(to: pb)
                }
                completion(true)
            }
        }
    }

    // MARK: - Word-buffer flip (manual hotkey when no selection)

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

    private func convertLastWord(targetNonEnglish: Layout) {
        let word = buffer.current
        guard !word.isEmpty else { return }
        guard let from = detectLayout(word) else { return }
        let to = resolveTarget(source: from, configured: targetNonEnglish)

        let converted = convert(word, from: from, to: to)
        guard converted != word else { return }

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: word flip '\(word)' (\(from)) → '\(converted)' (\(to))\n".utf8)) }

        for _ in 0..<word.count { postKey(virtualKey: CGKeyCode(kVK_Delete)) }
        InputSource.switchTo(to)
        for ch in converted { postUnicode(String(ch)) }

        buffer.reset()
        buffer.feed(converted)
    }

    // MARK: - Posting synthesized events

    private func makeSource() -> CGEventSource? {
        return CGEventSource(stateID: .privateState)
    }

    private func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.userDataMagic)
    }

    private func postKey(virtualKey: CGKeyCode) {
        postKey(virtualKey: virtualKey, flags: [])
    }

    private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let src = makeSource()
        if let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true) {
            down.flags = flags
            stamp(down)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) {
            up.flags = flags
            stamp(up)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postCmdShortcut(virtualKey: CGKeyCode) {
        postKey(virtualKey: virtualKey, flags: .maskCommand)
    }

    private func postUnicode(_ s: String) {
        let src = makeSource()
        let chars = Array(s.utf16)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            chars.withUnsafeBufferPointer { ptr in
                down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            down.flags = []
            stamp(down)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            chars.withUnsafeBufferPointer { ptr in
                up.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
            }
            up.flags = []
            stamp(up)
            up.post(tap: .cghidEventTap)
        }
    }
}
