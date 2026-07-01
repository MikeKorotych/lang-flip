#!/usr/bin/env bash
#
# tts-bench.sh — reproducible latency benchmark for text-to-speech.
#
# Usage:
#   Scripts/tts-bench.sh [preset] [runs]
#
# Presets:
#   backend      REAL production path: POST /tts to Sayful Cloud (counts quota!)
#   openrouter   direct OpenRouter /audio/speech (needs OPENROUTER_API_KEY)
#
# Env: MODEL, VOICE, SPEED, TEXT, RUNS. Keys auto-load from ~/.sayful-bench.env.

set -euo pipefail

BENCH_ENV="${BENCH_ENV:-$HOME/.sayful-bench.env}"
if [[ -f "$BENCH_ENV" ]]; then set -a; source "$BENCH_ENV"; set +a; fi

PRESET="${1:-backend}"
RUNS="${2:-${RUNS:-5}}"
MODEL="${MODEL:-google/gemini-3.1-flash-tts-preview}"
VOICE="${VOICE:-Kore}"
SPEED="${SPEED:-1.0}"
TEXT="${TEXT:-Привет, это тест функции озвучивания текста. Нужно проверить скорость, качество русской речи и задержку до начала воспроизведения.}"

SUPA="https://bpxsmfdpmbfsvdckndpw.supabase.co"
ANON="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJweHNtZmRwbWJmc3ZkY2tuZHB3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIzMDI5NDAsImV4cCI6MjA5Nzg3ODk0MH0.FzxlUqw7iH0PhmSVrHKOfd6MMhoEL_tyhaSqXf6-VHY"

EXTRA_HEADERS=()
case "$PRESET" in
  backend)
    EP="$SUPA/functions/v1/tts"; SHAPE="backend"
    KEY="${TTS_API_KEY:-$(security find-generic-password -s com.antonpinkevych.lang-flip -a backend-access-token -w 2>/dev/null || true)}"
    EXTRA_HEADERS=(-H "apikey: $ANON") ;;
  openrouter)
    EP="https://openrouter.ai/api/v1/audio/speech"; SHAPE="openai"
    KEY="${TTS_API_KEY:-${OPENROUTER_API_KEY:-$(security find-generic-password -s com.antonpinkevych.lang-flip -a cloud-ai-api-key -w 2>/dev/null || true)}}" ;;
  *) echo "unknown preset: $PRESET" >&2; exit 2 ;;
esac

[[ -z "${KEY:-}" ]] && { echo "✗ no API key for preset '$PRESET'" >&2; exit 1; }

PAYLOAD="$(mktemp)"; BODY="$(mktemp)"
AUTH_CONFIG="$(mktemp)"; chmod 600 "$AUTH_CONFIG"
printf 'header = "Authorization: Bearer %s"\n' "$KEY" > "$AUTH_CONFIG"
trap 'rm -f "$PAYLOAD" "$BODY" "$AUTH_CONFIG"' EXIT

if [[ "$SHAPE" == "backend" ]]; then
  jq -n --arg text "$TEXT" --arg model "$MODEL" --arg voice "$VOICE" --argjson speed "$SPEED" \
    '{text:$text, model:$model, voice:$voice, speed:$speed}' > "$PAYLOAD"
else
  jq -n --arg input "$TEXT" --arg model "$MODEL" --arg voice "$VOICE" --argjson speed "$SPEED" \
    '{input:$input, model:$model, voice:$voice, speed:$speed, response_format:"mp3"}' > "$PAYLOAD"
fi

echo "════════════════════════════════════════════════════════════════"
echo " TTS bench · preset=$PRESET · model=$MODEL · voice=$VOICE · runs=$RUNS"
echo " endpoint=$EP"
echo " chars=${#TEXT} · speed=$SPEED"
echo "════════════════════════════════════════════════════════════════"
printf "\n %-4s %9s %8s %7s %5s %s\n" run total ttfb kb code type
printf " %s\n" "------------------------------------------------------------"

totals=(); ttfbs=()
for i in $(seq 1 "$RUNS"); do
  read -r start total bytes code ctype < <(curl -s -o "$BODY" \
    -w '%{time_starttransfer} %{time_total} %{size_download} %{http_code} %{content_type}\n' \
    --config "$AUTH_CONFIG" \
    -X POST "$EP" \
    -H "Content-Type: application/json" \
    ${EXTRA_HEADERS[@]+"${EXTRA_HEADERS[@]}"} \
    --data @"$PAYLOAD")
  ttfb=$(awk -v t="$start" 'BEGIN{printf "%.0f", t*1000}')
  tot=$(awk -v t="$total" 'BEGIN{printf "%.0f", t*1000}')
  kb=$(awk -v b="$bytes" 'BEGIN{printf "%.0f", b/1024}')
  totals+=("$tot"); ttfbs+=("$ttfb")
  printf " %-4s %7sms %6sms %6s %5s %s\n" "$i" "$tot" "$ttfb" "$kb" "$code" "$ctype"
done

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}'; }
echo
echo " median ttfb  = $(median "${ttfbs[@]}") ms"
echo " median total = $(median "${totals[@]}") ms"
if [[ "$(file -b --mime-type "$BODY" 2>/dev/null || true)" == "application/json" ]]; then
  echo " response = $(jq -r '.error.message // .error // .message // empty' "$BODY" 2>/dev/null | head -c 300)"
fi
