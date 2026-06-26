# Changelog

## 0.7.0 - Dictation, Home, and Playback Polish

This release turns the recent Sayful Cloud work into a more complete daily-use
experience: faster dictation choices, safer retry flows, clearer Home history,
and more polished playback and hotkey controls.

### Added

- Added a simple Dictation Mode switch: Fast for lower latency, Quality for
  richer transcription.
- Added retry for failed transcriptions from both the dictation island and Home
  history, reusing the recorded audio instead of losing the attempt.
- Added Home activity tabs for dictations, screen text captures, and generated
  speech files.
- Added playback controls for generated speech, including pause/resume in the
  island and Home history.
- Added animated hotkey chips in the Superpowers card, including inline
  recording and reset affordances.

### Improved

- Streamlined onboarding so a ready account opens straight into Home, with
  hands-free dictation and Shift+Space translation enabled by default.
- Made dictation auto-formatting prefer logical paragraphs for longer
  monologues while preserving the speaker's wording.
- Tightened text-polish prompts so Single Shift behaves like typo cleanup first,
  not a style rewrite.
- Polished the Dictation hero, Superpowers highlight, Transform demo sheet, and
  TTS control animations.
- Kept generated speech files in Home so they can be replayed or deleted later.

### Fixed

- Fixed TTS history rows so the play button turns into pause while the selected
  file is playing.
- Fixed playback controls appearing from the edge of the screen instead of the
  center of the dictation island.
- Fixed LangFlip word-boundary handling so punctuation keys that are Cyrillic
  letters on another layout, such as `;` for `ж`, no longer trigger an early
  auto-flip.
- Fixed Home hotkey chips getting stuck in recording state after relaunch.
- Fixed first-run permission/event-tap restart paths so hotkeys work after
  onboarding without needing a manual relaunch.

## 0.6.0 - Personal Dictation Dictionary

This release teaches Sayful how you spell product names, people, jargon, and
other personal terms after dictation.

### Added

- Added Personal dictation words in Dictionary > Learning, with manual entries
  and automatically learned spellings.
- Added a post-dictation correction learner that watches short edits after a
  transcript is inserted and stores safe `recognized phrase -> preferred
  spelling` pairs.
- Applied personal dictionary replacements before and after dictation
  auto-formatting, so saved spellings survive the cleanup pass.

### Improved

- Cached Insights usage and heatmap snapshots to reduce repeated history
  calculations while the tab renders.
- Made the dictation island lift animation quicker.

## 0.2.9 - Cloud Speech and AI Providers

This release makes LangFlip's AI features more flexible while keeping every
cloud path opt-in. Voice, dictation, screenshot text capture, and AI text fixes
can now use configured API providers instead of depending only on local models.

### Added

- Added Cloud TTS with OpenRouter/OpenAI-compatible models, curated speech
  model choices, voice selection, speed, instructions, and a built-in sample
  generator.
- Added Cloud STT for dictation through `/audio/transcriptions`, with curated
  model choices and provider-side language auto-detection.
- Added Cloud OCR for screenshot text capture with a dedicated vision-model
  picker.
- Added curated OpenRouter model selection for AI text correction and selected
  text fixes.
- Added `Fn+Option` as the default hands-free dictation toggle, with a picker
  for alternative hands-free shortcuts.
- Added `docs/plan.html` as a visual living project manual and `make plan` to
  open it.

### Improved

- Optimized OpenRouter text correction for lower latency by capping response
  size, disabling reasoning output where supported, and preferring low-latency
  provider routing.
- Kept Cloud STT language-free so transcription models infer the spoken
  language from audio instead of receiving the current keyboard layout.
- Routed screenshot text capture through cloud vision models when OpenRouter /
  OpenAI-compatible mode is enabled.
- Clarified Voice settings around local vs cloud dictation, API-key storage,
  and per-feature cloud usage.

### Removed

- Removed weak or unreliable Cloud STT choices from the curated list, including
  OpenAI Whisper 1, OpenAI GPT-4o Mini Transcribe, and OpenAI Whisper Large V3.

## 0.2.8 - Double Shift Hotfix

This hotfix tightens manual double/triple Shift behavior in editors that do not
expose normal macOS Accessibility text ranges, including Obsidian and web-based
chat inputs.

### Fixed

- Prevented Obsidian-style Cmd+C-without-selection behavior from duplicating
  and converting the whole current line.
- Added a keyboard fallback for Codex/Claude-style inputs that do not expose
  focused text through Accessibility.
- Limited the fallback to the previous word/token instead of selecting the whole
  line.
- Preserved leading spaces when replacing the previous token.
- Made manual double/triple Shift deterministic:
  - English token + double Shift -> primary language.
  - English token + triple Shift -> secondary language.
  - Non-English token + double/triple Shift -> English.
- Removed dictionary checks from manual no-selection Shift flips. Explicit
  Shift gestures now convert the last token regardless of whether it is a known
  word.

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
