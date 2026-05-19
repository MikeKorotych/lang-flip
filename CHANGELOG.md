# Changelog

## 0.2.7 - Stability Release

This release focuses on typing stability after the performance work in 0.2.6,
especially the first auto-flip after launch and double-Shift word rewrites.

### Added

- Manual “Always flip” rules in General > Learning, with a target language per
  word.

### Improved

- Faster startup by loading larger dictionaries in the background while keeping
  deterministic built-in and manual rules available immediately.
- Lower per-keystroke overhead by caching repeated lowercase work and frontmost
  app suppression checks.
- Faster selected-text actions with exponential pasteboard polling.
- More reliable synthetic rewrites by keeping conservative event timing where
  apps are known to drop fast key bursts.

### Fixed

- Stabilized the first auto-flip after app launch so the word rewrite lands
  before LangFlip switches the active input source.
- Fixed double-Shift focused-word rewrites that could miss the first character
  or select too much text after the performance changes.
- Kept flip feedback smooth by decoupling the visual/audio confirmation from
  the slower first keyboard-layout switch.

## 0.2.6 - Patch Release

This patch release tightens the new-user flow and fixes a few high-impact
typing and translation edge cases found during daily use.

### Improved

- Shift+Space now translates selected text into the language of the active
  keyboard layout.
- Triple Shift defaults to Russian as the secondary language, while Double
  Shift keeps Ukrainian as the primary default.
- General settings now show optional Screen Recording and Microphone
  permissions with short explanations.
- Onboarding returns to the setup checklist after the macOS Screen Recording
  permission flow requires a restart.

### Fixed

- Prevented Shift+Space translations from appending translated text after the
  original selection.
- Disabled speech-to-text hotkeys by default so voice features stay opt-in.
- Kept bracket keys inside auto-flip words, fixing cases like `[jxe` → `хочу`.
- Clarified layout-target explanations in README, onboarding, and preferences.

## 0.2.5 - Release Candidate

This release focuses on making LangFlip easier to install, understand, and use
in the first session.

### Added

- First-run onboarding checklist after macOS permissions.
- One-click extended dictionary install from onboarding.
- Qwen 3.5 local AI setup from onboarding, with Ollama install guidance.
- Qwen 3.5 2B as the default local AI model, with 4B kept as a heavier quality
  option for 16 GB+ Macs when the smaller model makes mistakes.
- Built-in grammar test showing input and output.
- Safer default grammar-test text that works better with the smaller local
  model.
- Built-in copy-text-from-screenshot test with a visible target and paste check.
- Hotkey summary in onboarding:
  - Single Shift - fix selected text or the last sentence.
  - Double Shift - flip selected text or the last wrong-layout word run.
  - Shift+Space - translate selected text into the current keyboard layout language.
  - Shift+Command+S - copy text from a selected screenshot area.
- Developer reset commands for testing first-run flows:
  - `make reset-onboarding`
  - `make reset-onboarding-fresh`
  - `make reset-onboarding-empty`
  - `make run-onboarding`
  - `make run-onboarding-empty`

### Improved

- Qwen install flow no longer opens Ollama unnecessarily after it is installed.
- Dictionary install and Qwen download states are clearer.
- “OCR” wording in user-facing UI is now “copy text from screenshot” or
  “screenshot text capture.”
- Onboarding buttons keep stable layout while running.
- Input Monitoring onboarding avoids optimistic macOS permission prompts and
  guides the user to add `/Applications/LangFlip.app` manually when needed.

### Fixed

- Prevented several false-positive auto-flips, including Russian `доступы`.
- Stabilized no-selection Single Shift and Double Shift behavior around
  multiline text and cursor placement.
- Reduced first local-model latency by warming up text and vision requests
  sequentially instead of in parallel.
- Improved no-selection Single Shift fallback for text fields that do not expose
  their content through Accessibility.

### Notes

- Local AI features still depend on Ollama for Qwen 3.5.
- Whisper dictation and OmniVoice text-to-speech are available as experimental
  local voice features.
