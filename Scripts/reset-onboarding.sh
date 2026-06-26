#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${1:-com.antonpinkevych.sayful}"
MODE="${2:-settings}"
APP_NAME="${3:-Sayful}"
SUPPORT_DIR="${HOME}/Library/Application Support/Sayful"
LOG_DIR="${HOME}/Library/Logs/Sayful"
HF_CACHE_DIR="${HOME}/.cache/huggingface/hub/models--k2-fsa--OmniVoice"
OLD_BUNDLE_ID="com.antonpinkevych.lang-flip"
KEYCHAIN_SERVICE="com.antonpinkevych.lang-flip"
KEYCHAIN_ACCOUNTS=(
    "backend-access-token"
    "backend-refresh-token"
    "cloud-ai-api-key"
)

echo "→ Closing ${APP_NAME} if it is running…"
killall "${APP_NAME}" 2>/dev/null || true
sleep 0.5

echo "→ Resetting UserDefaults for ${BUNDLE_ID}…"
defaults delete "${BUNDLE_ID}" 2>/dev/null || true
defaults delete "${OLD_BUNDLE_ID}" 2>/dev/null || true
killall cfprefsd 2>/dev/null || true

echo "→ Resetting macOS privacy permissions for ${BUNDLE_ID}…"
for bundle in "${BUNDLE_ID}" "${OLD_BUNDLE_ID}"; do
    for service in Accessibility ListenEvent ScreenCapture Microphone; do
        tccutil reset "${service}" "${bundle}" >/dev/null 2>&1 || true
    done
done

echo "→ Removing Sayful keychain access tokens and API keys…"
for account in "${KEYCHAIN_ACCOUNTS[@]}"; do
    security delete-generic-password -s "${KEYCHAIN_SERVICE}" -a "${account}" >/dev/null 2>&1 || true
done

echo "→ Removing saved dictations, generated audio, account avatar, and logs…"
rm -rf "${SUPPORT_DIR}/Recordings"
rm -rf "${SUPPORT_DIR}/TTS"
rm -f "${SUPPORT_DIR}/Account/avatar.png"
rm -f "${SUPPORT_DIR}/avatar.png"
rm -rf "${LOG_DIR}"

if [[ "${MODE}" == "fresh" ]]; then
    echo "→ Removing onboarding data while keeping downloaded models/runtimes…"
    rm -rf "${SUPPORT_DIR}/Dictionaries"
fi

if [[ "${MODE}" == "empty" ]]; then
    echo "→ Removing Sayful dictionaries, generated audio, models, and runtimes…"
    rm -rf "${SUPPORT_DIR}/Dictionaries"
    rm -rf "${SUPPORT_DIR}/Models"
    rm -rf "${SUPPORT_DIR}/Runtimes"
    rm -rf "${HF_CACHE_DIR}"

    if command -v ollama >/dev/null 2>&1; then
        echo "→ Removing Sayful's recommended Ollama model if it exists…"
        ollama rm qwen3.5:4b >/dev/null 2>&1 || true
    else
        echo "→ Ollama CLI not found; skipped Ollama model cleanup."
    fi
fi

echo "✓ Onboarding state reset."
echo "  Removed app settings, privacy permissions, saved dictations, keychain tokens/API keys, profile avatar, and logs."
if [[ "${MODE}" == "empty" ]]; then
    echo "  Removed downloaded Sayful models/runtimes and qwen3.5:4b from Ollama when available."
else
    echo "  Kept downloaded models and runtimes in:"
    echo "  ${SUPPORT_DIR}/Models"
    echo "  ${SUPPORT_DIR}/Runtimes"
fi
