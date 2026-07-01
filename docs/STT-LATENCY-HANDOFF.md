# STT Latency Optimization — Handoff

Self-contained handoff for continuing speech-to-text (STT / dictation) latency
work on Sayful (formerly LangFlip). Written so another agent can act cold.

## 1. Product & repos

- **Sayful** — macOS menu-bar dictation app (a Wispr Flow alternative, free internal company tool).
  Swift, `swift build` / `make run`. Repo: `/Users/antonpinkevych/Desktop/Code/lang-flip`.
- **Backend** — Supabase Edge Functions (Deno/TypeScript) proxying AI providers, enforcing
  per-Google-account weekly quota. Repo: `/Users/antonpinkevych/Desktop/Code/langflip-backend`.
  Project ref `bpxsmfdpmbfsvdckndpw`. Deploy: `supabase functions deploy <name>` (CLI is linked +
  logged in; Docker NOT required — it bundles remotely).

The user dictates mostly in **Ukrainian / Russian** — accuracy on Cyrillic matters.

## 2. The task

Make dictation (STT) faster. Hard constraint added mid-way: **server-side quota must still be
counted** (the product meters weekly words per account) — so we cannot simply bypass the backend.

## 3. Pipeline (how dictation works today)

App records 16 kHz mono Int16 WAV → on stop, POSTs multipart `audio` to the backend
`POST /functions/v1/transcribe` (Sayful Cloud mode, the default; needs a Supabase session bearer).
Backend authenticates, checks quota, calls the STT provider, meters word count, returns `{text,words}`.
App pastes the text.

- BYOK/Advanced mode exists too (`CloudTranscriber.swift`, base64-JSON to OpenRouter) but is NOT
  the user's path.
- The model the backend uses is set by `DEFAULT_STT_MODEL` env. The app no
  longer sends arbitrary Developer-tab `Settings.shared.cloudSTTModel` values in
  Sayful Cloud mode; it sends no model for Fast, or the fixed Quality enum model.
  The backend must still enforce its own model allowlist.

## 4. What was achieved

**Median /transcribe latency: ~1350 ms → ~784 ms (−42%), quota fully preserved.**

Journey (measured on one fixed 8.4 s clip, see §7):
| step | median total |
|------|--------------|
| Qwen3 ASR Flash via OpenRouter (original default) | ~1350 ms |
| Groq `whisper-large-v3` via backend, naive | 1171 ms |
| + quick-wins (parallel pre-flight, deferred metering) | ~875 ms |
| + raw-fetch DB layer + local JWT verify (embedded key) | **784 ms** |

### Changes — backend (`langflip-backend`, commit `9fae527`)
File `supabase/functions/_shared/backend.ts` + `transcribe/index.ts` + `.env.example`:
- **Groq-direct routing**: `providerTranscribe` sends models prefixed `groq/` straight to
  `api.groq.com` (multipart) instead of OpenRouter. New env `GROQ_API_KEY` (already set as a Supabase
  secret). Groq Whisper is ~2–3× faster than the same model via OpenRouter.
- **Default model** = `groq/whisper-large-v3` (set via `supabase secrets set DEFAULT_STT_MODEL=…`).
  Chosen over `whisper-large-v3-turbo` because turbo misheard Ukrainian "Привіт"→"Привід" in A/B;
  large-v3 was accurate on UK & RU and still ~780 ms.
- **Parallelized pre-flight**: `req.formData()` + `checkRateLimit` + `loadQuota` run via `Promise.all`
  after `resolveUser` (were 3 serial awaits before the Groq call).
- **Deferred metering**: respond immediately after Groq; write quota via `EdgeRuntime.waitUntil`
  off the critical path. Pre-call `assertQuota` still rejects over-quota requests (at most one extra
  slips per window — acceptable).
- **Dropped `@supabase/supabase-js`** → raw-fetch PostgREST layer (`pg()` + service-role headers).
- **Local JWT verification** with **jose + an embedded ES256 public key** (kid
  `b60fef8e-a8e4-43b5-be39-0e96485abe2d`); remote JWKS is only a rotation fallback. This was the key
  win: isolates are always cold (see §6), so a remote JWKS would be re-fetched every request and
  negate local verify. Result: `ms_getuser` dropped from ~100 ms → ~2 ms.
- Shared helper signatures unchanged (`db` param now vestigial) → `chat/ocr/tts/me` untouched.

### Changes — app (`lang-flip`, commits `b7c4873`, `a98d2a1`)
- `Sources/LangFlip/NetworkLatency.swift` (new): `os.Logger` category `latency` — per-request
  DNS/TCP/TLS/TTFB/download + `reused` + protocol + wall-clock. `ConnectionWarmer` (warms the STT TLS
  connection at record-start). Wired into STT/TTS/transform call sites.
- `VoiceDictationController.swift`: `prewarmSTTConnection()` on record start.
- `PreferencesView.swift`: Developer-tab STT picker gains `groq/whisper-large-v3-turbo` and
  `groq/whisper-large-v3` (the `groq/` prefix triggers backend Groq routing).
- `Scripts/stt-bench.sh`: the benchmark harness (see §7).

## 5. The remaining problem — the ~250 ms "client↔edge" leg

Server-side timing (we instrumented the edge function with `performance.now()` and returned it in an
`X-Stt-Timing` response header; that instrumentation has since been removed). A typical ~710 ms request:

| component | ~ms | notes |
|-----------|-----|-------|
| `ms_stt` (edge→Groq + Groq transcription) | 300–380 | the model; largely irreducible |
| **client↔edge network** (`total − ms_server`) | **~250** | TLS/upload/transit + cold isolate boot |
| `ms_appuser` (app_user upsert) | 45–130 (spikes 360) | a DB write every request |
| `ms_pre` (parallel rate+quota+formData) | ~40 | already parallelized |
| `ms_getuser` (local JWT verify) | ~2 | fixed (embedded key) |

The ~250 ms client↔edge leg is the proxy's inherent cost: the user uploads ~267 KB to the edge,
the edge re-uploads to Groq, and responses transit back — a double hop. Dropping `supabase-js` did
NOT shrink it, which means it's mostly **network + the audio upload**, not module cold-boot.

### Options to reduce it further (none done yet — diminishing returns)

1. **App-direct to Groq + async metering** (biggest win → ~650 ms; the ONLY path meaningfully below
   ~780 ms). The app calls Groq directly (removes the edge double-hop), then fire-and-forgets a word
   count to a cheap backend `/meter` endpoint off the critical path. Tradeoffs:
   - Groq key must reach the app. Do NOT embed in the binary (extractable) — **vend it from the
     backend at sign-in** (e.g. add it to `/me` or a `/stt-credentials` endpoint) so only authed
     users get it. Acceptable for an internal tool.
   - Metering becomes **client-reported = trust-based**. Fine for trusted employees; weak for
     adversarial users. Quota *enforcement* would be soft (app already receives quota headers; it can
     refuse to dictate when over).
   - This is the recommended path IF the user wants <780 ms.

2. **Compress the upload** (~50–100 ms, helps both legs). Encode the WAV to Opus (~15–30 KB vs
   267 KB) or FLAC before upload. App-side encode (AVAudioConverter / AudioToolbox) + Groq must accept
   the format (it accepts many). Smaller payload shrinks both user→edge and edge→Groq uploads.

3. **`app_user` upsert** (~70 ms, spikes to 360). It writes `last_seen_at` every request and returns
   the id needed by quota. Could defer the write (waitUntil) but the id is needed synchronously, or
   key `usage_week` on `auth_uid` (from the JWT) instead of `app_user.id` to skip the lookup entirely
   — a schema migration.

4. **Accept ~784 ms.** Competitive (Wispr Flow ~1–2 s). The user chose to push to a full refactor; we
   landed at 784 ms and stopped before the app-direct rewrite.

## 6. Key findings / gotchas

- **Edge isolates are ALWAYS cold** (`cold:true` on every request, even 6 sequential). So "warm the
  edge function during recording" does NOT help — a real request hits a fresh isolate. This killed an
  early hypothesis. It also means anything cached per-isolate (remote JWKS) is re-fetched every call.
- **The backend hop roughly doubles Groq's standalone latency**: direct Groq large-v3 ≈ 651 ms client
  total; via backend ≈ 780–900 ms.
- **CLI `supabase functions logs` does not exist in v2.84** — return diagnostics in a response header
  instead, or use the Dashboard.
- **Backend session token (JWT) expires ~1 h.** The benchmark reads it from Keychain; it goes stale
  and returns `401 UNAUTHORIZED_ASYMMETRIC_JWT` (a *gateway*-level error, before the function runs).
  Do NOT refresh it from a script — Supabase rotates refresh tokens and would sign the app out. The
  fix is: open the app (it refreshes), then re-run.

## 7. How to measure (reproducible)

`Scripts/stt-bench.sh` feeds ONE deterministic `say`-generated fixture through an endpoint N times,
reports per-request + median timing. Key is auto-loaded from `~/.sayful-bench.env` (gitignored,
contains `GROQ_API_KEY=…`).

```bash
cd /Users/antonpinkevych/Desktop/Code/lang-flip
# Groq direct (isolates the model+network, no backend, no quota):
./Scripts/stt-bench.sh groq 5
STT_MODEL=whisper-large-v3 ./Scripts/stt-bench.sh groq 5
# Backend path (real production path; needs a FRESH token — open the app first):
STT_MODEL=groq/whisper-large-v3 ./Scripts/stt-bench.sh backend 5
# Cyrillic fixtures for accuracy: VOICE=Lesya (uk) / Milena (ru), FIXTURE=/tmp/uk.wav etc.
```
Fixtures live in `/tmp/sayful-stt-fixture.wav` (EN), `/tmp/uk.wav`, `/tmp/ru.wav`.
The app's own latency is observable via: `log stream --predicate 'category == "latency"' --info`.

## 8. Status — verified vs not

- ✅ Committed (backend `9fae527`, app `a98d2a1` + earlier `b7c4873`). **Not pushed.**
- ✅ Deployed to Supabase. Default model = `groq/whisper-large-v3`.
- ✅ Verified at HTTP 200 with correct transcript + incrementing quota — on the pre-cleanup build
  (the cleanup only removed diagnostic timing, no logic change).
- 🔴 **NOT YET verified: the final cleaned deploy at 200** — blocked by an expired token. Needs the
  user to do one live dictation (refreshes the token + confirms the full path end-to-end and that the
  new default routes to Groq). If broken, roll back:
  `supabase secrets set DEFAULT_STT_MODEL=qwen/qwen3-asr-flash-2026-02-10`.

## 9. Next (project priorities after STT)

Same method (instrument `category==latency` + benchmark, find the lever from data):
2. Transforms / text polishing  3. OCR from screenshot  4. TTS (cost + speed).

## 10. 2026-06-25 Qwen ASR re-check

User noticed Qwen3 ASR Flash gives more polished punctuation/list formatting
than Groq Whisper. Re-tested on real user dictations through the same
backend-reserved path.

| Audio | Current default (`groq/whisper-large-v3`) | Qwen via OpenRouter |
| --- | ---: | ---: |
| 14.8 s WAV | 783 ms | 1626 ms |
| 32.5 s FLAC | 977 ms | 1649 ms |
| 76.0 s FLAC | 1251 ms | 3295 ms |

Quality notes:
- Qwen output is often more editorially polished: more punctuation, list-like
  punctuation, `90+`, `100+`, `Первое - ...`.
- Groq preserves the spoken wording more literally and is materially faster.
- OpenRouter's Qwen page says this model has only one provider behind it, so
  OpenRouter cannot route to a faster alternative provider for this exact model.

Likely next experiment if Qwen quality is important:
- Add a backend-only DashScope/Alibaba direct route, e.g. `dashscope/qwen3-asr-flash`.
- Keep the API key server-side.
- Benchmark US Virginia and Singapore Model Studio regions.
- Qwen docs say Qwen3-ASR-Flash accepts local file upload up to 5 minutes and
  supports streaming output; that may remove OpenRouter overhead and improve
  perceived latency, but it needs a `DASHSCOPE_API_KEY` to test.

## 11. 2026-06-25 DashScope direct test

Tested a user-provided Alibaba Model Studio Singapore workspace:

```text
compatible endpoint: https://ws-...ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1
model: qwen3-asr-flash
input: base64 data URI via OpenAI-compatible chat/completions
```

Results from local Mac -> Alibaba Singapore:

| Audio | DashScope direct | Notes |
| --- | ---: | --- |
| 6.7 s WAV | 2281-2703 ms | Misread `2-5` as `две пять`; `language=ru` did not help |
| 14.8 s WAV | 3658-4291 ms | Good punctuation, slower than OpenRouter Qwen |
| 32.5 s FLAC | 3505-3889 ms | More polished text, but misrecognized `speech-to-text` wording |
| 76.0 s FLAC | 7289-7959 ms | Best punctuation/list style, far too slow for hot path |

Streaming test on 14.8 s WAV:

```text
TTFB: 4526 ms
total: 4776 ms
```

Streaming does not improve perceived latency enough for the current dictation
UX because first useful output arrives near completion.

Decision: do **not** move production STT to DashScope Singapore direct. Keep
`groq/whisper-large-v3` as default and treat Qwen as a quality/reference model.
