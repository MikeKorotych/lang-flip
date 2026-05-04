# lang-flip — Roadmap

Living document. Reflects status as of v0.1.x development.

## Done

- [x] **Core conversion** — char-based EN ↔ UK / RU mapping by physical key position
- [x] **Layout detection** from typed text (most cyrillic / latin chars wins)
- [x] **System input source switching** via TIS API
- [x] **CGEventTap-based daemon** with feedback-loop protection (events tagged via `eventSourceUserData`)
- [x] **Double-Shift hotkey** — clean detection (ignores Shift used as a real modifier)
- [x] **Triple-Shift hotkey** — for secondary language; auto-disabled when no secondary set so double-tap stays instant
- [x] **Selection-based flip** — Cmd+C → convert → Cmd+V → restore clipboard. Handles half-paragraph case
- [x] **Word-buffer fallback** — when no selection, flips the last word in the in-progress buffer
- [x] **Primary / secondary language settings** — persisted in UserDefaults, swappable from menubar
- [x] **Menubar app** with submenus, Auto-flip toggle, Quit
- [x] **App bundle build** — `make app` produces a `LSUIElement=YES` `.app` with ad-hoc codesign
- [x] **Permission diagnostics on startup** (Accessibility + Input Monitoring)
- [x] **Auto-flip on word boundary** (off by default — embedded UK/RU dicts still small)

## Phase 1 — Friendly distribution & UX (next)

Goal: non-technical user can install and configure without a terminal.

### 1.1 Onboarding window (first launch)
Three-step SwiftUI wizard:
- "Hi! Here's what lang-flip does" + brief animation/GIF
- "Step 1: grant Accessibility" + button → opens System Settings
- "Step 2: grant Input Monitoring" + button → opens System Settings
- "Done! Look for ⌥ in the menu bar"

Live-monitor `AXIsProcessTrusted()` and `IOHIDCheckAccess()` so checkmarks light up automatically when permissions are granted.

Estimate: ~150 lines of SwiftUI in `OnboardingWindow.swift`.

### 1.2 Preferences window
Full GUI window (replaces nested submenus for power users):
- Toggle Enabled / Auto-flip
- Picker for primary / secondary language
- Display current hotkey + future option to change
- Counter "Conversions today: N"
- Toggle "Show in menu bar"

Triggered by `Preferences…` menu item (⌘,) — macOS standard.

### 1.3 App icon
- Design a simple glyph (letter `α`, swap symbol `⇄`, or original)
- Export at 16/32/64/128/256/512 px
- `iconutil --convert icns Resources/AppIcon.iconset`
- Reference in `Info.plist` (`CFBundleIconFile`)

### 1.4 Launch at login
- `SMAppService.mainApp.register()` (macOS 13+)
- Toggle in Preferences

## Phase 2 — Reliability

### 2.1 Bigger UK / RU dictionaries
Public sources:
- UK: [`brown-uk/dict_uk`](https://github.com/brown-uk/dict_uk) (~150k, MIT)
- RU: [`danakt/russian-words`](https://github.com/danakt/russian-words) (~50k, public domain)

Add `Scripts/build-dicts.sh` to fetch / clean / pick top 30k by frequency. Embed as `Resources/uk-words.txt` and `Resources/ru-words.txt`. Read in `AutoFlip.shared` on init. Total ~300 KB embedded.

After this, **flip the auto-flip default back to ON** — false positives should be rare.

### 2.2 Cmd+Z undo of last flip
- Record `(originalWord, source, target, timestamp)` after every flip
- Listen for Cmd+Z within 3 seconds
- Reverse the conversion, switch layout back, optionally add the word to a "never-flip" set

### 2.3 Per-app blacklist
- Read `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`
- Hardcoded defaults: `com.apple.Terminal`, `com.googlecode.iterm2`, `com.warp.Warp`, `dev.zed.Zed`
- User-editable list in Preferences
- Menu item "Disable for current app"

## Phase 3 — Distribution

### 3.1 Free path (no Apple Developer Program)
- `brew install create-dmg`
- `make dmg` target:
  ```sh
  create-dmg \
    --volname "lang-flip" \
    --icon "lang-flip.app" 175 120 \
    --app-drop-link 425 120 \
    --background "Resources/dmg-bg.png" \
    "build/lang-flip-0.1.0.dmg" \
    "build/lang-flip.app"
  ```
- Publish on GitHub Releases
- README: "Download .dmg, drag to Applications, first launch right-click → Open" (Gatekeeper bypass for unsigned)

Caveat: users see a security warning on first run. OK for friends/colleagues, awkward for general public.

### 3.2 Notarized release ($99/year Apple Developer Program)
- Sign with Developer ID Application certificate
- `xcrun notarytool submit lang-flip.dmg --keychain-profile "AC_PASSWORD" --wait`
- `xcrun stapler staple lang-flip.dmg`
- Gatekeeper approves silently. Looks like a normal app.

### 3.3 Homebrew Cask
After 3.2, submit to `homebrew-cask` repo:
```ruby
cask "lang-flip" do
  version "0.1.0"
  sha256 "..."
  url "https://github.com/MikeKorotych/lang-flip/releases/download/v#{version}/lang-flip-#{version}.dmg"
  name "lang-flip"
  desc "Free keyboard layout corrector for EN ↔ UK/RU"
  homepage "https://github.com/MikeKorotych/lang-flip"
  app "lang-flip.app"
end
```

`brew install --cask lang-flip` becomes the standard install path.

## Phase 4 — Long-term ideas

- [ ] **Sparkle auto-updater** — app updates itself silently
- [ ] **More language pairs** — PL, DE, FR (driven by demand)
- [ ] **Anonymous opt-in telemetry** — counter of flips, top words, helps tune dicts
- [ ] **iCloud sync** of settings between machines
- [ ] **Visual / sound feedback** on flip — small toast or subtle sound
- [ ] **Inline conversion hint** — small floating label "руддщ → hello?" before user even presses hotkey, based on auto-detection confidence
- [ ] **Better detection for ambiguous words** — bigram frequency model on top of dict lookup

## Recommended order to resume

When picking this up next:

**Week 1 — UX polish for non-technical users**
1. App icon (1–2 hours; placeholder fine to start)
2. Onboarding window with live permission status (1 day)
3. Preferences window in SwiftUI (1 day)
4. Launch at login toggle (2 hours)

**Week 2 — distribution**
5. Bigger dictionaries (half a day — fetch + clean script)
6. DMG packaging (2 hours — `create-dmg`)
7. README with GIF demo, screenshots, install instructions
8. GitHub release v0.1.0 with `.dmg`

After that the app is reasonably installable by a non-technical colleague: download `.dmg`, drag to Applications, right-click → Open once, follow onboarding wizard. No terminal needed.

Notarization (Phase 3.2) and Homebrew (Phase 3.3) can wait until there's clear demand.
