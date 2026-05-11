import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox
import ApplicationServices

final class EventTap {
    private let buffer = WordBuffer()
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
    private var singleShiftGrammarInFlight = false
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

    // MARK: - Voice dictation gestures

    private static let speechHoldDelay: TimeInterval = 0.45
    private static let commandShiftToggleDelay: TimeInterval = 0.35

    private var speechHoldWork: DispatchWorkItem?
    private var speechPushToTalkActive = false
    private var commandShiftSpeechWork: DispatchWorkItem?
    private var commandShiftSpeechTriggered = false

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

        // Screen text capture hotkey: Shift+Command+S. Only intercept it
        // when the selected local model can actually handle images; this
        // avoids stealing Save As / Duplicate shortcuts when OCR is not
        // available.
        if Settings.shared.screenTextCaptureHotkeyEnabled,
           Settings.shared.aiMode == .ollama,
           Self.isVisionOllamaModel(Settings.shared.ollamaModel),
           Settings.shared.screenTextCaptureHotkeyPreset.matches(keyCode: keyCode, flags: flags) {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: screen OCR hotkey fired\n".utf8)) }
            DispatchQueue.main.async { [weak self] in
                self?.captureScreenTextWithAI()
            }
            return nil
        }

        // Read selected text aloud: Control+Option+X. This is global and
        // intentionally avoids Command-based browser/editor shortcuts.
        if Settings.shared.readSelectionHotkeyEnabled,
           Settings.shared.readSelectionHotkeyPreset.matches(keyCode: keyCode, flags: flags) {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: read-aloud hotkey fired\n".utf8)) }
            DispatchQueue.main.async { [weak self] in
                self?.readSelectedTextAloud()
            }
            return nil
        }

        // Sprint G: translate-selection hotkey ⇧Space. Consume the event
        // so the underlying app never sees the rogue space. Only active
        // when AI is on and Settings.translationHotkeyEnabled allows it.
        // For local Ollama setups the release default is on, because the
        // action only applies to selected text and consumes the stray space.
        if Settings.shared.translationHotkeyEnabled,
           Settings.shared.aiMode != .off,
           Settings.shared.translationHotkeyPreset.matches(keyCode: keyCode, flags: flags) {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: translate hotkey fired\n".utf8)) }
            let target = Settings.shared.translationTarget
            DispatchQueue.main.async { [weak self] in
                self?.translateSelectionWithAI(target: target)
            }
            return nil
        }

        // Any keypress while a hotkey-watched modifier is held means the
        // user pressed it as a real shortcut modifier, not as a hotkey
        // tap — disqualify the current sequence.
        cancelSpeechModifierCandidates()
        if hotkeyCurrentlyHeld {
            hotkeyUsedAsModifier = true
        }
        // Any non-modifier keypress also cancels any pending tap sequence.
        cancelPendingTaps()

        // Track what the user types into the word buffer.
        if keyCode == CGKeyCode(kVK_Delete) {
            buffer.backspace()
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

                // Compute suppression once per keystroke; suppressionCause()
                // does an NSWorkspace frontmost-app lookup.
                let suppression = AppContext.suppressionCause()

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

        if handleSpeechModifierGesture(keyCode: keyCode, flags: flags) {
            return
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

    private func handleSpeechModifierGesture(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let isShiftKey = keyCode == CGKeyCode(kVK_Shift) || keyCode == CGKeyCode(kVK_RightShift)
        let isCommandKey = keyCode == CGKeyCode(kVK_Command) || keyCode == CGKeyCode(kVK_RightCommand)
        let shiftHeld = flags.contains(.maskShift)
        let commandHeld = flags.contains(.maskCommand)
        let hasOtherModifiers = flags.contains(.maskAlternate) || flags.contains(.maskControl)

        if commandShiftSpeechTriggered {
            if !shiftHeld && !commandHeld {
                commandShiftSpeechTriggered = false
            }
            return true
        }

        if shiftHeld && commandHeld && !hasOtherModifiers && (isShiftKey || isCommandKey) {
            speechHoldWork?.cancel()
            speechHoldWork = nil
            if commandShiftSpeechWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.commandShiftSpeechWork = nil
                    self.commandShiftSpeechTriggered = true
                    self.hotkeyUsedAsModifier = true
                    self.cancelPendingTaps()
                    VoiceDictationController.shared.toggleRecording()
                }
                commandShiftSpeechWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandShiftToggleDelay, execute: work)
            }
            return false
        }
        commandShiftSpeechWork?.cancel()
        commandShiftSpeechWork = nil

        guard isShiftKey, !commandHeld, !hasOtherModifiers else {
            if !shiftHeld {
                speechHoldWork?.cancel()
                speechHoldWork = nil
            }
            return false
        }

        if shiftHeld {
            if speechHoldWork == nil, !speechPushToTalkActive {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.speechHoldWork = nil
                    self.speechPushToTalkActive = true
                    self.hotkeyUsedAsModifier = true
                    self.cancelPendingTaps()
                    VoiceDictationController.shared.start(mode: .pushToTalk)
                }
                speechHoldWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.speechHoldDelay, execute: work)
            }
            return false
        }

        speechHoldWork?.cancel()
        speechHoldWork = nil
        if speechPushToTalkActive {
            speechPushToTalkActive = false
            hotkeyUsedAsModifier = true
            cancelPendingTaps()
            VoiceDictationController.shared.stopAndTranscribe()
            return true
        }
        return false
    }

    private func cancelSpeechModifierCandidates() {
        speechHoldWork?.cancel()
        speechHoldWork = nil
        commandShiftSpeechWork?.cancel()
        commandShiftSpeechWork = nil
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

            // We only wait the tripleGrace window if triple-tap could
            // actually do something: switch to a configured secondary
            // language. Otherwise no point delaying double-tap.
            let tripleHasMeaning = Settings.shared.secondaryLanguage != nil
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
        // selected text. If nothing is selected, nothing happens.
        if Settings.shared.grammarCheckOnSingleShift,
           AIAssistantManager.shared.isReady,
           !singleShiftGrammarInFlight,
           AppContext.suppressionCause() == nil {
            AppLog.write("single-shift grammar scheduled")
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.tapCount = 0
                self.lastShiftReleaseTime = nil
                self.fireSingleShiftGrammarFix()
            }
            pendingFire = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapWindow, execute: work)
        } else if tapCount == 1, Settings.shared.grammarCheckOnSingleShift {
            AppLog.write("single-shift grammar not scheduled: ready=\(AIAssistantManager.shared.isReady) inFlight=\(singleShiftGrammarInFlight) suppression=\(String(describing: AppContext.suppressionCause()))")
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

    /// Hotkey entry point: prefer the stable selection-based layout flip.
    /// If the experimental no-selection toggle is enabled, fall back to
    /// the focused field's AX value instead of the lossy key history.
    private func handleHotkey(targetNonEnglish: Layout) {
        convertSelectionIfPresent(targetNonEnglish: targetNonEnglish) { [weak self] didConvertSelection in
            guard let self else { return }
            if !didConvertSelection {
                if Settings.shared.flipLastWordsOnDoubleShift,
                   self.flipFocusedLastWords(targetNonEnglish: targetNonEnglish) {
                    return
                }
                if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: no selection — double-shift layout flip skipped\n".utf8)) }
            }
        }
    }

    /// Menu entry point for the same selection-only layout flip as the
    /// double-Shift hotkey.
    func flipSelectedText() {
        handleHotkey(targetNonEnglish: Settings.shared.primaryLanguage)
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

    // MARK: - Read selection aloud

    func readSelectedTextAloud() {
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)
        let countBefore = pb.changeCount

        Sound.playFlip()
        FlipOverlay.shared.show()
        if debug { FileHandle.standardError.write(Data("lang-flip[debug]: speech: posting Cmd+C\n".utf8)) }
        postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_C))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.copyPollDeadline)
            while Date() < deadline && NSPasteboard.general.changeCount == countBefore {
                Thread.sleep(forTimeInterval: Self.copyPollInterval)
            }

            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                defer { snapshot.restore(to: pb) }
                guard pb.changeCount > countBefore,
                      let text = pb.string(forType: .string),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: speech: no selected text\n".utf8)) }
                    Notifications.show(title: "LangFlip", body: "Select text first, then press \(Settings.shared.readSelectionHotkeyPreset.displayName).")
                    return
                }
                Notifications.show(title: "Reading selected text", body: String(text.prefix(80)))
                SpeechReader.shared.speak(text)
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
    /// Ollama with a vision-capable model (Qwen 3.5, Qwen-VL,
    /// LLaVA). Apple Foundation Models is text-only and will return
    /// `.unsupported`.
    func captureScreenTextWithAI() {
        guard Settings.shared.aiMode != .off, AIAssistantManager.shared.isReady else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: AI not ready\n".utf8)) }
            Notifications.show(title: "LangFlip", body: "AI is off or not ready — enable Ollama (or another vision-capable backend) in Preferences.")
            return
        }
        guard PermissionStatus.hasScreenRecording() else {
            AppLog.write("ocr skipped: screen recording permission missing")
            PermissionStatus.requestScreenRecording()
            PermissionStatus.openScreenRecordingPane()
            Notifications.show(title: "LangFlip", body: "Screen text capture needs Screen Recording permission. Toggle LangFlip on, then try again.")
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
                            pb.setString(text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
                            Sound.playFlip()
                            FlipOverlay.shared.show()
                            let preview = String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                            Notifications.show(title: "Text copied", body: text.count > 60 ? "\(preview)…" : preview)
                        case .unsupported:
                            if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: ocr: assistant doesn't support OCR\n".utf8)) }
                            Notifications.show(title: "LangFlip", body: "OCR needs a vision-capable model. Switch to Ollama with qwen3.5:4b in Preferences.")
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

    // MARK: - Auto-flip on word boundary

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

    // MARK: - Single-Shift grammar fix (Sprint C)

    /// Cancel an in-flight grammar request. The actual inference task
    /// may still complete asynchronously; the bumped token discards its
    /// result on arrival.
    private func cancelSpeculativeGrammar() {
        grammarToken &+= 1
    }

    /// Tap window expired without a second tap arriving — the user did
    /// in fact want grammar correction. Selection is the only target we
    /// trust for the release path: it reflects the real text currently
    /// in the focused app instead of LangFlip's best-effort key history.
    private func fireSingleShiftGrammarFix() {
        guard Settings.shared.aiMode != .off, AIAssistantManager.shared.isReady else {
            AppLog.write("single-shift grammar fired but AI not ready")
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
                    AppLog.write("single-shift grammar using selection len=\(text.count)")
                    self.singleShiftGrammarInFlight = true
                    self.applySingleShiftAIFixToSelection(text: text, snapshot: snapshot)
                    return
                }

                if Settings.shared.fixLastSentenceOnSingleShift,
                   let context = self.focusedTextContext(),
                   context.selectedRange.length == 0,
                   let sentence = self.lastSentenceBeforeCursor(in: context.value, cursorUTF16: context.selectedRange.location) {
                    AppLog.write("single-shift grammar using focused last sentence len=\(sentence.text.count)")
                    self.singleShiftGrammarInFlight = true
                    self.applySingleShiftAIFixToFocusedRange(
                        context: context,
                        range: sentence.range,
                        text: sentence.text,
                        snapshot: snapshot
                    )
                    return
                }

                AppLog.write("single-shift grammar found no selection; skipped")
                snapshot.restore(to: pb)
            }
        }
    }

    /// Menu entry point for the same selected-text grammar fix as a
    /// single Shift tap.
    func fixSelectedTextWithAI() {
        guard !singleShiftGrammarInFlight else { return }
        fireSingleShiftGrammarFix()
    }

    private func applySingleShiftAIFixToSelection(text: String, snapshot: PasteboardSnapshot) {
        let pb = NSPasteboard.general
        let request = AIFixRequest(text: text, activeLayout: InputSource.currentLayout())
        AIAssistantManager.shared.current.fixSelection(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.singleShiftGrammarInFlight = false
                switch result {
                case .fixed(let corrected):
                    AppLog.write("single-shift selection fixed \(text.count)->\(corrected.count)")
                    if self.debug {
                        FileHandle.standardError.write(Data("lang-flip[debug]: single-shift selection AI fix \(text.count)→\(corrected.count) chars\n".utf8))
                    }
                    pb.clearContents()
                    pb.setString(corrected, forType: .string)
                    self.postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))
                    self.playRewriteFeedback()
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteRestoreDelay) {
                        snapshot.restore(to: pb)
                    }
                case .unchanged:
                    AppLog.write("single-shift selection unchanged")
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift selection grammar — unchanged\n".utf8)) }
                    snapshot.restore(to: pb)
                case .unsupported:
                    AppLog.write("single-shift selection unsupported")
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift selection grammar — unsupported\n".utf8)) }
                    snapshot.restore(to: pb)
                case .failed(let reason):
                    AppLog.write("single-shift selection failed: \(reason)")
                    if self.debug { FileHandle.standardError.write(Data("lang-flip[debug]: single-shift selection grammar — failed: \(reason)\n".utf8)) }
                    snapshot.restore(to: pb)
                }
            }
        }
    }

    private func playRewriteFeedback() {
        Sound.playFlip()
        FlipOverlay.shared.show()
    }

    // MARK: - Focused text fallback (experimental)

    private struct FocusedTextContext {
        let element: AXUIElement
        let value: String
        let selectedRange: CFRange
    }

    private struct FocusedTextSlice {
        let range: CFRange
        let text: String
    }

    private func focusedTextContext() -> FocusedTextContext? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: focused text: no focused AX element\n".utf8)) }
            return nil
        }

        let element = focusedRef as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else {
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: focused text: no string AX value\n".utf8)) }
            return nil
        }

        var range = CFRange(location: value.utf16.count, length: 0)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef,
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var selected = CFRange()
            if AXValueGetValue((rangeRef as! AXValue), .cfRange, &selected) {
                range = selected
            }
        }

        range.location = max(0, min(range.location, value.utf16.count))
        range.length = max(0, min(range.length, value.utf16.count - range.location))
        return FocusedTextContext(element: element, value: value, selectedRange: range)
    }

    private func setFocusedSelection(_ range: CFRange, in element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        ) == .success
    }

    private func focusedSelection(in element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue((rangeRef as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    private func waitForFocusedSelection(_ expected: CFRange, in element: AXUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(0.16)
        while Date() < deadline {
            if let actual = focusedSelection(in: element),
               actual.location == expected.location,
               actual.length == expected.length {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func pasteFocusedReplacement(
        _ replacement: String,
        range: CFRange,
        context: FocusedTextContext,
        snapshot: PasteboardSnapshot
    ) {
        guard setFocusedSelection(range, in: context.element) else {
            snapshot.restore()
            return
        }
        guard waitForFocusedSelection(range, in: context.element) else {
            snapshot.restore()
            if debug { FileHandle.standardError.write(Data("lang-flip[debug]: focused replacement: AX selection did not settle\n".utf8)) }
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(replacement, forType: .string)
        postCmdShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))
        playRewriteFeedback()

        let cursor = CFRange(location: range.location + replacement.utf16.count, length: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            _ = self?.setFocusedSelection(cursor, in: context.element)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteRestoreDelay) {
            snapshot.restore(to: pb)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                _ = self?.setFocusedSelection(cursor, in: context.element)
            }
        }
    }

    private func typeFocusedReplacementFromCursor(
        original: String,
        replacement: String,
        range: CFRange,
        context: FocusedTextContext,
        snapshot: PasteboardSnapshot
    ) -> Bool {
        guard context.selectedRange.length == 0,
              context.selectedRange.location == range.location + range.length
        else {
            return false
        }

        postBackspaces(original.count)
        postUnicode(replacement)
        playRewriteFeedback()
        snapshot.restore()
        return true
    }

    private func lastSentenceBeforeCursor(in value: String, cursorUTF16: Int) -> FocusedTextSlice? {
        guard !value.isEmpty else { return nil }
        let ns = value as NSString
        var end = min(max(cursorUTF16, 0), ns.length)
        while end > 0, isWhitespaceOrNewline(ns.character(at: end - 1)) {
            end -= 1
        }
        guard end > 0 else { return nil }

        var start = 0
        let searchFrom = end > 0 && isSentenceBoundary(ns.character(at: end - 1)) ? end - 2 : end - 1
        if searchFrom >= 0 {
            for index in stride(from: searchFrom, through: 0, by: -1) where isSentenceBoundary(ns.character(at: index)) {
                start = index + 1
                break
            }
        }
        while start < end, isWhitespaceOrNewline(ns.character(at: start)) {
            start += 1
        }

        let range = NSRange(location: start, length: end - start)
        guard range.length >= 2 else { return nil }
        let text = ns.substring(with: range)
        guard text.rangeOfCharacter(from: .letters) != nil else { return nil }
        return FocusedTextSlice(range: CFRange(location: range.location, length: range.length), text: text)
    }

    private func lastWrongLayoutRunBeforeCursor(
        in value: String,
        cursorUTF16: Int,
        targetNonEnglish: Layout
    ) -> FocusedTextSlice? {
        guard !value.isEmpty else { return nil }
        let ns = value as NSString
        var end = min(max(cursorUTF16, 0), ns.length)
        while end > 0, isWhitespaceOrNewline(ns.character(at: end - 1)) {
            end -= 1
        }
        guard end > 0 else { return nil }

        var sentenceStart = 0
        let searchFrom = end > 0 && isSentenceBoundary(ns.character(at: end - 1)) ? end - 2 : end - 1
        if searchFrom >= 0 {
            for index in stride(from: searchFrom, through: 0, by: -1) where isSentenceBoundary(ns.character(at: index)) {
                sentenceStart = index + 1
                break
            }
        }
        while sentenceStart < end, isWhitespaceOrNewline(ns.character(at: sentenceStart)) {
            sentenceStart += 1
        }
        guard sentenceStart < end else { return nil }

        let sentenceRange = NSRange(location: sentenceStart, length: end - sentenceStart)
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-zА-Яа-яЁёІіЇїЄєҐґ']+") else { return nil }
        let matches = regex.matches(in: value, range: sentenceRange)
        guard let lastMatch = matches.last else { return nil }

        let lastWord = ns.substring(with: lastMatch.range)
        guard let source = detectLayout(lastWord) else { return nil }
        let target = resolveTarget(source: source, configured: targetNonEnglish)
        let convertedLastWord = convert(lastWord, from: source, to: target)
        guard convertedLastWord != lastWord else { return nil }

        var includedStart = lastMatch.range.location
        if matches.count >= 2 {
            for match in matches.dropLast().reversed() {
                let word = ns.substring(with: match.range)
                guard let wordSource = detectLayout(word),
                      wordSource == source,
                      resolveTarget(source: wordSource, configured: targetNonEnglish) == target,
                      AutoFlip.shared.suggestedFlip(for: word, currentLayout: wordSource) == target
                else {
                    break
                }
                includedStart = match.range.location
            }
        }

        let range = NSRange(location: includedStart, length: end - includedStart)
        guard range.length > 0 else { return nil }
        let original = ns.substring(with: range)
        let converted = convert(original, from: source, to: target)
        guard converted != original else { return nil }
        return FocusedTextSlice(range: CFRange(location: range.location, length: range.length), text: converted)
    }

    private func flipFocusedLastWords(targetNonEnglish: Layout) -> Bool {
        guard let context = focusedTextContext(),
              context.selectedRange.length == 0,
              let replacement = lastWrongLayoutRunBeforeCursor(
                  in: context.value,
                  cursorUTF16: context.selectedRange.location,
                  targetNonEnglish: targetNonEnglish
              )
        else {
            return false
        }

        let snapshot = PasteboardSnapshot.capture()
        if let source = detectLayout((context.value as NSString).substring(with: NSRange(location: replacement.range.location, length: replacement.range.length))) {
            InputSource.switchTo(resolveTarget(source: source, configured: targetNonEnglish))
        }
        pasteFocusedReplacement(replacement.text, range: replacement.range, context: context, snapshot: snapshot)
        AppLog.write("double-shift focused words flipped len=\(replacement.text.count)")
        return true
    }

    private func applySingleShiftAIFixToFocusedRange(
        context: FocusedTextContext,
        range: CFRange,
        text: String,
        snapshot: PasteboardSnapshot
    ) {
        let request = AIFixRequest(text: text, activeLayout: InputSource.currentLayout())
        AIAssistantManager.shared.current.fixSelection(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.singleShiftGrammarInFlight = false
                switch result {
                case .fixed(let corrected):
                    AppLog.write("single-shift focused sentence fixed \(text.count)->\(corrected.count)")
                    if !self.typeFocusedReplacementFromCursor(
                        original: text,
                        replacement: corrected,
                        range: range,
                        context: context,
                        snapshot: snapshot
                    ) {
                        self.pasteFocusedReplacement(corrected, range: range, context: context, snapshot: snapshot)
                    }
                case .unchanged:
                    AppLog.write("single-shift focused sentence unchanged")
                    snapshot.restore()
                case .unsupported:
                    AppLog.write("single-shift focused sentence unsupported")
                    snapshot.restore()
                case .failed(let reason):
                    AppLog.write("single-shift focused sentence failed: \(reason)")
                    snapshot.restore()
                }
            }
        }
    }

    private func isSentenceBoundary(_ utf16: unichar) -> Bool {
        utf16 == 10 || utf16 == 13 || utf16 == 46 || utf16 == 33 || utf16 == 63 || utf16 == 8230
    }

    private func isWhitespaceOrNewline(_ utf16: unichar) -> Bool {
        guard let scalar = UnicodeScalar(Int(utf16)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
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

private extension EventTap {
    static func isVisionOllamaModel(_ model: String) -> Bool {
        let tag = model.lowercased()
        return tag.contains("qwen3.5")
            || tag.contains("-vl")
            || tag.contains(":vl")
            || tag.contains("llava")
            || tag.contains("gemma4")
    }
}
