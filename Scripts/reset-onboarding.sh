#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${1:-com.antonpinkevych.lang-flip}"
MODE="${2:-settings}"
APP_NAME="${3:-LangFlip}"
SUPPORT_DIR="${HOME}/Library/Application Support/LangFlip"
HF_CACHE_DIR="${HOME}/.cache/huggingface/hub/models--k2-fsa--OmniVoice"

echo "→ Closing ${APP_NAME} if it is running…"
killall "${APP_NAME}" 2>/dev/null || true
sleep 0.5

echo "→ Resetting UserDefaults for ${BUNDLE_ID}…"
defaults delete "${BUNDLE_ID}" 2>/dev/null || true
killall cfprefsd 2>/dev/null || true

echo "→ Resetting macOS privacy permissions for ${BUNDLE_ID}…"
for service in Accessibility ListenEvent ScreenCapture Microphone; do
    tccutil reset "${service}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
done

if [[ "${MODE}" == "fresh" ]]; then
    echo "→ Removing onboarding data while keeping downloaded models/runtimes…"
    rm -rf "${SUPPORT_DIR}/Dictionaries"
    rm -rf "${SUPPORT_DIR}/TTS"
fi

if [[ "${MODE}" == "empty" ]]; then
    echo "→ Removing LangFlip dictionaries, generated audio, models, and runtimes…"
    rm -rf "${SUPPORT_DIR}/Dictionaries"
    rm -rf "${SUPPORT_DIR}/TTS"
    rm -rf "${SUPPORT_DIR}/Models"
    rm -rf "${SUPPORT_DIR}/Runtimes"
    rm -rf "${HF_CACHE_DIR}"

    if command -v ollama >/dev/null 2>&1; then
        echo "→ Removing LangFlip's recommended Ollama model if it exists…"
        ollama rm qwen3.5:4b >/dev/null 2>&1 || true
    else
        echo "→ Ollama CLI not found; skipped Ollama model cleanup."
    fi
fi

echo "✓ Onboarding state reset."
if [[ "${MODE}" == "empty" ]]; then
    echo "  Removed downloaded LangFlip models/runtimes and qwen3.5:4b from Ollama when available."
else
    echo "  Kept downloaded models and runtimes in:"
    echo "  ${SUPPORT_DIR}/Models"
    echo "  ${SUPPORT_DIR}/Runtimes"
fi
