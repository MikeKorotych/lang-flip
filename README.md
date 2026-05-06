# LangFlip

Free, open-source keyboard layout corrector for macOS. Type a word in the wrong layout,
**LangFlip** fixes it on the fly and switches the system input source. Inspired by
[Caramba Switcher](https://caramba-switcher.com/).

Supports **EN ↔ UK ↔ RU** out of the box.

> Repo / package / build directory is named `lang-flip` (kebab-case);
> the user-facing app is **LangFlip** (CamelCase). Bundle ID is
> `com.antonpinkevych.lang-flip`.

## Install

1. Download the latest **LangFlip-X.Y.Z.dmg** from
   [Releases](https://github.com/MikeKorotych/lang-flip/releases).
2. Open the DMG and drag **LangFlip** into your Applications folder.
3. Open LangFlip from Applications. The first launch shows a small wizard that walks
   you through granting two macOS permissions:
   - **Accessibility** — needed to read keystrokes globally
   - **Input Monitoring** — needed on macOS 10.15+

   Both buttons in the wizard deep-link straight to the right pane in System Settings.

That's it. After the wizard you'll see a small `⌥` icon in the menu bar.

> Releases are signed with a Developer ID and notarized by Apple, so Gatekeeper accepts
> them without the "unidentified developer" warning. If you build from source yourself,
> you'll get the warning until you sign the binary — see [Distribution](#distribution).

## Features

- **Auto-flip on the fly.** Type `руддщ` on a Ukrainian layout when you meant `hello`,
  hit space → LangFlip rewrites it as `hello ` and switches you to ABC. The opposite
  direction (latin gibberish → cyrillic) works too.
- **Selection mode.** Just realised a whole paragraph is in the wrong layout? Select it,
  double-tap Shift, done — Cmd+C / convert / Cmd+V under the hood, with your original
  clipboard restored.
- **Smart hotkeys** (à la Caramba):
  - **⇧⇧** swap with the primary language
  - **⇧⇧⇧** swap with the secondary (if configured)
  - **Both ⇧ at once** — pause / resume the whole app
- **Self-learning.** Got a flip you didn't want? Hit Backspace and LangFlip both undoes
  it and remembers never to flip that exact word again. No exception list to manage by
  hand — one Backspace teaches it.
- **Sticky-shift fix.** `WOrld` → `World`, `ПРивет` → `Привет`. Only fires when the
  corrected form is a real dictionary word, so acronyms like `OAuth` stay intact.
- **Context-aware.** Auto-flip stays silent in terminals (Terminal, iTerm2, Warp,
  Ghostty, …) and password managers (1Password, LastPass, Bitwarden, …) — anywhere a
  bad rewrite would do real damage. Optional: pause in fullscreen apps (off by default).
- **Per-app override.** From the menubar, disable auto-flip in any specific app you don't
  want it touching.
- **Sound feedback.** Quiet system tick on every rewrite. Off by default.
- **Launch at login.** One toggle in Preferences.
- **Bundled UK / RU dictionaries.** ~45 k words each, frequency-ordered (from the
  OpenSubtitles 2018 corpus). The English dictionary is the system one at
  `/usr/share/dict/words`.

## Project layout

```
Sources/LangFlip/
  LangFlipApp.swift         — @main App + AppDelegate
  MenubarController.swift   — NSStatusItem (Enabled / Auto-flip / Preferences… / Quit)
  OnboardingWindow.swift    — first-launch permissions wizard
  PreferencesWindow.swift   — Preferences window controller
  PreferencesView.swift     — five-section SwiftUI layout
  Settings.swift            — UserDefaults toggles
  EventTap.swift            — CGEventTap + key synthesis
  WordBuffer.swift          — current-word buffer
  Layouts.swift             — physical-key char maps + layout detection
  InputSource.swift         — TIS API wrapper (language-property based)
  AutoFlip.swift            — score / suggest flip + password entropy filter
  AppContext.swift          — context blacklist + fullscreen detection
  BackspaceLearner.swift    — undo + exception list state machine
  DoubleCapsFix.swift       — sticky-shift correction
  PermissionStatus.swift    — Accessibility + Input Monitoring read/prompt
  LaunchAtLogin.swift       — SMAppService.mainApp wrapper
  Sound.swift               — NSSound feedback
  Pasteboard.swift          — capture + restore round-trip
  Notifications.swift       — internal NotificationCenter names
  Dictionaries/             — bundled uk-words.txt + ru-words.txt
Resources/
  Info.plist                — bundle metadata, LSUIElement, version
  AppIcon.icns              — generated from lang-flip-logo.png
  AppIcon.iconset/          — source PNGs for AppIcon.icns
  lang-flip-logo.png        — 1024x1024 master icon
  lang-flip.entitlements    — hardened-runtime entitlements (intentionally empty)
Scripts/
  build-dicts.sh            — fetch + clean UK / RU frequency lists
  build-icon.sh             — master PNG → iconset → .icns
Makefile                    — build / sign / dmg / notarize / release
ROADMAP.md                  — future plans
```

## Build from source

```sh
make app                  # → build/LangFlip.app (ad-hoc signed, Gatekeeper will warn)
make run                  # build + open the .app
make install              # copies build/LangFlip.app → /Applications/
make clean                # nuke .build and build/
```

`make app` is enough for local development. For distribution, see below.

## Distribution

Each release goes through five stages, automated via `make release`:

```
make release
   ├── make build        # swift build -c release
   ├── make app          # assemble .app bundle (incl. dictionaries + icon)
   ├── make sign         # codesign with Developer ID Application + hardened runtime
   ├── make dmg          # create-dmg with drag-to-Applications layout
   └── make notarize     # xcrun notarytool submit + xcrun stapler staple
```

You can also run individual targets — they all `make app` first as a dependency, so
they're idempotent.

### One-time setup

You need an Apple Developer account ($99 / year) and one signing identity.

1. **Developer ID Application certificate.**
   At <https://developer.apple.com/account/resources/certificates/add>, pick
   **Developer ID Application**, follow the CSR flow, and double-click the downloaded
   `.cer` to install it. Verify with:
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **App-specific password** for notarytool.
   Go to <https://account.apple.com/account/manage> → App-Specific Passwords →
   Generate. Save the 4×4 password.

3. **Keychain profile** so notarytool doesn't prompt every release:
   ```sh
   xcrun notarytool store-credentials lang-flip-notarize \
       --apple-id   you@example.com \
       --team-id    YOURTEAMID \
       --password   xxxx-xxxx-xxxx-xxxx
   ```
   Find your Team ID at <https://developer.apple.com/account> → Membership.

After this you can ship a release with one command:

```sh
make release                              # build + sign + dmg + notarize + staple
gh release create v0.2.0 build/LangFlip-0.2.0.dmg
```

### Without a Developer Account

You can still ship something. Skip `sign` / `notarize`, run only:

```sh
make dmg
```

Tell users on first launch to right-click → Open (Gatekeeper bypass for unsigned).
Useful for sharing with friends; not recommended for general distribution.

## Limitations

- Some apps (terminals, password fields, some IME-driven editors) reject synthesized
  unicode keystrokes — auto-flip stays silent there by default. Manual hotkey still
  works in most.
- If your installed input sources don't expose a primary language code (rare), the
  app may not recognize them. Edit `InputSource.swift` if you hit this.
- Backspace-learning is keyed on the lowercased word; case-sensitive jargon "Foo" and
  "foo" share an exception slot.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the long list. Highlights still ahead:

- Sparkle auto-updater
- More language pairs (PL / DE / FR by demand)
- Anonymous opt-in telemetry to tune the dictionaries
- iCloud sync of settings + learned exception list

## License

MIT.
