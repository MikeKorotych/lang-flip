# LangFlip

LangFlip is a macOS menu-bar writing assistant for people who type in several
languages every day. It fixes wrong-keyboard-layout text, polishes grammar,
translates selected text, and can copy text from a selected area of the screen.

The layout fixer works locally with rules and dictionaries. AI features are
optional and can run on your Mac through Ollama. The current recommended local
model is **Qwen 3.5 4B**.

Supports **English, Ukrainian, and Russian** out of the box.

## What It Does

- **Fixes wrong layout while you type.** Type `руддщ` when you meant `hello`,
  press Space, and LangFlip rewrites it as `hello` while switching the system
  input source back to ABC.
- **Fixes selected text.** Select a word, sentence, or paragraph and use the
  hotkey. LangFlip converts the text and restores your clipboard afterward.
- **Corrects grammar with local AI.** A single Shift tap can fix typos,
  punctuation, capitalization, and small grammar mistakes in selected text or in
  the latest sentence.
- **Auto-fixes completed sentences.** When enabled, typing `.`, `!`, or `?`
  can trigger a quick grammar pass on the sentence you just finished.
- **Translates selected text.** Translate into English, Ukrainian, or Russian
  from the menu or with the optional Shift+Space hotkey.
- **Captures text from the screen.** Press Shift+Command+S, select a screen
  region, and LangFlip copies recognized text to the clipboard.
- **Learns from Backspace.** If LangFlip flips something you did not want, press
  Backspace and it remembers that word as an exception.
- **Stays out of risky places.** Auto-flip is quiet in terminals, password
  managers, and other apps where automatic rewrites would be dangerous.

## Why Use It

LangFlip saves the small but constant effort of correcting text by hand:

- fewer layout-switching mistakes;
- less copy/paste into browser-only grammar tools;
- quick cleanup in any macOS app, not just the browser;
- local AI processing when using Ollama;
- OCR for visible text that is hard or impossible to select.

It is especially useful for programmers, office workers, founders, support
teams, writers, and anyone who switches languages all day.

## Basic Use

After installation, LangFlip lives in the macOS menu bar.

Common shortcuts:

- **Double-tap Shift** - flip the latest word or selected text.
- **Triple-tap Shift** - switch to the secondary language, or use it for AI fix
  if configured that way.
- **Press both Shift keys** - pause or resume LangFlip.
- **Single Shift tap** - AI-fix selected text or the latest sentence, if enabled.
- **Shift+Space** - translate selected text, if enabled.
- **Shift+Command+S** - capture text from a selected screen region.

Most behavior can be changed in **Preferences**.

## Install

1. Download the latest **LangFlip-X.Y.Z.dmg** from
   [Releases](https://github.com/MikeKorotych/lang-flip/releases).
2. Open the DMG and drag **LangFlip** into Applications.
3. Open LangFlip from Applications.
4. Follow the onboarding steps for macOS permissions:
   - **Accessibility** lets LangFlip rewrite text and control input sources.
   - **Input Monitoring** lets LangFlip detect hotkeys and typed words.
   - **Screen Recording** is needed only for screen text capture.

After onboarding, look for the LangFlip icon in the menu bar.

## Local AI Setup

AI is optional. For the best local experience:

1. Install and open [Ollama](https://ollama.com/).
2. Open **LangFlip → Preferences → AI**.
3. Choose **Ollama (local)**.
4. Install or select **Qwen 3.5 4B**.
5. Run the built-in grammar and OCR tests.

In Ollama mode, LangFlip talks to `127.0.0.1:11434`. Your text and screenshots
are sent to the local Ollama daemon on your Mac, not to LangFlip servers.

## Privacy

- The core layout correction is local and rule-based.
- Ollama AI mode runs locally on your Mac.
- Cloud AI providers are optional and only used if you configure them.
- API keys are stored in macOS Keychain.
- LangFlip does not collect analytics by default.

## Current Status

LangFlip is already usable as a daily writing helper. The next release work is
focused on polishing onboarding, simplifying the menu, improving first-session
AI setup, and preparing a public release.

Planned improvements include:

- downloadable dictionaries for more Slavic and European languages;
- customizable hotkeys;
- smoother model installation;
- App Store feasibility research;
- iCloud sync for settings and learned exceptions.

See [ROADMAP.md](ROADMAP.md) for the longer plan.

## Build From Source

For local development:

```sh
make dev
```

This builds, signs, installs, and launches `/Applications/LangFlip.app`. Use this
instead of opening the raw `build/` copy, because macOS privacy permissions are
tied to the installed signed app.

Other useful commands:

```sh
make app       # build build/LangFlip.app
make run       # same daily path as make dev
make install   # copy build/LangFlip.app to /Applications
make release   # build, sign, package, notarize, and staple a release DMG
```

## License

MIT.
