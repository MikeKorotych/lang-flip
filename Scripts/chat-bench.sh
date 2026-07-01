#!/usr/bin/env bash
#
# chat-bench.sh — reproducible latency benchmark for the text-transform path
# (polish / fix / rewrite / prompt-engineer), the same `/chat` backend route the
# app uses. Fixed system+input → differences between runs/models are the model
# and network, not the prompt.
#
# Chat is non-streaming, so `total` ≈ generation time (the response arrives only
# when the model finishes). Output length dominates — benchmark a SHORT (polish)
# and a LONG (prompt-engineer) case separately via SYSTEM/INPUT/MAXTOKENS.
#
# Usage:  Scripts/chat-bench.sh [preset] [runs]
# Presets:
#   backend      REAL path: POST /chat to Sayful Cloud (model override allowed). counts quota.
#   groq         direct api.groq.com /chat/completions (needs GROQ_API_KEY)              (default)
#   openrouter   direct openrouter.ai /chat/completions (needs OPENROUTER_API_KEY)
#   custom       STT_… style: CHAT_BASE_URL / CHAT_API_KEY
# Env: MODEL, SYSTEM, INPUT, MAXTOKENS, RUNS. Keys auto-load from ~/.sayful-bench.env.

set -euo pipefail

BENCH_ENV="${BENCH_ENV:-$HOME/.sayful-bench.env}"
if [[ -f "$BENCH_ENV" ]]; then set -a; source "$BENCH_ENV"; set +a; fi

PRESET="${1:-groq}"
RUNS="${2:-${RUNS:-5}}"
MAXTOKENS="${MAXTOKENS:-512}"
SYSTEM="${SYSTEM:-You edit user text. Fix only typos, grammar, punctuation, and capitalization. Preserve meaning, tone, names, code, URLs, and line breaks. Output ONLY the corrected text — no quotes, no explanation.}"
INPUT="${INPUT:-so basically i was thinking we could maybe ship the the new feature on friday but im not sure if the backend is ready yet we should probably check with the team first}"

SUPA="https://bpxsmfdpmbfsvdckndpw.supabase.co"
ANON="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJweHNtZmRwbWJmc3ZkY2tuZHB3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIzMDI5NDAsImV4cCI6MjA5Nzg3ODk0MH0.FzxlUqw7iH0PhmSVrHKOfd6MMhoEL_tyhaSqXf6-VHY"

EXTRA_HEADERS=()
case "$PRESET" in
  backend)
    EP="$SUPA/functions/v1/chat"; SHAPE="backend"
    MODEL="${MODEL:-}"  # empty → backend DEFAULT_TEXT_MODEL
    KEY="${CHAT_API_KEY:-$(security find-generic-password -s com.antonpinkevych.lang-flip -a backend-access-token -w 2>/dev/null || true)}"
    EXTRA_HEADERS=(-H "apikey: $ANON") ;;
  groq)
    EP="https://api.groq.com/openai/v1/chat/completions"; SHAPE="openai"
    MODEL="${MODEL:-llama-3.3-70b-versatile}"; KEY="${CHAT_API_KEY:-${GROQ_API_KEY:-}}" ;;
  openrouter)
    EP="https://openrouter.ai/api/v1/chat/completions"; SHAPE="openai"
    MODEL="${MODEL:-deepseek/deepseek-v4-flash}"; KEY="${CHAT_API_KEY:-${OPENROUTER_API_KEY:-}}" ;;
  custom)
    EP="${CHAT_BASE_URL:?set CHAT_BASE_URL}/chat/completions"; SHAPE="openai"
    MODEL="${MODEL:?set MODEL}"; KEY="${CHAT_API_KEY:?set CHAT_API_KEY}" ;;
  *) echo "unknown preset: $PRESET" >&2; exit 2 ;;
esac
[[ -z "${KEY:-}" ]] && { echo "✗ no API key for preset '$PRESET'" >&2; exit 1; }

# Build the request body for this shape (JSON-escape system/input via a heredoc + jq).
PAYLOAD="$(mktemp)"; BODY="$(mktemp)"
AUTH_CONFIG="$(mktemp)"; chmod 600 "$AUTH_CONFIG"
printf 'header = "Authorization: Bearer %s"\n' "$KEY" > "$AUTH_CONFIG"
trap 'rm -f "$PAYLOAD" "$BODY" "$AUTH_CONFIG"' EXIT
if [[ "$SHAPE" == "backend" ]]; then
  jq -n --arg s "$SYSTEM" --arg i "$INPUT" --arg m "$MODEL" --argjson mt "$MAXTOKENS" \
    '{system:$s, input:$i, maxTokens:$mt} + (if $m=="" then {} else {model:$m} end)' > "$PAYLOAD"
else
  jq -n --arg s "$SYSTEM" --arg i "$INPUT" --arg m "$MODEL" --argjson mt "$MAXTOKENS" \
    '{model:$m, temperature:0, max_tokens:$mt, messages:[{role:"system",content:$s},{role:"user",content:$i}]}' > "$PAYLOAD"
fi

echo "════════════════════════════════════════════════════════════════"
echo " chat bench · preset=$PRESET · model=${MODEL:-<backend default>} · runs=$RUNS · maxTokens=$MAXTOKENS"
echo " endpoint=$EP"
echo "════════════════════════════════════════════════════════════════"
printf "\n %-4s %9s %5s\n" run total code
printf " %s\n" "------------------------------"

ts=()
for i in $(seq 1 "$RUNS"); do
  read -r total code < <(curl -s -o "$BODY" -w '%{time_total} %{http_code}\n' \
    --config "$AUTH_CONFIG" -X POST "$EP" -H "Content-Type: application/json" \
    ${EXTRA_HEADERS[@]+"${EXTRA_HEADERS[@]}"} --data @"$PAYLOAD")
  tot=$(awk -v t="$total" 'BEGIN{printf "%.0f", t*1000}'); ts+=("$tot")
  printf " %-4s %7sms %5s\n" "$i" "$tot" "$code"
done

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}'; }
echo
echo " median total = $(median "${ts[@]}") ms"
# Show the produced text (backend → .text ; openai shape → .choices[0].message.content).
out=$(jq -r '.text // .choices[0].message.content // .error // empty' "$BODY" 2>/dev/null | head -c 300)
echo " output = $out"
