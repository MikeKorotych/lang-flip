# lang-flip — Roadmap

Living document. Updated 2026-05-06 after a deep dive into Caramba Switcher's
internals — many ideas below are inspired by what makes Caramba feel "smart"
without configuration screens.

## Done

- [x] Core EN ↔ UK / RU char-based conversion via physical-key map
- [x] Layout detection from typed text (alphabet voting)
- [x] Stable input-source switching via TIS language property API (not bundle-ID substring)
- [x] CGEventTap with feedback-loop protection (`eventSourceUserData` magic stamp)
- [x] Double-Shift hotkey — clean detection (ignores Shift used as a real modifier)
- [x] Triple-Shift hotkey — for secondary language; auto-disabled when none set so double-tap stays instant
- [x] Selection-based flip — Cmd+C → convert → Cmd+V → restore clipboard, handles half-paragraph case
- [x] Word-buffer fallback — when no selection, flip the last word in the in-progress buffer
- [x] Primary / secondary language settings, persisted in UserDefaults
- [x] Menubar app with submenus, Auto-flip toggle, Quit
- [x] App-bundle build target (`make app`) with ad-hoc codesign
- [x] Permission diagnostics on startup (Accessibility + Input Monitoring)
- [x] Auto-flip on word boundary (off by default until dicts grow)
- [x] Cached char-map lookup (hot path no longer rebuilds the map each call)
- [x] Hardened pasteboard restore delay (300 ms) for slow editors

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

### 2.1 Embed proper UK / RU word lists
- UK: [`brown-uk/dict_uk`](https://github.com/brown-uk/dict_uk) (~150 k, MIT)
- RU: [`danakt/russian-words`](https://github.com/danakt/russian-words) (~50 k, public domain)
- Frequency-rank top 30 k each, lowercase, drop apostrophes/dashes for v1
- `Scripts/build-dicts.sh` fetches → cleans → writes `Resources/uk-words.txt`, `Resources/ru-words.txt`
- `AutoFlip` reads them on init (~300 KB total embedded)

### 2.2 Default auto-flip back to ON
After 2.1 + Phase 1.1 / 1.2 / 1.4 are in. Update `Settings.autoFlip` default to `true`.

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

---

## Phase 5 — Long-term

- [ ] **Sparkle** auto-updater
- [ ] **More language pairs** (PL, DE, FR, by demand)
- [ ] **Anonymous opt-in telemetry** — counts of flips, top words, helps tune dicts
- [ ] **iCloud sync** of settings + Backspace-learned exception list
- [ ] **Inline conversion hint** — small floating label "руддщ → hello?" before the user even presses hotkey, on auto-detect confidence
- [ ] **Bigram-frequency model** layered over dict lookup for ambiguous cases
- [ ] **Light auto-correct** beyond layout flip — typos like `teh → the` (only where macOS auto-correct is off)
- [ ] **Plugin / scripting hook** — let power users add custom rules (regex-based replacements)

---

## Recommended order to resume

When picking this up next, in this order:

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
