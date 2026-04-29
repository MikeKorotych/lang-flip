# lang-flip

Free, open-source alternative to [Caramba Switcher](https://caramba-switcher.com/) for macOS.
Type a word in the wrong keyboard layout, hit a hotkey, and it converts the word **and** switches
the system input source.

Supports **EN ↔ UK ↔ RU** out of the box.

## Status

MVP — manual hotkey conversion. Auto-detection on space/punctuation is on the roadmap.

## How it works

1. A `CGEventTap` watches keystrokes globally and keeps a buffer of the current word.
2. When you press the hotkey, the last word is converted character-by-character using a physical-key
   map (e.g. UK `й` lives on the same key as EN `q`).
3. The original word is erased with backspaces, the system layout is switched via
   `TISSelectInputSource`, and the converted text is re-typed.

## Build

```sh
swift build -c release
```

The binary lands at `.build/release/LangFlip`.

## Run

```sh
./.build/release/LangFlip
```

The first run will trigger a macOS permission prompt for **Accessibility**. Approve it in
**System Settings → Privacy & Security → Accessibility**, then run again. Some macOS versions also
require **Input Monitoring** for the same binary.

## Hotkey

Default: `⌃⌥⌘\` (control + option + command + backslash).

To change it, edit `hotkeyKeyCode` / `hotkeyMask` in [`Sources/LangFlip/EventTap.swift`](Sources/LangFlip/EventTap.swift).

## Conversion direction

Heuristic for now:

- Word looks like EN → convert to UK.
- Word looks like UK or RU → convert to EN.

If you primarily switch EN ↔ RU, change the target in `convertLastWord()`.

## Limitations

- Some apps (terminals, password fields, IME-driven editors) may reject synthesized unicode
  keystrokes. The hotkey will appear to do nothing in those.
- If your installed keyboard layouts have different IDs than `com.apple.keylayout.ABC` /
  `…Ukrainian` / `…Russian`, edit `InputSource.switchTo`.
- No menubar UI, no preferences panel — yet.

## Roadmap

- [ ] Auto-flip on word boundary using a frequency dictionary
- [ ] Menubar app + preferences (hotkey, target layout pairs)
- [ ] App bundle + notarization for distribution
- [ ] Per-app blacklist (don't act inside Terminal, password fields, etc.)
