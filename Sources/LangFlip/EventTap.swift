import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox

final class EventTap {
    private let buffer = WordBuffer()
    private let sentenceBuffer = SentenceBuffer()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Magic value stamped on every synthesized event so we can recognise our
    /// own keystrokes when they round-trip through the tap and ignore them.
    /// Without this we get a feedback loop because `event.post` is async and
    /// any boolean "isSimulating" flag has already flipped back by the time
    /// the events reach our callback.
    ///
    /// The value is the ASCII bytes of "LFLI" (lang-flip identifier), encoded
    /// big-endian: 0x1A is the leading byte of an arbitrary tag namespace,
    /// followed by 'L' 'F' 'L' 'I' = 0x4C 0x46 0x4C 0x49.
    private static let userDataMagic: Int64 = 0x1A4C46_4C49

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

    // MARK: - Single-Shift grammar (Sprint C)

    /// Latest grammar request token. Bumped every time a new speculative
    /// inference starts; lets us discard results from cancelled requests
    /// when they eventually return (Task cancellation can't always reach
    /// the Foundation Models call once it's in flight).
    private var grammarToken: Int = 0
    /// Set true on any non-watched keyDown event while a watched modifier
    /// is held — means the user used the modifier as a real shortcut
    /// modifier, not as a hotkey tap.
    private var hotkeyUsedAsModifier = false

    /// Whether any of the configured hotkey's watched keys is currently held.
    private var hotkeyCurrentlyHeld = false

    /// Per-key held / down-time tracking. Generic across hotkey presets:
    /// for `.doubleShift` we have entries for both shift keyCodes; for
    /// `.doubleRightCmd` we have just the one. Reset between releases.
    private var watchedKeyHeld: [CGKeyCode: Bool] = [:]
    private var watchedKeyDownTime: [CGKeyCode: Date] = [:]

    // MARK: - Both-Shifts pause toggle (Phase 1.6)

    /// How close the two Shift presses must be for the gesture to count.
    private static let bothShiftsWindow: TimeInterval = 0.10

    /// Both-shifts gesture state — kept independent of the hotkey
    /// preset so "press both Shifts at once" still pauses the app even
    /// when the user has chosen a non-Shift gesture (e.g. right-Cmd).
    private var leftShiftHeld = false
    private var rightShiftHeld = false
    private var leftShiftDownTime: Date?
    private var rightShiftDownTime: Date?

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

        // Sprint G: translate-selection hotkey ⇧Space. Consume the event
        // so the underlying app never sees the rogue space. Only active
        // when AI is on AND the user has opted in via
        // Settings.translationHotkeyEnabled. Shift+Space is a near-zero-
        // collision combo in normal typing — Shift is released between
        // capital letter and the trailing space — so hijacking it is
        // safe even with the toggle defaulting OFF.
        if Settings.shared.translationHotkeyEnabled,
           Settings.shared.aiMode != .off,
           keyCode == CGKeyCode(kVK_Space),
           flags.contains(.maskShift),
           !flags.contains(.maskCommand),
           !flags.contains(.maskAlternate),
           !flags.contains(.maskControl) {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: translate hotkey ⇧Space fired\n".utf8)) }
            let target = Settings.shared.translationTarget
            DispatchQueue.main.async { [weak self] in
                self?.translateSelectionWithAI(target: target)
            }
            return nil
        }

        // Any keypress while a hotkey-watched modifier is held means the
        // user pressed it as a real shortcut modifier, not as a hotkey
        // tap — disqualify the current sequence.
        if hotkeyCurrentlyHeld {
            hotkeyUsedAsModifier = true
        }
        // Any non-modifier keypress also cancels any pending tap sequence.
        cancelPendingTaps()

        // Track what the user types into the word buffer.
        if keyCode == CGKeyCode(kVK_Delete) {
            buffer.backspace()
            sentenceBuffer.backspace()
            // Backspace within the auto-flip watch window is a disagreement
            // signal. The learner adds the word to the exception list on the
            // first hit and asks for a physical rollback once the user has
            // wiped the whole converted word + trailing space.
            if let rollback = BackspaceLearner.shared.handleBackspace() {
                performRollback(rollback)
            }
        } else {
            var len = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &len, unicodeString: &chars)
            if len > 0 {
                // Any non-backspace keystroke after a flip means the user
                // accepted it (or has moved on). Stop watching.
                BackspaceLearner.shared.cancelPending()

                let s = String(utf16CodeUnits: chars, count: len)
                sentenceBuffer.feed(s)

                // Compute suppression once per keystroke. With C.2 enabled
                // both the sentence-end gate and the word-boundary gate
                // need it; suppressionCause() does an NSWorkspace
                // frontmost-app lookup so calling it twice per keystroke
                // is wasteful.
                let suppression = AppContext.suppressionCause()

                // Sentence-end auto grammar fix (Sprint C.2). Runs as soon
                // as the user types `.` `!` or `?` — the buffer has just
                // rolled over so sentenceBuffer.previous is the sentence
                // we want to rewrite. We deliberately exclude `\n`
                // (Enter) because in chat apps the message has already
                // been sent, and a delayed in-place fix would land in the
                // wrong place.
                let endersInBatch = s.contains(where: { $0 == "." || $0 == "!" || $0 == "?" })
                if endersInBatch {
                    if !Settings.shared.grammarCheckOnSentenceEnd {
                        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end seen but feature off (grammarCheckOnSentenceEnd)\n".utf8)) }
                    } else if Settings.shared.aiMode == .off {
                        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end seen but aiMode = off\n".utf8)) }
                    } else if suppression != nil {
                        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end seen but suppressed: \(suppression!)\n".utf8)) }
                    } else {
                        maybeStartSentenceEndGrammar()
                    }
                }

                if let completed = buffer.feedReturningCompleted(s) {
                    var word = completed

                    // Sticky-shift correction first — its result feeds
                    // the cross-layout / auto-flip stages so a fix
                    // composes if the word also has another problem.
                    if Settings.shared.doubleCapsFix,
                       suppression == nil,
                       let fixed = DoubleCapsFix.correction(for: word) {
                        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: double-caps fix '\(word)' → '\(fixed)'\n".utf8)) }
                        rewriteCompletedWord(originalLength: word.count, replacement: fixed)
                        FlipOverlay.shared.show()
                        word = fixed
                    }

                    // Cross-layout single-letter fix (ы↔і, э↔є). Same
                    // suppression rules as auto-flip — silent in
                    // terminals, password apps, etc.
                    if Settings.shared.crossLayoutFix,
                       suppression == nil,
                       !BackspaceLearner.shared.isExcluded(word),
                       let cross = CrossLayoutFix.correction(for: word, recentContext: buffer.recentHistory) {
                        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: cross-layout fix '\(word)' → '\(cross.corrected)' (\(cross.target))\n".utf8)) }
                        applyCrossLayoutFix(original: word, fix: cross)
                        word = cross.corrected
                    }

                    if Settings.shared.autoFlip {
                        if let cause = suppression {
                            if debug {
                                let reason: String
                                switch cause {
                                case .builtinApp(let id): reason = "built-in block (\(id))"
                                case .userApp(let id):    reason = "user-blocked (\(id))"
                                case .fullscreen:         reason = "fullscreen window"
                                }
                                FileHandle.standardError.write(Data("lang-flip[debug]: auto-flip suppressed: \(reason); word='\(word)'\n".utf8))
                            }
                        } else {
                            autoFlipIfNeeded(completedWord: word)
                        }
                    }
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Replace the just-completed word in the focused app with `replacement`,
    /// preserving the boundary char (assumed to be a space — same simplifying
    /// assumption auto-flip uses). Used by the double-caps fix.
    private func rewriteCompletedWord(originalLength: Int, replacement: String) {
        let eraseCount = originalLength + 1
        postBackspaces(eraseCount)
        postUnicode(replacement + " ")
        Sound.playFlip()
    }

    /// Apply a cross-layout single-letter fix: rewrite the word, switch
    /// the system input source, and arm the BackspaceLearner so the user
    /// can hit Backspace to undo + permanently exclude the word.
    private func applyCrossLayoutFix(original: String, fix: CrossLayoutFix.Correction) {
        let eraseCount = original.count + 1
        postBackspaces(eraseCount)
        InputSource.switchTo(fix.target)
        postUnicode(fix.corrected + " ")
        Sound.playFlip()
        FlipOverlay.shared.show()

        // Treat as a layout flip from the user's perspective: capture the
        // pre-fix layout (best effort — we use the *opposite* of the
        // target since the wrong-letter side of the pair effectively
        // implies that layout was active).
        let source: Layout = (fix.target == .uk) ? .ru : .uk
        BackspaceLearner.shared.recordFlip(
            original: original,
            converted: fix.corrected,
            source: source,
            target: fix.target
        )
    }

    /// Physically undo an auto-flip the user just rejected. We're called from
    /// the event-tap callback (main thread); switching the input source and
    /// posting events is fine here.
    private func performRollback(_ req: BackspaceLearner.RollbackRequest) {
        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: rollback to '\(req.originalWord)' (\(req.sourceLayout))\n".utf8)) }
        InputSource.switchTo(req.sourceLayout)
        postUnicode(req.originalWord + " ")
        Sound.playFlip()
        FlipOverlay.shared.show()
        // Rebuild buffer to reflect the just-typed word so a subsequent
        // boundary doesn't re-fire auto-flip on stale state.
        buffer.reset()
        buffer.feed(req.originalWord)
    }

    private func handleFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) {
        // Both-Shifts pause/resume gesture — runs regardless of hotkey
        // preset, so users on e.g. double-right-Cmd can still freeze the
        // app with the Shift gesture.
        let isShiftKey = (keyCode == CGKeyCode(kVK_Shift) || keyCode == CGKeyCode(kVK_RightShift))
        if isShiftKey {
            updateBothShiftsGesture(flags: flags)
        }

        // Now route the event through the configurable hotkey-tap counter.
        let preset = Settings.shared.hotkeyPreset
        let isWatchedKey = preset.watchedKeys.contains { $0.keyCode == keyCode }
        guard isWatchedKey else {
            // Modifier changed but it isn't part of the hotkey — cancel
            // any in-progress tap sequence so a stray press doesn't
            // accidentally extend it.
            if !isShiftKey { cancelPendingTaps() }
            return
        }

        // Update per-key held / down-time tables from raw NX bits.
        let watchedKeys = preset.watchedKeys
        var anyHeldBefore = false
        var anyHeldNow = false
        let now = Date()
        for hk in watchedKeys {
            let wasHeld = watchedKeyHeld[hk.keyCode, default: false]
            let nowHeld = (flags.rawValue & hk.bitMask) != 0
            anyHeldBefore = anyHeldBefore || wasHeld
            anyHeldNow    = anyHeldNow    || nowHeld
            watchedKeyHeld[hk.keyCode] = nowHeld
            if nowHeld, !wasHeld { watchedKeyDownTime[hk.keyCode] = now }
            if !nowHeld          { watchedKeyDownTime[hk.keyCode] = nil }
        }

        if anyHeldNow && !anyHeldBefore {
            // First key in a new sequence going down.
            hotkeyCurrentlyHeld = true
            hotkeyUsedAsModifier = false
            return
        }

        if !anyHeldNow && anyHeldBefore {
            // Last watched key just went up — end of a possibly-clean tap.
            hotkeyCurrentlyHeld = false
            defer { hotkeyUsedAsModifier = false }
            guard !hotkeyUsedAsModifier else {
                cancelPendingTaps()
                return
            }
            registerCleanShiftTap()
        }
    }

    /// Both-Shifts gesture detector — split out from the main hotkey path
    /// so it works independently of which hotkey preset the user picked.
    private func updateBothShiftsGesture(flags: CGEventFlags) {
        let leftBit:  UInt64 = 0x2
        let rightBit: UInt64 = 0x4
        let leftHeldNow  = (flags.rawValue & leftBit)  != 0
        let rightHeldNow = (flags.rawValue & rightBit) != 0

        let now = Date()
        if leftHeldNow,  !leftShiftHeld  { leftShiftDownTime  = now }
        if rightHeldNow, !rightShiftHeld { rightShiftDownTime = now }
        if !leftHeldNow                  { leftShiftDownTime  = nil }
        if !rightHeldNow                 { rightShiftDownTime = nil }
        leftShiftHeld  = leftHeldNow
        rightShiftHeld = rightHeldNow

        if leftHeldNow && rightHeldNow,
           let lt = leftShiftDownTime, let rt = rightShiftDownTime,
           abs(lt.timeIntervalSince(rt)) < Self.bothShiftsWindow {
            // Fire once per press-pair.
            leftShiftDownTime = nil
            rightShiftDownTime = nil
            // If the configured hotkey is double-Shift, the same release
            // is about to be misinterpreted as a tap — disqualify it.
            hotkeyUsedAsModifier = true
            cancelPendingTaps()
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: both-shifts gesture → toggle Enabled\n".utf8)) }
            DispatchQueue.main.async { [weak self] in self?.handleBothShiftsToggle() }
        }
    }

    private func handleBothShiftsToggle() {
        Settings.shared.enabled.toggle()
        NotificationCenter.default.post(name: .langFlipEnabledChanged, object: nil)
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
            // A second tap arrived within the window — any speculative
            // grammar inference we kicked off on the first tap is no
            // longer wanted. Cancel it before falling through to the
            // double-tap-as-layout-flip path.
            cancelSpeculativeGrammar()

            // We only wait the tripleGrace window if a triple-tap could
            // actually do something — either the user has a secondary
            // language to switch to, OR they've bound triple-tap to the
            // AI selection fix. Otherwise no point delaying double-tap.
            let tripleHasMeaning = Settings.shared.secondaryLanguage != nil ||
                                   Settings.shared.tripleShiftAction == .aiSelectionFix
            if !tripleHasMeaning {
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
            return
        }

        // tapCount == 1.
        // If grammar-on-single-Shift is enabled, wait out the tap window
        // so double/triple Shift still wins. Once it expires, try the
        // selected text first; if nothing is selected, fix the most
        // recent sentence.
        if Settings.shared.grammarCheckOnSingleShift,
           AIAssistantManager.shared.isReady,
           AppContext.suppressionCause() == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.tapCount = 0
                self.lastShiftReleaseTime = nil
                self.fireSingleShiftGrammarFix()
            }
            pendingFire = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapWindow, execute: work)
        }
        // Else: leave tapCount==1 dangling; if a second tap comes the
        // double-tap path takes over, otherwise it harmlessly resets on
        // the next non-shift keypress / timeout.
    }

    private func cancelPendingTaps() {
        pendingFire?.cancel()
        pendingFire = nil
        tapCount = 0
        lastShiftReleaseTime = nil
        cancelSpeculativeGrammar()
    }

    private func fire(taps: Int) {
        // Triple-tap can route to AI selection fix instead of a layout
        // flip, depending on Settings.tripleShiftAction. The AI path
        // doesn't go through chooseTarget / handleHotkey because it
        // skips the input-source switch entirely.
        if taps == 3, Settings.shared.tripleShiftAction == .aiSelectionFix {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: firing triple-tap → AI fix on selection\n".utf8)) }
            DispatchQueue.main.async { [weak self] in
                self?.aiFixSelectionGesture()
            }
            return
        }
        guard let target = chooseTarget(forTapCount: taps) else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: tap count \(taps) — no target configured\n".utf8)) }
            return
        }
        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: firing \(taps)-tap → target=\(target)\n".utf8)) }
        DispatchQueue.main.async { [weak self] in
            self?.handleHotkey(targetNonEnglish: target)
        }
    }

    /// Triple-tap-Shift gesture entry point when the user has
    /// configured `tripleShiftAction = .aiSelectionFix`. Captures the
    /// current selection via Cmd+C, sends it to the AI for a "fix
    /// everything" pass, pastes the result. No mechanical fallback —
    /// the user explicitly wired this gesture to AI, so falling back
    /// to a layout flip would be surprising. On AI failure we just
    /// restore the clipboard and bail with a debug log.
    private func aiFixSelectionGesture() {
        guard Settings.shared.aiMode != .off, AIAssistantManager.shared.isReady else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: triple-tap AI fix: AI not ready\n".utf8)) }
            return
        }
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)
        let countBefore = pb.changeCount

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: triple-tap AI fix: posting Cmd+C\n".utf8)) }
        postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_C))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.copyPollDeadline)
            while Date() < deadline && pb.changeCount == countBefore {
                Thread.sleep(forTimeInterval: Self.copyPollInterval)
            }
            DispatchQueue.main.async {
                guard pb.changeCount > countBefore else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: triple-tap AI fix: no selection\n".utf8)) }
                    snapshot.restore(to: pb)
                    return
                }
                guard let text = pb.string(forType: .string),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count >= 2 else {
                    snapshot.restore(to: pb)
                    return
                }
                let request = AIFixRequest(text: text, activeLayout: InputSource.currentLayout())
                AIAssistantManager.shared.current.fixSelection(request) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch result {
                        case .fixed(let corrected):
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: triple-tap AI fix \(text.count)→\(corrected.count) chars\n".utf8)) }
                            pb.clearContents()
                            pb.setString(corrected, forType: .string)
                            self.postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))
                            Sound.playFlip()
                            FlipOverlay.shared.show()
                            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteRestoreDelay) {
                                snapshot.restore(to: pb)
                            }
                        case .unchanged:
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: triple-tap AI fix: model returned unchanged\n".utf8)) }
                            snapshot.restore(to: pb)
                        case .unsupported:
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: triple-tap AI fix: assistant unsupported\n".utf8)) }
                            snapshot.restore(to: pb)
                        case .failed(let reason):
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: triple-tap AI fix: failed (\(reason))\n".utf8)) }
                            snapshot.restore(to: pb)
                        }
                    }
                }
            }
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

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: selection: posting Cmd+C, pb.changeCount=\(countBefore)\n".utf8)) }
        postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_C))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.copyPollDeadline)
            while Date() < deadline && pb.changeCount == countBefore {
                Thread.sleep(forTimeInterval: Self.copyPollInterval)
            }
            let pollDuration = Date().timeIntervalSince(deadline.addingTimeInterval(-Self.copyPollDeadline))

            DispatchQueue.main.async {
                if self.debug {
                    FileHandle.standardError.write(Data("lang-flip[debug]: selection: poll done in \(String(format: "%.0f", pollDuration * 1000))ms, changeCount: \(countBefore)→\(pb.changeCount)\n".utf8))
                }

                guard pb.changeCount > countBefore else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: selection: no clipboard change → no selection (or app blocks Cmd+C)\n".utf8)) }
                    snapshot.restore(to: pb)
                    completion(false)
                    return
                }

                guard let text = pb.string(forType: .string),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count >= 2
                else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: selection: clipboard updated but no usable string content\n".utf8)) }
                    snapshot.restore(to: pb)
                    completion(false)
                    return
                }

                // Sprint F: smart selection fix. If AI is on AND the
                // toggle is enabled AND the assistant is ready, route
                // the selection through a "fix everything" pass instead
                // of the mechanical layout flip. On AI failure or
                // .unsupported, fall through to the mechanical path so
                // the user always gets *some* result from the gesture.
                if Settings.shared.smartSelectionFix,
                   Settings.shared.aiMode != .off,
                   AIAssistantManager.shared.isReady {
                    self.applyAIFixToSelection(
                        text: text,
                        snapshot: snapshot,
                        targetNonEnglish: targetNonEnglish,
                        completion: completion
                    )
                    return
                }

                guard let from = detectLayout(text) else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: selection: detectLayout returned nil — no alphabetic chars in '\(text.prefix(40))'\n".utf8)) }
                    snapshot.restore(to: pb)
                    completion(false)
                    return
                }
                let to = self.resolveTarget(source: from, configured: targetNonEnglish)
                let converted = convert(text, from: from, to: to)

                guard converted != text else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: selection: converted == original (\(from)→\(to)); nothing to flip\n".utf8)) }
                    snapshot.restore(to: pb)
                    completion(false)
                    return
                }

                if self.debug {
                    FileHandle.standardError.write(Data("lang-flip[debug]: selection \(from)→\(to), \(text.count) chars\n".utf8))
                    FileHandle.standardError.write(Data("lang-flip[debug]:   in:  '\(text.prefix(80))\(text.count > 80 ? "…" : "")'\n".utf8))
                    FileHandle.standardError.write(Data("lang-flip[debug]:   out: '\(converted.prefix(80))\(converted.count > 80 ? "…" : "")'\n".utf8))
                }

                pb.clearContents()
                pb.setString(converted, forType: .string)

                InputSource.switchTo(to)
                self.postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))
                Sound.playFlip()
                FlipOverlay.shared.show()

                DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteRestoreDelay) {
                    snapshot.restore(to: pb)
                }
                completion(true)
            }
        }
    }

    /// Sprint F: send the captured selection to the AI and paste the
    /// fixed result back in. Falls back to the mechanical flip path on
    /// any AI failure / unchanged / unsupported result so the user's
    /// gesture is never wasted.
    ///
    /// `targetNonEnglish` is **only** consumed by the mechanical-flip
    /// fallback — the AI itself does not use it. The AI is given the
    /// user's currently-active layout as a soft language hint instead
    /// (see `AIFixRequest.activeLayout`); the configured non-English
    /// target wouldn't make sense for a "fix everything" pass that may
    /// produce text in any of EN / UK / RU.
    private func applyAIFixToSelection(
        text: String,
        snapshot: PasteboardSnapshot,
        targetNonEnglish: Layout,
        completion: @escaping (Bool) -> Void
    ) {
        let pb = NSPasteboard.general
        if debug {
            FileHandle.standardError.write(Data("lang-flip[debug]: selection: AI fix-everything pass starting (\(text.count) chars)\n".utf8))
        }
        let activeLayout = InputSource.currentLayout()
        let request = AIFixRequest(text: text, activeLayout: activeLayout)
        AIAssistantManager.shared.current.fixSelection(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .fixed(let corrected):
                    if self.debug {
                        FileHandle.standardError.write(Data("lang-flip[debug]: selection AI fix \(text.count)→\(corrected.count) chars\n".utf8))
                        FileHandle.standardError.write(Data("lang-flip[debug]:   in:  '\(text.prefix(80))\(text.count > 80 ? "…" : "")'\n".utf8))
                        FileHandle.standardError.write(Data("lang-flip[debug]:   out: '\(corrected.prefix(80))\(corrected.count > 80 ? "…" : "")'\n".utf8))
                    }
                    pb.clearContents()
                    pb.setString(corrected, forType: .string)
                    self.postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))
                    Sound.playFlip()
                    FlipOverlay.shared.show()
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteRestoreDelay) {
                        snapshot.restore(to: pb)
                    }
                    completion(true)

                case .unchanged:
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: selection: AI returned unchanged → mechanical fallback\n".utf8)) }
                    self.fallBackToMechanicalFlip(text: text, snapshot: snapshot, targetNonEnglish: targetNonEnglish, completion: completion)

                case .unsupported:
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: selection: assistant doesn't support fix → mechanical fallback\n".utf8)) }
                    self.fallBackToMechanicalFlip(text: text, snapshot: snapshot, targetNonEnglish: targetNonEnglish, completion: completion)

                case .failed(let reason):
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: selection: AI failed (\(reason)) → mechanical fallback\n".utf8)) }
                    self.fallBackToMechanicalFlip(text: text, snapshot: snapshot, targetNonEnglish: targetNonEnglish, completion: completion)
                }
            }
        }
    }

    // MARK: - Translate selection (Sprint G)

    /// Capture the current text selection (Cmd+C round-trip), send it
    /// to the AI for translation into `target`, paste the result back.
    /// Public so the menubar's "Translate selection →" submenu can call
    /// it with an explicit target. The hotkey path uses
    /// `Settings.shared.translationTarget`.
    ///
    /// On any failure (no selection, AI unavailable, model unsupported,
    /// transient inference error) we restore the clipboard and bail
    /// silently. There's no mechanical fallback for translation — it
    /// simply requires AI.
    func translateSelectionWithAI(target: Layout) {
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)
        let countBefore = pb.changeCount

        guard Settings.shared.aiMode != .off, AIAssistantManager.shared.isReady else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: translate: AI not ready\n".utf8)) }
            return
        }

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: translate: posting Cmd+C, target=\(target)\n".utf8)) }
        postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_C))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.copyPollDeadline)
            while Date() < deadline && pb.changeCount == countBefore {
                Thread.sleep(forTimeInterval: Self.copyPollInterval)
            }

            DispatchQueue.main.async {
                guard pb.changeCount > countBefore else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: translate: no clipboard change → no selection\n".utf8)) }
                    snapshot.restore(to: pb)
                    return
                }
                guard let text = pb.string(forType: .string),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count >= 2 else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: translate: clipboard updated but no usable string\n".utf8)) }
                    snapshot.restore(to: pb)
                    return
                }

                let request = AITranslateRequest(text: text, target: target)
                AIAssistantManager.shared.current.translateSelection(request) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch result {
                        case .translated(let translated):
                            if self.debug {
                                FileHandle.standardError.write(Data("lang-flip[debug]: translate \(text.count)→\(translated.count) chars\n".utf8))
                                FileHandle.standardError.write(Data("lang-flip[debug]:   in:  '\(text.prefix(80))\(text.count > 80 ? "…" : "")'\n".utf8))
                                FileHandle.standardError.write(Data("lang-flip[debug]:   out: '\(translated.prefix(80))\(translated.count > 80 ? "…" : "")'\n".utf8))
                            }
                            pb.clearContents()
                            pb.setString(translated, forType: .string)
                            // Hop the input source to the target so further
                            // typing matches the new language. Cheap UX win.
                            InputSource.switchTo(target)
                            self.postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))
                            Sound.playFlip()
                            FlipOverlay.shared.show()
                            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteRestoreDelay) {
                                snapshot.restore(to: pb)
                            }
                        case .unsupported:
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: translate: assistant unsupported\n".utf8)) }
                            snapshot.restore(to: pb)
                        case .failed(let reason):
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: translate: failed (\(reason))\n".utf8)) }
                            snapshot.restore(to: pb)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Screen-region OCR (multimodal)

    /// Run macOS's built-in interactive area-select screenshot, send
    /// the resulting PNG to the AI assistant for OCR, drop the
    /// recognized text on the user's clipboard. Cancellation (user
    /// hits Esc in the screenshot UI) is silent.
    ///
    /// Public so the menubar's "Capture text from screen…" item can
    /// invoke it. Requires a multimodal AI backend — currently only
    /// Ollama with a vision-capable model (Gemma 4, Qwen 2.5-VL,
    /// LLaVA). Apple Foundation Models is text-only and will return
    /// `.unsupported`.
    func captureScreenTextWithAI() {
        guard Settings.shared.aiMode != .off, AIAssistantManager.shared.isReady else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: AI not ready\n".utf8)) }
            Notifications.show(title: "LangFlip", body: "AI is off or not ready — enable Ollama (or another vision-capable backend) in Preferences.")
            return
        }

        // Tmp PNG path. Unique per pid so simultaneous captures across
        // app restarts don't collide.
        let tmpDir = FileManager.default.temporaryDirectory
        let pngURL = tmpDir.appendingPathComponent("langflip-ocr-\(getpid())-\(Int(Date().timeIntervalSince1970)).png")

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: launching screencapture -i → \(pngURL.path)\n".utf8)) }

        // /usr/sbin/screencapture is system-managed. The -i flag puts
        // the user into interactive area-select mode (same crosshair
        // they get from ⇧⌘4); -t png forces PNG; -o disables shadow.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-t", "png", "-o", pngURL.path]

        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                guard proc.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: pngURL.path),
                      let imageData = try? Data(contentsOf: pngURL),
                      !imageData.isEmpty
                else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: screenshot cancelled or empty\n".utf8)) }
                    try? FileManager.default.removeItem(at: pngURL)
                    return
                }
                let b64 = imageData.base64EncodedString()
                if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: sending \(imageData.count) bytes (b64=\(b64.count) chars) to AI\n".utf8)) }
                Notifications.show(title: "LangFlip", body: "Reading text from screenshot…")

                let request = AIOcrRequest(imageBase64: b64)
                AIAssistantManager.shared.current.extractTextFromImage(request) { [weak self] result in
                    DispatchQueue.main.async {
                        defer { try? FileManager.default.removeItem(at: pngURL) }
                        guard let self else { return }
                        switch result {
                        case .extracted(let text):
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: extracted \(text.count) chars\n".utf8)) }
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(text, forType: .string)
                            Sound.playFlip()
                            FlipOverlay.shared.show()
                            let preview = String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                            Notifications.show(title: "Text copied", body: text.count > 60 ? "\(preview)…" : preview)
                        case .unsupported:
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: assistant doesn't support OCR\n".utf8)) }
                            Notifications.show(title: "LangFlip", body: "OCR needs a vision-capable model. Switch to Ollama with gemma4 / qwen2.5-vl / llava in Preferences.")
                        case .failed(let reason):
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: failed: \(reason)\n".utf8)) }
                            Notifications.show(title: "OCR failed", body: reason)
                        }
                    }
                }
            }
        }

        do {
            try task.run()
        } catch {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: failed to spawn screencapture: \(error)\n".utf8)) }
            Notifications.show(title: "LangFlip", body: "Couldn't launch screen capture: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: pngURL)
        }
    }

    /// Mechanical-flip fallback used by `applyAIFixToSelection` when the
    /// model declines or fails. Mirrors the inline mechanical path but
    /// reuses the already-captured selection text — saves the second
    /// Cmd+C round-trip.
    private func fallBackToMechanicalFlip(
        text: String,
        snapshot: PasteboardSnapshot,
        targetNonEnglish: Layout,
        completion: @escaping (Bool) -> Void
    ) {
        let pb = NSPasteboard.general
        guard let from = detectLayout(text) else {
            snapshot.restore(to: pb)
            completion(false)
            return
        }
        let to = resolveTarget(source: from, configured: targetNonEnglish)
        let converted = convert(text, from: from, to: to)
        guard converted != text else {
            snapshot.restore(to: pb)
            completion(false)
            return
        }
        pb.clearContents()
        pb.setString(converted, forType: .string)
        InputSource.switchTo(to)
        postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))
        Sound.playFlip()
        FlipOverlay.shared.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteRestoreDelay) {
            snapshot.restore(to: pb)
        }
        completion(true)
    }

    // MARK: - Word-buffer flip (manual hotkey when no selection)

    private func autoFlipIfNeeded(completedWord: String) {
        guard let current = InputSource.currentLayout() else { return }
        guard let target = AutoFlip.shared.suggestedFlip(for: completedWord, currentLayout: current) else { return }
        let converted = convert(completedWord, from: current, to: target)
        guard converted != completedWord else { return }

        // Two-vote agreement: when the user has an AI assistant enabled
        // and ready, ask it for a second opinion before committing the
        // flip. AI inference runs off-main; the apply path hops back via
        // DispatchQueue.main.async. When AI is .off or unavailable, we
        // skip the vote entirely and apply immediately — keeps latency
        // identical to v0.2.0 for users who haven't opted in.
        if Settings.shared.aiMode != .off, AIAssistantManager.shared.isReady {
            consultAIThenApplyFlip(
                original: completedWord,
                converted: converted,
                source: current,
                target: target
            )
        } else {
            applyAutoFlip(
                original: completedWord,
                converted: converted,
                source: current,
                target: target
            )
        }
    }

    /// Submit the candidate flip to the AI assistant. On `.flip` /
    /// `.unknown` we proceed with the rules-based flip; on `.dontFlip`
    /// we drop it entirely (the AI explicitly vetoed). Failures /
    /// timeouts collapse to `.unknown` upstream so we don't lose flips
    /// to flaky inference.
    private func consultAIThenApplyFlip(
        original: String,
        converted: String,
        source: Layout,
        target: Layout
    ) {
        let candidate = AICandidate(
            originalWord: original,
            proposedFlip: converted,
            context: buffer.recentContext(),
            sourceLayout: source,
            targetLayout: target
        )
        AIAssistantManager.shared.current.review(candidateFlip: candidate) { [weak self] decision in
            DispatchQueue.main.async {
                guard let self else { return }
                switch decision {
                case .dontFlip:
                    if self.debug {
                        FileHandle.standardError.write(Data("lang-flip[debug]: AI vetoed flip '\(original)' → '\(converted)'\n".utf8))
                    }
                case .flip, .unknown:
                    self.applyAutoFlip(
                        original: original,
                        converted: converted,
                        source: source,
                        target: target
                    )
                }
            }
        }
    }

    /// Erase + retype + record. Shared between the immediate-apply path
    /// (AI off) and the AI-confirmed-apply path.
    private func applyAutoFlip(
        original: String,
        converted: String,
        source: Layout,
        target: Layout
    ) {
        let eraseCount = original.count + 1
        postBackspaces(eraseCount)
        InputSource.switchTo(target)
        postUnicode(converted + " ")
        Sound.playFlip()
        FlipOverlay.shared.show()

        // Open the disagreement-watch window so the user can backspace this
        // away and have us learn from it.
        BackspaceLearner.shared.recordFlip(
            original: original,
            converted: converted,
            source: source,
            target: target
        )
    }

    private func convertLastWord(targetNonEnglish: Layout) {
        let word = buffer.current
        guard !word.isEmpty else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: word flip skipped — buffer empty\n".utf8)) }
            return
        }
        guard let from = detectLayout(word) else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: word flip skipped — could not detect layout for '\(word)'\n".utf8)) }
            return
        }
        let to = resolveTarget(source: from, configured: targetNonEnglish)

        let converted = convert(word, from: from, to: to)
        guard converted != word else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: word flip skipped — converted == original for '\(word)' (\(from)→\(to))\n".utf8)) }
            return
        }

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: word flip '\(word)' (\(word.count) chars, \(from)) → '\(converted)' (\(to))\n".utf8)) }

        postBackspaces(word.count)
        InputSource.switchTo(to)
        postUnicode(converted)
        Sound.playFlip()
        FlipOverlay.shared.show()

        buffer.reset()
        buffer.feed(converted)
    }

    // MARK: - Single-Shift grammar fix (Sprint C)

    /// Cancel an in-flight grammar request. The actual inference task
    /// may still complete asynchronously; the bumped token discards its
    /// result on arrival.
    private func cancelSpeculativeGrammar() {
        grammarToken &+= 1
    }

    /// Tap window expired without a second tap arriving — the user did
    /// in fact want grammar correction. Selection gets priority because
    /// it is the most explicit target: Shift over selected text should
    /// fix exactly that chunk. If Cmd+C doesn't produce a usable string,
    /// fall back to the most recent sentence from SentenceBuffer.
    private func fireSingleShiftGrammarFix() {
        guard Settings.shared.aiMode != .off, AIAssistantManager.shared.isReady else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift grammar skipped: AI not ready\n".utf8)) }
            return
        }

        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)
        let countBefore = pb.changeCount

        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift grammar: posting Cmd+C to check selection\n".utf8)) }
        postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_C))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.copyPollDeadline)
            while Date() < deadline && pb.changeCount == countBefore {
                Thread.sleep(forTimeInterval: Self.copyPollInterval)
            }

            DispatchQueue.main.async {
                if pb.changeCount > countBefore,
                   let text = pb.string(forType: .string),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   text.count >= 2 {
                    self.applySingleShiftAIFixToSelection(text: text, snapshot: snapshot)
                    return
                }

                snapshot.restore(to: pb)
                self.fireSingleShiftSentenceGrammarFix()
            }
        }
    }

    private func applySingleShiftAIFixToSelection(text: String, snapshot: PasteboardSnapshot) {
        let pb = NSPasteboard.general
        let request = AIFixRequest(text: text, activeLayout: InputSource.currentLayout())
        AIAssistantManager.shared.current.fixSelection(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .fixed(let corrected):
                    if self.debug {
                        FileHandle.standardError.write(Data("lang-flip[debug]: single-shift selection AI fix \(text.count)→\(corrected.count) chars\n".utf8))
                    }
                    pb.clearContents()
                    pb.setString(corrected, forType: .string)
                    self.postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteRestoreDelay) {
                        snapshot.restore(to: pb)
                    }
                case .unchanged:
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift selection grammar — unchanged\n".utf8)) }
                    snapshot.restore(to: pb)
                case .unsupported:
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift selection grammar — unsupported\n".utf8)) }
                    snapshot.restore(to: pb)
                case .failed(let reason):
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift selection grammar — failed: \(reason)\n".utf8)) }
                    snapshot.restore(to: pb)
                }
            }
        }
    }

    private func fireSingleShiftSentenceGrammarFix() {
        guard let sentence = sentenceBuffer.mostRecentSentence,
              sentence.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift sentence grammar skipped: no sentence\n".utf8)) }
            return
        }

        grammarToken &+= 1
        let token = grammarToken
        let wasCurrent = sentenceBuffer.current == sentence
        let request = AIRewriteRequest(
            text: sentence,
            preferredLayout: InputSource.currentLayout()
        )
        AIAssistantManager.shared.current.rewriteSentence(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.grammarToken == token else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift sentence grammar discarded (stale token)\n".utf8)) }
                    return
                }
                self.applySingleShiftSentenceGrammar(
                    originalSentence: sentence,
                    wasCurrent: wasCurrent,
                    result: result
                )
            }
        }
        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift sentence grammar started (token=\(token), len=\(sentence.count))\n".utf8)) }
    }

    private func applySingleShiftSentenceGrammar(originalSentence: String, wasCurrent: Bool, result: AIRewriteResult) {
        switch result {
        case .rewritten(let corrected):
            let bufferStillMatches = wasCurrent
                ? sentenceBuffer.current == originalSentence
                : sentenceBuffer.current.isEmpty && sentenceBuffer.previous == originalSentence
            guard bufferStillMatches else {
                if debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift sentence grammar dropped (buffer changed)\n".utf8)) }
                return
            }
            applyGrammarFix(original: originalSentence, corrected: corrected)
            if wasCurrent {
                sentenceBuffer.replaceCurrent(with: corrected)
            } else {
                sentenceBuffer.replacePrevious(with: corrected)
            }
        case .unchanged:
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift sentence grammar — unchanged\n".utf8)) }
        case .unsupported:
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift sentence grammar — unsupported\n".utf8)) }
        case .failed(let reason):
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift sentence grammar — failed: \(reason)\n".utf8)) }
        }
    }

    /// Replace the just-typed sentence with the AI-corrected one.
    /// Backspaces over the original (in the focused app), retypes the
    /// new text, leaves layout / sound / overlay alone — grammar fixes
    /// are intentionally silent so users see only the diff in the text.
    private func applyGrammarFix(original: String, corrected: String) {
        guard original != corrected else { return }
        if debug {
            let oPrefix = String(original.prefix(60))
            let cPrefix = String(corrected.prefix(60))
            FileHandle.standardError.write(Data("lang-flip[debug]: grammar fix '\(oPrefix)' → '\(cPrefix)'\n".utf8))
        }
        postBackspaces(original.count)
        postUnicode(corrected)
        // Caller updates SentenceBuffer according to whether this was
        // the in-progress or previously-completed sentence.
        buffer.reset()
        // Don't play sound or overlay — rewrites should be a quiet
        // background fix, not a celebration. Different surface from
        // layout flips.
    }

    // MARK: - Sentence-end auto grammar (Sprint C.2)

    /// Called from the keyDown path right after the SentenceBuffer rolls
    /// over on a `.` / `!` / `?`. Decides whether the just-completed
    /// sentence is worth a grammar pass and kicks off an async AI call
    /// that — if it returns before the user types another sentence — is
    /// applied silently in place.
    ///
    /// Trivial sentences ("Ok.", "Yes!", "What?") are skipped: the cost
    /// of an in-place rewrite isn't worth the marginal value, and a
    /// model echoing the same single word back fires `unchanged` anyway.
    /// We use a 4-word threshold to keep the sweet spot.
    ///
    /// Shares `grammarToken` with the single-Shift speculative path so
    /// the two features can't fight each other — whichever fires last
    /// wins, the older inference's result is discarded on arrival.
    private func maybeStartSentenceEndGrammar() {
        let prev = sentenceBuffer.previous
        let trimmed = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        // Two-word minimum keeps "Yes." / "Ok!" out of the round-trip
        // while still firing for "Привіт як справи?" (3) and most
        // real-world sentences. Earlier 4-word threshold was too tight
        // — typical 2-3 word phrases never triggered.
        guard words.count >= 2 else {
            if debug {
                FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end grammar skip: only \(words.count) words in '\(trimmed.prefix(40))'\n".utf8))
            }
            return
        }
        if !AIAssistantManager.shared.isReady {
            if debug {
                FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end grammar skip: AI not ready\n".utf8))
            }
            return
        }
        grammarToken &+= 1
        let token = grammarToken
        let request = AIRewriteRequest(
            text: prev,
            preferredLayout: InputSource.currentLayout()
        )
        AIAssistantManager.shared.current.rewriteSentence(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.grammarToken == token else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end grammar discarded (stale token=\(token), current=\(self.grammarToken))\n".utf8)) }
                    return
                }
                self.applySentenceEndGrammar(originalSentence: prev, result: result)
            }
        }
        if debug {
            FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end grammar started (token=\(token), \(words.count) words, \(prev.count) chars): '\(prev.prefix(60))'\n".utf8))
        }
    }

    /// Result handler for a sentence-end grammar request. Applies the
    /// rewrite in-place if the buffer state is still consistent — i.e.
    /// the user hasn't typed past another sentence boundary while the
    /// model was thinking. Anything they typed after the trigger boundary
    /// (the `current` portion) is preserved by erasing through it,
    /// retyping the corrected sentence, then retyping the captured
    /// trailing text.
    private func applySentenceEndGrammar(originalSentence: String, result: AIRewriteResult) {
        switch result {
        case .rewritten(let corrected):
            guard sentenceBuffer.previous == originalSentence else {
                if debug {
                    FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end grammar dropped (buffer rolled over)\n".utf8))
                    FileHandle.standardError.write(Data("lang-flip[debug]:   expected: '\(originalSentence.prefix(60))'\n".utf8))
                    FileHandle.standardError.write(Data("lang-flip[debug]:   got:      '\(sentenceBuffer.previous.prefix(60))'\n".utf8))
                }
                return
            }
            guard corrected != originalSentence else {
                if debug { FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end grammar — corrected == original, no-op\n".utf8)) }
                return
            }
            let typedSince = sentenceBuffer.current
            if debug {
                let oPrefix = String(originalSentence.prefix(60))
                let cPrefix = String(corrected.prefix(60))
                FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end fix '\(oPrefix)' → '\(cPrefix)' (typedSince=\(typedSince.count))\n".utf8))
            }
            let totalErase = typedSince.count + originalSentence.count
            postBackspaces(totalErase)
            postUnicode(corrected + typedSince)
            sentenceBuffer.replacePrevious(with: corrected)
            // current is intact — typedSince is back where it was.
        case .unchanged:
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end grammar — unchanged\n".utf8)) }
        case .unsupported:
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end grammar — unsupported\n".utf8)) }
        case .failed(let reason):
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: sentence-end grammar — failed: \(reason)\n".utf8)) }
        }
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

    /// Send N backspace events. Used to erase the original word/sentence
    /// before retyping a corrected one. Earlier code did
    /// `for _ in 0..<n { postKey(kVK_Delete) }`, which works in Notes and
    /// most native apps but unreliably in Slack, Notion, and Electron-
    /// based editors — they drop the back half of a fast burst, so the
    /// flip ends up rewriting only the tail of a long word.
    ///
    /// Adding a sub-millisecond gap between events fixes it across every
    /// app we've tested while staying invisible to the user (a 12-letter
    /// word costs ~6 ms total).
    private func postBackspaces(_ count: Int) {
        for i in 0..<count {
            postKey(virtualKey: CGKeyCode(kVK_Delete))
            if i + 1 < count {
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
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
