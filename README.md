# lang-flip

Free, open-source alternative to [Caramba Switcher](https://caramba-switcher.com/) for macOS.
Type a word in the wrong keyboard layout — `lang-flip` notices on the next space, fixes the
word, and switches the system input source. Runs as a menubar app.

Supports **EN ↔ UK ↔ RU**.

## Features

- 🪄 **Auto-flip** on word boundary. Type `руддщ` (= `hello` typed on Ukrainian) followed by
  space → it becomes `hello ` and the system layout switches to ABC. Uses macOS's built-in
  English dictionary plus an embedded list of common UK / RU words to avoid touching real words.
- ⌨️ **Manual hotkey** `⌃⌥⌘\` — converts the last word, regardless of the auto-flip setting.
- 🟦 **Menubar app** — toggle Enabled / Auto-flip / Quit. No Dock icon, no preferences window.

## Build

```sh
# Just the binary:
swift build -c release

# Full .app bundle (recommended):
make app                # → build/lang-flip.app
make install            # → /Applications/lang-flip.app
make run                # build + open
```

## First launch

macOS will prompt for **Accessibility** permission — required for the global event tap.
Approve it in **System Settings → Privacy & Security → Accessibility** and relaunch. Some
macOS versions also require **Input Monitoring** for the same binary; grant it the same way.

## How it works

1. A `CGEventTap` watches every keystroke and keeps a buffer of the in-progress word.
2. On a word boundary (space, punctuation, newline), the just-completed word is scored:
   - 2 points if it's in the dictionary of its current layout
   - 1 if it just *looks* like a word in that layout (vowels, no triple-letter runs)
   - 0 otherwise
3. The same word is then converted to each of the other two layouts and scored again.
4. If the original scores 0 and a converted version scores ≥ 2, we erase the word + boundary,
   switch the system input source via `TISSelectInputSource`, retype the converted text and
   re-emit a space.
5. The manual hotkey skips the scoring and just flips the current buffer.

## Project layout

```
Sources/LangFlip/
  main.swift              — NSApplication bootstrap
  MenubarController.swift — NSStatusItem menu
  Settings.swift          — UserDefaults toggles
  EventTap.swift          — CGEventTap + key synthesis
  WordBuffer.swift        — current-word buffer
  Layouts.swift           — physical-key char maps + layout detection
  InputSource.swift       — TIS API wrapper
  AutoFlip.swift          — score / suggest flip
  EmbeddedDicts.swift     — compact UK / RU common-word lists
Resources/Info.plist      — bundle metadata, LSUIElement=YES
Makefile                  — wraps swift build into a .app
```

## Limitations

- Some apps (terminals, password fields, some IME-driven editors) reject synthesized unicode
  keystrokes — auto-flip will appear to do nothing inside them.
- If your installed input sources have unusual IDs, edit `InputSource.switchTo`.
- The embedded UK / RU word lists are tiny (~250 each). Real words outside them won't be
  *protected* from accidental flip, but the auto-flip threshold (`originalScore == 0`) keeps
  this rare in practice.
- No code signing / notarization yet — you'll see a Gatekeeper warning on a fresh install
  until the binary is notarized.

## Roadmap

- [ ] Configurable hotkey + target layout pairs in the menubar
- [ ] Per-app blacklist (skip Terminal, password fields, etc.)
- [ ] Bigger embedded dictionaries (or pull from the system if available)
- [ ] Notarized release builds
- [ ] Login item / launch-at-login toggle
