#!/usr/bin/env bash
# Fetch frequency-ordered word lists for Ukrainian and Russian and write
# cleaned versions next to the Swift sources. The output files are committed
# to the repo so end-users don't need network access to build the app.
#
# Sources (both MIT-style permissive licences):
#   - hermitdave/FrequencyWords — top 50k from OpenSubtitles 2018, one word
#     per line followed by frequency count
#
# Cleaning:
#   - lowercase
#   - keep only the word column (drop frequency)
#   - keep only words made of language-specific letters (no digits / punct)
#   - keep words 3 chars or longer
#   - dedupe (preserves frequency ordering of the first occurrence)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$ROOT_DIR/Sources/LangFlip/Dictionaries"

mkdir -p "$OUT_DIR"

UK_URL="https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/uk/uk_50k.txt"
RU_URL="https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt"

echo "→ Fetching Ukrainian word list…"
curl -fsSL "$UK_URL" \
  | awk '{print $1}' \
  | tr '[:upper:]' '[:lower:]' \
  | grep -E '^[абвгґдеєжзиіїйклмнопрстуфхцчшщьюя]{3,}$' \
  | awk '!seen[$0]++' \
  > "$OUT_DIR/uk-words.txt"
UK_COUNT=$(wc -l < "$OUT_DIR/uk-words.txt" | tr -d ' ')
echo "  ✓ uk-words.txt — $UK_COUNT words"

echo "→ Fetching Russian word list…"
curl -fsSL "$RU_URL" \
  | awk '{print $1}' \
  | tr '[:upper:]' '[:lower:]' \
  | grep -E '^[абвгдеёжзийклмнопрстуфхцчшщъыьэюя]{3,}$' \
  | awk '!seen[$0]++' \
  > "$OUT_DIR/ru-words.txt"
RU_COUNT=$(wc -l < "$OUT_DIR/ru-words.txt" | tr -d ' ')
echo "  ✓ ru-words.txt — $RU_COUNT words"

echo
echo "Done. Re-run \`make app\` to bundle the new dictionaries into the .app."
