# lang-flip — Roadmap

Living document. Updated 2026-05-06 after a deep dive into Caramba Switcher's
internals — many ideas below are inspired by what makes Caramba feel "smart"
without configuration screens.

## Near-term backlog — do FIRST after the corporate rollout

Deferred from the 2026-06-29 release-prep pass (release shipped with the lazy
history list, delete controls, and the Share-logs button). These two are the
top priority for the next iteration:

1. **Remote crash/error reporting.** Today the app has *zero* remote
   observability — `AppLog` writes to `~/Library/Logs/Sayful/Sayful.log` and
   errors only flash in a banner. With ~300 employees we're blind to failures.
   Decide Sentry vs. a `/v1/logs` endpoint on the existing Supabase/Railway
   backend. MUST redact dictated/transformed text (privacy) — same redaction the
   Share-logs button uses. See `AppLog.swift`, `AI/Backend/*`.
2. **Verify & analyse learned "fixes."** `PersonalDictionaryStore` accumulates
   automatic corrections from `DictationCorrectionLearner` using heuristics only
   — nothing checks they're sensible. Add a periodic job that runs the automatic
   entries through the backend LLM to prune nonsense and suggest "make this a
   rule." A deeper-analysis pass (insights/ideas to improve the feature) is a
   follow-up to that.

## Done

- [x] Core EN ↔ UK / RU char-based conversion via physical-key map
- [x] Layout detection from typed text (alphabet voting)
- [x] Stable input-source switching via TIS language property API (not bundle-ID substring)
- [x] CGEventTap with feedback-loop protection (`eventSourceUserData` magic stamp)
- [x] Double-Shift hotkey — clean detection (ignores Shift used as a real modifier)
- [x] Triple-Shift hotkey — for secondary language; auto-disabled when none set so double-tap stays instant
- [x] Selection-based flip — Cmd+C → convert → Cmd+V → restore clipboard, handles half-paragraph case
- [x] Selection-only manual flip — double-Shift without a selection intentionally does nothing
- [x] Primary / secondary language settings, persisted in UserDefaults
- [x] Menubar app with submenus, Auto-flip toggle, Quit
- [x] App-bundle build target (`make app`) with ad-hoc codesign
- [x] Permission diagnostics on startup (Accessibility + Input Monitoring)
- [x] Auto-flip at word end (off by default until dicts grow)
- [x] Cached char-map lookup (hot path no longer rebuilds the map each call)
- [x] Hardened pasteboard restore delay (300 ms) for slow editors
- [x] Local AI assist via Ollama for selected-text grammar fixes, translation,
  and screen-region OCR

---

## Phase 1 — Smart heuristics (Caramba-parity and beyond)

Goal: app feels intelligent out of the box — minimal toggles, never gets in the
way, learns from the user. Ordered roughly by impact / effort ratio.

### 1.1 Self-learning via Backspace ⭐
**The single biggest UX win.** If we auto-flip a word and the user immediately
hits Backspace (within ~2 seconds, before any other typing), we:
1. Detect the "auto-flip → Backspace storm" pattern
2. Reverse the flip — re-type the original word, switch the layout back
3. Add the word's hash to a local "never auto-flip this" set in `UserDefaults`
4. Optionally show a one-time toast: "Won't auto-flip 'foo' anymore"

This neatly side-steps the dictionary-coverage problem. The dict can stay
imperfect because users teach the app their jargon.

State machine: track `lastAutoFlip = (originalWord, convertedWord, sourceLayout, targetLayout, timestamp)`. On Backspace events received within 2 s of a flip, count consecutive Backspaces — if `count == convertedWord.count + 1` (the converted word + the trailing space), assume the user wanted the original and trigger the rollback.

### 1.2 Context-aware auto-flip kill-switch
Read `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` on every key event (cheap — cached pointer):

**Hard-coded "never auto-flip" bundle IDs:**
- Terminals: `com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`, `com.mitchellh.ghostty`
- IDEs: `com.microsoft.VSCode`, `com.jetbrains.intellij*`, `com.jetbrains.pycharm*`, `com.jetbrains.WebStorm*`, `com.apple.dt.Xcode`, `dev.zed.Zed`, `org.vim.MacVim`, `com.sublimetext.4`
- Password managers: `com.1password.1password*`, `com.lastpass.LastPass`, `com.agilebits.onepassword*`
- Anything containing `password`, `keychain`, `secrets` in the name

The hotkey itself remains active everywhere (user explicit intent), but auto-flip stays silent in these apps.

**User overrides:** Preferences pane lets users add their own bundle IDs to the blacklist or whitelist a normally-blocked app.

### 1.3 Fullscreen / game detection
Compare focused window's frame to the screen size. If the window covers the entire screen and has no title bar, assume it's a game or video player and pause auto-flip + hotkey detection.

```swift
let windowFrame = focusedWindow.frame
let screenFrame = NSScreen.main?.frame
let isFullscreen = windowFrame.size == screenFrame?.size && windowFrame.origin == .zero
```

### 1.4 Password / high-entropy detector
Before triggering auto-flip on a finished word, score it on entropy:

| Signal | Weight |
|---|---|
| length > 8 | +1 |
| has uppercase + lowercase mixed | +2 |
| has digits | +1 |
| has special chars | +2 |
| no vowels | +2 |
| total score ≥ 4 → looks like a password |

If it looks like a password → skip auto-flip even if the converted form is in the dictionary. Manual hotkey still works (explicit intent).

### 1.5 Double-cAPS fix (sticky-shift correction)
Detect `WOrld → World`, `ПРивет → Привет` patterns. Trigger: the just-completed word starts with two uppercase chars then continues lowercase, with the same alphabet throughout.

When matched: erase the word, retype it with the second char lowercased. Independent of layout-flip — runs as a separate post-processing step. Disable in IDEs / password apps via the same context-blacklist as 1.2.

### 1.6 Both-Shifts to pause/resume
Press **left Shift + right Shift simultaneously** → toggle a "paused" mode. Status bar icon changes to indicate paused. Press the combo again → resume. Useful when typing mixed-language jargon.

Detect by tracking modifier flags: when both `kVK_Shift` and `kVK_RightShift` are pressed within ~50 ms of each other and no other key is involved.

### 1.7 Single-Shift to switch layout
Optional setting: a clean short tap of either Shift (KeyDown → KeyUp within ~250 ms, no other key in between) cycles the system input source. Replaces `⌘Space`.

Off by default — too aggressive for many users. Power-user feature, on by toggle.

### 1.8 100 % confidence threshold (already partially there)
Current scoring: original = 0 (unknown) AND target ≥ 2 (in dict) → flip. Tighten further:
- If word has any "borderline" mark (single letter that doesn't exist in either alphabet, e.g. mixed Latin + Cyrillic) → never auto-flip
- If the converted form has a homograph in the source language ("сос" in RU vs "cos" in EN — both real) → require user-defined preference or skip
- Confidence telemetry: log near-misses to stderr in debug mode so we can tune

### 1.9 Sound feedback
Tiny click on every auto-flip / correction. `NSSound(named: "Pop")` is a system sound that already exists. Toggle in Preferences. Custom WAV by drag-drop into Preferences (Caramba's UX) — Phase 3.

### 1.10 Light auto-correct (nice-to-have)
Single-keystroke typo fix in obvious words: `teh → the`, `recieve → receive`, etc. Driven by a small embedded list. Independent of layout flip. **Lowest priority** — overlaps with macOS's built-in autocorrect for many apps; only adds value where the OS one is off.

---

## Phase 2 — Bigger dictionaries

After Phase 1 lands, false positives are mostly mitigated by Backspace-learning + context blacklist + entropy filter. We can finally flip the auto-flip default back to ON and ship bigger dicts to make the win-rate higher.

### 2.1 Installable extended word-list pack
- EN / UK / RU: [`hermitdave/FrequencyWords`](https://github.com/hermitdave/FrequencyWords), OpenSubtitles 2018, CC BY-SA 4.0 for content.
- Preferences → Languages → Dictionaries downloads the full lists, cleans them,
  caps each language to the most frequent 120k words, and stores them in
  `~/Library/Application Support/LangFlip/Dictionaries`.
- `AutoFlip` reloads installed dictionaries immediately, without app restart.

### 2.2 Evaluate Hunspell / morphological dictionaries
- EN: SCOWL / LibreOffice Hunspell is permissively licensed and suitable for
  bundling with attribution.
- UK: LibreOffice `uk_UA` is MPL 1.1; upstream VESUM/dict_uk data is strong but
  has different licensing depending on the distributed derivative. Treat this
  carefully before bundling.
- RU: LibreOffice `ru_RU` uses a permissive BSD-like license with attribution
  and modified-version marking.
- Next technical step: offline Hunspell expansion into plain word forms, then
  compare false positives against the current frequency pack before shipping.

### 2.3 Default auto-flip back to ON
After 2.1 + Phase 1.1 / 1.2 / 1.4 are in. Update `Settings.autoFlip` default to `true`.

### 2.4 User-defined layout rules
Let users add local rules for words or short phrases:
- **Always flip**: source text → target layout/result, e.g. `бі` on Ukrainian
  layout should become Russian `бы`.
- **Never flip**: product names, slang, abbreviations, code words, or phrases
  that should stay exactly as typed.
- Store rules locally in `UserDefaults` or Application Support, expose them in
  Preferences, and apply them before dictionary scoring so explicit user intent
  wins over heuristics.

---

## Phase 3 — Friendly UX (for non-technical users)

### 3.1 App icon
- Simple glyph (`α`, `⇄`, custom mark)
- Export at 16 / 32 / 64 / 128 / 256 / 512 px, generate `.icns` via `iconutil`
- Reference in `Info.plist` (`CFBundleIconFile`)

### 3.2 Onboarding window (first launch)
SwiftUI three-step wizard:
- "Hi! Here's what lang-flip does" + brief animation
- "Step 1: grant Accessibility" → opens System Settings; live `AXIsProcessTrusted()` polling lights the checkmark
- "Step 2: grant Input Monitoring" → similar
- "Done! Look for ⌥ in the menu bar"

Estimate: ~150 lines in `OnboardingWindow.swift`.

### 3.3 Preferences window
SwiftUI `Settings` scene (⌘,):
- Enabled / Auto-flip toggles
- Language pickers (Primary / Secondary)
- Hotkey display + customise (later)
- Per-app blacklist editor
- Sound on/off + custom-sound drag-drop
- "Conversions today" counter
- "Pause / Resume auto-flip" hotkey (Both-Shifts) — toggle

Replaces nested submenus for power users; menubar stays for quick toggle.

### 3.4 Launch at login
`SMAppService.mainApp.register()` (macOS 13+). Toggle in Preferences.

### 3.5 Visual flip indicator
Tiny floating overlay near the cursor showing `руддщ → hello` for ~600 ms when an auto-flip happens. Lets the user see what changed, especially while learning the tool. Off by default.

### 3.6 Statistics
"You've fixed N words this week" surfaced gently in Preferences. No telemetry to a server — purely local, opt-in.

---

## Phase 4 — Distribution

### 4.1 Free path (no Apple Developer Program)
- `brew install create-dmg`
- `make dmg` target with custom background, drag-to-Applications layout
- Publish on GitHub Releases as `.dmg`
- README install instructions: download → drag to Applications → right-click → Open (Gatekeeper bypass for unsigned)

Caveat: first-run security warning. Acceptable for friends/colleagues, awkward for general public.

### 4.2 Notarized release ($99 / year Apple Developer Program)
- Sign with Developer ID Application certificate
- `xcrun notarytool submit` → wait → `stapler staple`
- Gatekeeper approves silently. Looks like any other Mac app.

### 4.3 Homebrew Cask
Submit cask file to `homebrew-cask` repo:
```ruby
cask "lang-flip" do
  version "0.x.0"
  sha256 "..."
  url "https://github.com/MikeKorotych/lang-flip/releases/download/v#{version}/lang-flip-#{version}.dmg"
  name "lang-flip"
  desc "Free keyboard layout corrector for EN ↔ UK / RU"
  homepage "https://github.com/MikeKorotych/lang-flip"
  app "lang-flip.app"
end
```

`brew install --cask lang-flip` becomes the standard install.

### 4.4 App Store investigation
Decide whether the App Store is worth the extra sandboxing and review work:
- global keyboard monitoring requires Accessibility / Input Monitoring, which
  may not fit App Store expectations cleanly
- screen OCR needs Screen Recording permission and clear user-facing purpose
- Ollama model downloads are external tooling, so onboarding must explain what
  is installed locally and what stays outside the app bundle
- if App Store is too restrictive, ship notarized DMG + Homebrew first

---

## Phase 5 — Long-term

- [ ] **Sparkle** auto-updater
- [ ] **More language pairs** — start with Slavic and common European
  languages (PL, CZ, SK, BG, SR/HR, DE, FR, ES, IT by demand)
- [ ] **Downloadable dictionary packs** — language dropdown with install/remove
  actions so users only keep the dictionaries they need locally
- [ ] **Customizable hotkeys** — remap OCR, translate, grammar fix, pause, and
  layout-flip gestures from Preferences
- [ ] **Anonymous opt-in telemetry** — counts of flips, top words, helps tune dicts
- [ ] **iCloud sync** of settings + Backspace-learned exception list
- [ ] **Inline conversion hint** — small floating label "руддщ → hello?" before the user even presses hotkey, on auto-detect confidence
- [ ] **Bigram-frequency model** layered over dict lookup for ambiguous cases
- [ ] **Light auto-correct** beyond layout flip — typos like `teh → the` (only where macOS auto-correct is off)
- [ ] **Plugin / scripting hook** — let power users add custom rules (regex-based replacements)

---

## Phase 6 — Voice layer

Goal: make Sayful useful not only while typing, but also while speaking and
listening. Keep the same product principle: explicit hotkeys, local-first where
possible, clear permissions, and no surprise network calls.

### 6.1 Dictation MVP — push-to-talk → insert text
First target because it fits Sayful's core loop best.

- Add Microphone permission onboarding and diagnostics.
- Add a configurable push-to-talk hotkey.
- Record audio while the hotkey is held, then transcribe on release.
- Insert recognized text into the focused field.
- Immediately run the existing AI cleanup pass so dictated text gets punctuation,
  casing, and typo cleanup before it lands.
- Start with `openai/whisper-large-v3-turbo` as the baseline model because it is
  MIT-licensed, multilingual, widely supported, and fast enough to validate UX.
- Run the model out-of-process first (local Python helper/service) so the macOS
  app stays small and we can swap runtimes without destabilizing EventTap.

Success criteria: dictating one paragraph into Slack/Telegram/Notes feels faster
than typing, and the final text needs little manual cleanup.

### 6.2 Streaming dictation experiment
Try to solve the Wispr Flow pain point: users should see text while speaking.

- Evaluate `Qwen/Qwen3-ASR-1.7B` and, if needed, `Qwen3-ASR-0.6B`.
- Prototype a local streaming service that emits partial transcripts.
- Decide how partial text appears:
  - temporary floating preview; or
  - live insertion into the focused field with stable replacement ranges.
- Keep an easy fallback to "transcribe after release" if streaming is unstable.

Success criteria: partial text is useful rather than distracting, and corrections
do not corrupt existing text in common apps.

### 6.3 Text-to-speech for selected text
Second product surface: let users listen while doing other tasks.

- Add "Read selected text aloud" menu action and hotkey.
- Add playback controls: play/pause/stop, speed, voice.
- MVP can use macOS `AVSpeechSynthesizer` first for low-risk native playback.
- Then evaluate `k2-fsa/OmniVoice` as an optional local model for higher-quality
  voices and multilingual output.

Success criteria: selected agent replies, articles, and docs can be listened to
without blocking the user's hands or eyes.

### 6.4 OmniVoice local TTS service
If native TTS feels too limited, integrate OmniVoice as an optional install.

- Download/install model into Application Support, not the app bundle.
- Run it as an out-of-process local service.
- Cache generated audio for repeated playback.
- Support voice design presets before custom voice cloning.
- Make model size, storage location, and deletion obvious in Preferences.

### 6.5 Voice cloning — fun, but guarded
Voice cloning can be magical and meme-worthy, but it needs careful UX.

- Only allow cloning from user-provided reference audio.
- Require an explicit consent/safety notice before enabling custom voice cloning.
- Store reference clips locally and let users delete them.
- Do not ship impersonation-oriented presets of real people or copyrighted
  characters. Prefer neutral built-in style presets.
- Label generated/clone voices clearly in UI.

Success criteria: the feature feels playful and useful without encouraging
impersonation or unsafe sharing.

### 6.6 Voice settings
Preferences should eventually include:

- STT provider/model: Whisper turbo, Qwen ASR, system dictation, custom endpoint.
- TTS provider/model: macOS voice, OmniVoice, custom endpoint.
- Model install/update/remove actions.
- Microphone device selection.
- Push-to-talk hotkey.
- Language hints and automatic language detection.
- Local storage usage for models, cached audio, and reference voices.

---

## Recommended order to resume

When picking this up next, in this order:

**Sprint 0 — Current trunk cleanup (same day)**
1. Commit and release the built-in layout rules added after v0.2.4:
   `тексті` stays Ukrainian, `єто` flips to Russian `это`.

**Sprint 1 — Smart heuristics, the core IQ jump (1–2 weeks)**
1. Phase 1.1 — Backspace self-learning (biggest single UX win)
2. Phase 1.2 — Context blacklist (terminals + IDEs + password managers)
3. Phase 1.4 — Password / entropy filter
4. Phase 1.5 — Double-caps fix
5. Phase 1.3 — Fullscreen detection
6. Phase 1.6 — Both-Shifts pause toggle
7. Phase 1.9 — Sound feedback (basic, system sound)

**Sprint 2 — Reliability uplift (3–4 days)**
8. Phase 2.1 — Bigger UK / RU dicts via build script
9. Phase 2.2 — Flip auto-flip default to ON

**Sprint 3 — Distribution-ready UX (1 week)**
10. Phase 3.1 — App icon
11. Phase 3.2 — Onboarding window
12. Phase 3.3 — Preferences window
13. Phase 3.4 — Launch at login

**Sprint 4 — Ship (2 days)**
14. Phase 4.1 — DMG packaging via `create-dmg`
15. README with screenshots, GIF demo, install instructions
16. GitHub Release v0.2.0 with `.dmg`

**Sprint 5 — Voice MVP (1–2 weeks)**
17. Phase 6.1 — Dictation MVP with Whisper large-v3-turbo
18. Phase 6.2 — Streaming ASR experiment with Qwen3-ASR
19. Phase 6.3 — TTS for selected text with macOS voices
20. Phase 6.4 / 6.5 — OmniVoice + voice cloning only after MVP UX is proven

After that the app is genuinely usable by a non-technical colleague: install the
`.dmg`, click through the wizard, type as normal — it does the right thing
without the user ever opening the menubar.

Notarization (4.2) and Homebrew Cask (4.3) wait for clear demand or external
distribution pressure.

## Why this order

1. **Smart heuristics first** — without 1.1 / 1.2 / 1.4 the auto-flip is a footgun in dev environments and password fields. Shipping a `.dmg` before this would burn first-impression goodwill.
2. **Bigger dicts second** — they raise the auto-flip win-rate, but only matter once the false-positive guards are in place.
3. **UX polish third** — onboarding + Preferences + icon are the "looks professional" layer; they go on top of working logic.
4. **DMG last** — packaging is a one-day job once the rest is solid.
