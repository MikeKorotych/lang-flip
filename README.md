# LangFlip

<p align="center">
  <img src="docs/media/overlay-animation.gif" alt="LangFlip rewrite animation" width="160" />
</p>

LangFlip is a macOS menu-bar writing assistant for people who type in several
languages every day. It fixes wrong-keyboard-layout text, polishes grammar,
translates selected text, and can copy text from a selected area of the screen.

The layout fixer works locally with rules and dictionaries. AI features are
optional and can run on your Mac through Ollama. The current recommended local
model is **Qwen 3.5 2B** because it is fast, light, and good enough for short
grammar fixes. **Qwen 3.5 4B** remains available as a heavier quality option for
Macs with 16 GB+ RAM when the smaller model makes mistakes.

Supports **English, Ukrainian, and Russian** out of the box.

## ✨ What It Does

- 🔁 **Fixes wrong layout while you type.** Type `руддщ` when you meant `hello`,
  press Space, and LangFlip rewrites it as `hello` while switching the system
  input source back to ABC.
- ✍️ **Flips selected text.** Select a word, sentence, or paragraph and
  double-tap Shift. LangFlip converts the keyboard layout and restores your
  clipboard afterward.
- 🧠 **Corrects selected text with local AI.** Select text and tap Shift once to
  fix typos, punctuation, capitalization, and small grammar mistakes.
- ⚡ **Fixes the last sentence without selecting text.** Tap Shift at the end of
  a sentence and LangFlip can clean up just that sentence.
- 🌍 **Translates selected text.** Translate into English, Ukrainian, or Russian
  from the menu, or press Shift+Space to translate into your current keyboard
  layout language.
- 📸 **Captures text from the screen.** Press Shift+Command+S, select a screen
  region, and LangFlip copies recognized text to the clipboard.
- ↩️ **Learns from Backspace.** If LangFlip flips something you did not want, press
  Backspace and it remembers that word as an exception.
- 📚 **Installs extended dictionaries.** Download larger EN/UK/RU word lists
  from Preferences to improve auto-flip coverage without updating the app.
- 🛡️ **Stays out of risky places.** Auto-flip is quiet in terminals, password
  managers, and other apps where automatic rewrites would be dangerous.

## 💡 Why Use It

LangFlip saves the small but constant effort of correcting text by hand:

- fewer layout-switching mistakes;
- less copy/paste into browser-only grammar tools;
- quick cleanup in any macOS app, not just the browser;
- local AI processing when using Ollama;
- copy text from screenshots when visible text is hard or impossible to select.

It is especially useful for programmers, office workers, founders, support
teams, writers, and anyone who switches languages all day.

## ⌨️ Basic Use

After installation, LangFlip lives in the macOS menu bar. The first launch
onboarding walks you through permissions, extended dictionaries, Qwen 3.5 setup,
and two quick tests.

Common shortcuts:

- **Single Shift** - fix selected text, or the last sentence when nothing is
  selected.
- **Double Shift** - flip selected text, or the last wrong-layout word run when
  nothing is selected. By default, English-layout text flips to Ukrainian.
- **Triple Shift** - same as Double Shift, but uses the secondary language. By
  default, English-layout text flips to Russian.
- **Shift+Space** - translate selected text into the current keyboard layout language.
- **Shift+Command+S** - copy text from a selected screen region.
- **Both Shift keys** - pause or resume LangFlip.

The selection-based actions are the most predictable. The no-selection
single/double Shift actions are designed for fast everyday typing and can be
disabled in Preferences.

For better auto-flip coverage, open **Preferences → Languages → Dictionaries**
and install the extended word-list pack.

## 🚀 Install

1. Download the latest **LangFlip-X.Y.Z.dmg** from
   [Releases](https://github.com/MikeKorotych/lang-flip/releases).
2. Open the DMG and drag **LangFlip** into Applications.
3. Open LangFlip from Applications.
4. Follow the onboarding steps for macOS permissions:
   - **Accessibility** lets LangFlip rewrite text and control input sources.
   - **Input Monitoring** lets LangFlip detect hotkeys and typed words.
   - **Screen Recording** is needed only for screen text capture.

After onboarding, look for the LangFlip icon in the menu bar.

## 🤖 Local AI Setup

AI is optional. For the best local experience, use the onboarding checklist. It
can install/select Qwen 3.5, run a grammar test, and test copy text from
screenshot.

Manual setup:

1. Install and open [Ollama](https://ollama.com/).
2. Open **LangFlip → Preferences → AI**.
3. Choose **Ollama (local)**.
4. Install or select **Qwen 3.5 2B**. If you want to compare quality, try
   **Qwen 3.5 4B** from the same menu, preferably on a Mac with 16 GB+ RAM.
5. Run the built-in grammar and copy-text-from-screenshot tests.

In Ollama mode, LangFlip talks to `127.0.0.1:11434`. Your text and screenshots
are sent to the local Ollama daemon on your Mac, not to LangFlip servers.

## 🔒 Privacy

- The core layout correction is local and rule-based.
- Ollama AI mode runs locally on your Mac.
- Cloud AI providers are optional and only used if you configure them.
- API keys are stored in macOS Keychain.
- LangFlip does not collect analytics by default.

## 🛠️ Current Status

LangFlip is usable as a daily writing helper. The current release candidate is
focused on a much smoother first session: clearer onboarding, easier model
setup, built-in tests, better hotkey explanation, and safer reset commands for
development.

Planned improvements include:

- downloadable dictionaries for more Slavic and European languages;
- richer custom hotkey recording across more actions;
- App Store feasibility research;
- iCloud sync for settings and learned exceptions.

See [CHANGELOG.md](CHANGELOG.md) for recent release notes and
[ROADMAP.md](ROADMAP.md) for the longer plan.

## 🧑‍💻 Build From Source

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

Onboarding test commands:

```sh
make reset-onboarding        # reset settings + permissions, keep downloads
make reset-onboarding-fresh  # also remove installed dictionaries and TTS files
make reset-onboarding-empty  # full new-user reset, including local models
make run-onboarding          # reset fresh, rebuild, install, launch
make run-onboarding-empty    # full new-user reset, rebuild, install, launch
```

## 📄 License

MIT.
