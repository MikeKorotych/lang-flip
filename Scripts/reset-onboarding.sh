#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${1:-com.antonpinkevych.lang-flip}"
MODE="${2:-settings}"
APP_NAME="${3:-LangFlip}"
SUPPORT_DIR="${HOME}/Library/Application Support/LangFlip"

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

echo "✓ Onboarding state reset."
echo "  Kept downloaded models and runtimes in:"
echo "  ${SUPPORT_DIR}/Models"
echo "  ${SUPPORT_DIR}/Runtimes"
