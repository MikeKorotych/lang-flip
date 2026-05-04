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
            shiftCurrentlyHeld = true
            shiftUsedAsModifier = false
        } else {
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
                lastCleanShiftRelease = nil
                if debug { FileHandle.standardError.write(Data("lang-flip[debug]: double-shift detected\n".utf8)) }
                // Defer to the next runloop tick so the Shift release event
                // settles before we start posting synthesized events.
                DispatchQueue.main.async { [weak self] in
                    self?.handleHotkey()
                }
            } else {
                lastCleanShiftRelease = now
            }
        }
    }

    /// Hotkey entry point: if there's selected text, convert it; otherwise
    /// fall back to converting the last word in the buffer.
    private func handleHotkey() {
        convertSelectionIfPresent { [weak self] didConvertSelection in
            guard let self else { return }
            if !didConvertSelection {
                if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: no selection — falling back to last-word flip\n".utf8)) }
                self.convertLastWord()
            }
        }
    }

    // MARK: - Selection-based flip (Cmd+C / convert / Cmd+V)

    private func convertSelectionIfPresent(completion: @escaping (Bool) -> Void) {
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)
        let countBefore = pb.changeCount

        // Trigger a copy on the focused app.
        postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_C))

        // Pasteboard updates asynchronously — poll on a background queue with
        // a short deadline so we don't block the event tap callback.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline && pb.changeCount == countBefore {
                Thread.sleep(forTimeInterval: 0.015)
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
                let to: Layout = (from == .en) ? .uk : .en
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

                // Restore the user's clipboard after the paste has had time
                // to be consumed by the focused app.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    snapshot.restore(to: pb)
                }
                completion(true)
            }
        }
    }

    // MARK: - Word-buffer flip (manual hotkey when no selection)

    /// Auto-flip on word boundary (called from key tracking when enabled).
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

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: word flip '\(word)' (\(from)) → '\(converted)' (\(to))\n".utf8)) }

        for _ in 0..<word.count { postKey(virtualKey: CGKeyCode(kVK_Delete)) }
        InputSource.switchTo(to)
        for ch in converted { postUnicode(String(ch)) }

        buffer.reset()
        buffer.feed(converted)
    }

    // MARK: - Posting synthesized events

    /// Build a fresh event source. We use `.privateState` so the event source
    /// doesn't inherit the user's currently-pressed modifier flags.
    private func makeSource() -> CGEventSource? {
        return CGEventSource(stateID: .privateState)
    }

    /// Tag an event so we recognise it on round-trip through the tap.
    private func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.userDataMagic)
    }

    /// Post a plain (no-modifier) key press + release.
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

    /// Post a Command-key shortcut (e.g. Cmd+C, Cmd+V).
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
