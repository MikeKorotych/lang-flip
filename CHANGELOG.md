# Changelog

## 0.2.4 - Release Candidate

This release focuses on making LangFlip easier to install, understand, and use
in the first session.

### Added

- First-run onboarding checklist after macOS permissions.
- One-click extended dictionary install from onboarding.
- Qwen 3.5 local AI setup from onboarding, with Ollama install guidance.
- Qwen 3.5 2B as the default local AI model, with 4B kept as a heavier quality
  option for comparison.
- Built-in grammar test showing input and output.
- Built-in copy-text-from-screenshot test with a visible target and paste check.
- Hotkey summary in onboarding:
  - Single Shift - fix selected text or the last sentence.
  - Double Shift - flip selected text or the last wrong-layout word run.
  - Shift+Space - translate selected text.
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

### Notes

- Local AI features still depend on Ollama for Qwen 3.5.
- Whisper dictation and OmniVoice text-to-speech are available as experimental
  local voice features.
