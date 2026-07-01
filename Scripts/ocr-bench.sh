#!/usr/bin/env bash
#
# ocr-bench.sh — reproducible latency benchmark for screenshot OCR.
#
# Generates one deterministic PNG fixture (or uses IMAGE=...), sends it through
# the same `/ocr` backend route the app uses, and reports total wall time. Use
# MODEL to compare vision models without changing app settings.
#
# Usage:
#   Scripts/ocr-bench.sh [preset] [runs]
#
# Presets:
#   backend      REAL production path: POST /ocr to Sayful Cloud (counts quota!)
#   groq         direct Groq vision chat/completions (needs GROQ_API_KEY)
#   openrouter   direct OpenRouter vision chat/completions (needs OPENROUTER_API_KEY)
#
# Env: MODEL, IMAGE, RUNS. Keys auto-load from ~/.sayful-bench.env.

set -euo pipefail

BENCH_ENV="${BENCH_ENV:-$HOME/.sayful-bench.env}"
if [[ -f "$BENCH_ENV" ]]; then set -a; source "$BENCH_ENV"; set +a; fi

PRESET="${1:-backend}"
RUNS="${2:-${RUNS:-5}}"
MODEL="${MODEL:-google/gemini-3.1-flash-lite}"
IMAGE="${IMAGE:-/tmp/sayful-ocr-fixture.png}"

SUPA="https://bpxsmfdpmbfsvdckndpw.supabase.co"
ANON="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJweHNtZmRwbWJmc3ZkY2tuZHB3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIzMDI5NDAsImV4cCI6MjA5Nzg3ODk0MH0.FzxlUqw7iH0PhmSVrHKOfd6MMhoEL_tyhaSqXf6-VHY"

if [[ ! -f "$IMAGE" ]]; then
  GEN_SWIFT="$(mktemp /tmp/sayful-ocr-fixture.XXXXXX.swift)"
  trap 'rm -f "$GEN_SWIFT"' EXIT
  cat > "$GEN_SWIFT" <<'SWIFT'
import AppKit

let out = CommandLine.arguments[1]
let size = NSSize(width: 980, height: 360)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .semibold),
    .foregroundColor: NSColor.black,
]
let bodyAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .regular),
    .foregroundColor: NSColor.black,
]

"SCAN THIS TEXT".draw(in: NSRect(x: 40, y: 270, width: 900, height: 50), withAttributes: titleAttrs)
"Русский текст: исправь пунктуацию и сохрани смысл.".draw(in: NSRect(x: 40, y: 205, width: 900, height: 44), withAttributes: bodyAttrs)
"Український текст: швидкість, стабільність, якість.".draw(in: NSRect(x: 40, y: 150, width: 900, height: 44), withAttributes: bodyAttrs)
"1. apples  2. сметана  3. чипсы".draw(in: NSRect(x: 40, y: 95, width: 900, height: 44), withAttributes: bodyAttrs)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
SWIFT
  /usr/bin/swift "$GEN_SWIFT" "$IMAGE"
fi

case "$PRESET" in
  backend)
    EP="$SUPA/functions/v1/ocr"; SHAPE="backend"
    KEY="${OCR_API_KEY:-$(security find-generic-password -s com.antonpinkevych.lang-flip -a backend-access-token -w 2>/dev/null || true)}"
    EXTRA_HEADERS=(-H "apikey: $ANON") ;;
  groq)
    EP="https://api.groq.com/openai/v1/chat/completions"; SHAPE="groq"
    MODEL="${MODEL:-meta-llama/llama-4-scout-17b-16e-instruct}"
    KEY="${OCR_API_KEY:-${GROQ_API_KEY:-}}" ;;
  openrouter)
    EP="https://openrouter.ai/api/v1/chat/completions"; SHAPE="openrouter"
    KEY="${OCR_API_KEY:-${OPENROUTER_API_KEY:-$(security find-generic-password -s com.antonpinkevych.lang-flip -a cloud-ai-api-key -w 2>/dev/null || true)}}" ;;
  *) echo "unknown preset: $PRESET" >&2; exit 2 ;;
esac

[[ -z "${KEY:-}" ]] && { echo "✗ no API key for preset '$PRESET'" >&2; exit 1; }

B64="$(base64 -i "$IMAGE" | tr -d '\n')"
BYTES="$(stat -f%z "$IMAGE")"
PAYLOAD="$(mktemp)"; BODY="$(mktemp)"
AUTH_CONFIG="$(mktemp)"; chmod 600 "$AUTH_CONFIG"
printf 'header = "Authorization: Bearer %s"\n' "$KEY" > "$AUTH_CONFIG"
trap 'rm -f "$PAYLOAD" "$BODY" "$AUTH_CONFIG" ${GEN_SWIFT:-}' EXIT

if [[ "$SHAPE" == "backend" ]]; then
  jq -n --arg img "$B64" --arg model "$MODEL" '{imageBase64:$img, model:$model}' > "$PAYLOAD"
elif [[ "$SHAPE" == "openrouter" ]]; then
  jq -n --arg img "data:image/png;base64,$B64" --arg model "$MODEL" '{
    model:$model,
    temperature:0,
    provider:{sort:"latency"},
    reasoning:{exclude:true},
    messages:[{
      role:"user",
      content:[
        {type:"text", text:"Extract all text from this image exactly as it appears. Output only the text, no commentary."},
        {type:"image_url", image_url:{url:$img}}
      ]
    }]
  }' > "$PAYLOAD"
else
  jq -n --arg img "data:image/png;base64,$B64" --arg model "$MODEL" '{
    model:$model,
    temperature:0,
    messages:[{
      role:"user",
      content:[
        {type:"text", text:"Extract all text from this image exactly as it appears. Output only the text, no commentary."},
        {type:"image_url", image_url:{url:$img}}
      ]
    }]
  } + (if ($model | test("^qwen/")) then {reasoning_format:"hidden"} else {} end)' > "$PAYLOAD"
fi

echo "════════════════════════════════════════════════════════════════"
echo " OCR bench · preset=$PRESET · model=$MODEL · runs=$RUNS"
echo " endpoint=$EP"
echo " fixture=$IMAGE · ${BYTES}B"
echo "════════════════════════════════════════════════════════════════"
printf "\n %-4s %9s %5s\n" run total code
printf " %s\n" "------------------------------"

ts=()
for i in $(seq 1 "$RUNS"); do
  read -r total code < <(curl -s -o "$BODY" -w '%{time_total} %{http_code}\n' \
    --config "$AUTH_CONFIG" \
    -X POST "$EP" \
    -H "Content-Type: application/json" \
    ${EXTRA_HEADERS[@]+"${EXTRA_HEADERS[@]}"} \
    --data @"$PAYLOAD")
  tot=$(awk -v t="$total" 'BEGIN{printf "%.0f", t*1000}'); ts+=("$tot")
  printf " %-4s %7sms %5s\n" "$i" "$tot" "$code"
done

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}'; }
echo
echo " median total = $(median "${ts[@]}") ms"
out=$(jq -r '.text // .choices[0].message.content // .error.message // .error // empty' "$BODY" 2>/dev/null | head -c 500)
echo " output = $out"
