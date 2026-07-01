# OCR Latency Handoff

Date: 2026-06-25

## Current Path

App `BackendAssistant.extractTextFromImage` -> Supabase Edge Function `/ocr` -> OpenRouter vision chat completion.

The user-visible capture UI (`/usr/sbin/screencapture -i`) is interactive and outside the model critical path. Optimize the path after the PNG exists: upload, backend auth/quota, provider routing, model latency.

## Changes Made

- `/ocr` now parses request JSON and resolves auth in parallel.
- `/ocr` now runs rate-limit and quota reads in parallel.
- `/ocr` returns the OCR response before quota metering; metering runs via `EdgeRuntime.waitUntil`.
- OpenRouter OCR requests now set `provider.sort = "latency"` and `reasoning.exclude = true`.
- Backend OCR now routes models prefixed with `groq/` directly to Groq. The Groq API key stays server-side; the app only sends the model id.
- Groq Qwen OCR uses `reasoning_format = "hidden"` server-side, so `<think>` output does not leak into OCR text.
- Security follow-up: Sayful Cloud OCR no longer sends arbitrary
  `Settings.shared.cloudOCRModel` values from the app. The Developer
  vision-model picker remains for BYOK/direct-provider mode; backend OCR should
  choose from server-side allowed defaults.
- Added `Scripts/ocr-bench.sh` for reproducible backend/OpenRouter OCR latency checks.
- Updated the Developer OCR test copy so it no longer says Ollama-only.

## Bench Fixture

`Scripts/ocr-bench.sh` generates `/tmp/sayful-ocr-fixture.png`:

- 980x360 PNG, about 340 KB
- English + Russian + Ukrainian + numbered list text
- Same input across models/runs

## Production Backend Results

Backend route, same fixture, successful output in all cases.

| Model | Runs | Median |
| --- | ---: | ---: |
| `google/gemini-3.1-flash-lite` before `/ocr` optimization | 1 | 3735 ms |
| `google/gemini-3.1-flash-lite` after `/ocr` optimization | 5 | 1802 ms |
| `google/gemma-4-26b-a4b-it` | 3 | 1838 ms |
| `perceptron/perceptron-mk1` | 3 | 3874 ms |
| `qwen/qwen3.6-flash` | 3 | 7195 ms |
| `qwen/qwen3.5-plus-20260420` | 3 | 10028 ms |
| `groq/meta-llama/llama-4-scout-17b-16e-instruct` | 10 | 970 ms |
| `groq/qwen/qwen3.6-27b` | 10 | 1096 ms |

Direct Groq checks before backend routing:

| Model | Runs | Median | Notes |
| --- | ---: | ---: | --- |
| `meta-llama/llama-4-scout-17b-16e-instruct` | 5 | 924 ms | Clean OCR output |
| `qwen/qwen3.6-27b` | 5 | 769 ms | Needs `reasoning_format = "hidden"` to avoid `<think>` text |

## Decision

Use `groq/meta-llama/llama-4-scout-17b-16e-instruct` as the default OCR model:

- Fastest production backend route in the current fixture.
- Strong quality on mixed English/Russian/Ukrainian fixture.
- Clean output without reasoning handling.

Keep `groq/qwen/qwen3.6-27b` as the main A/B candidate. It is excellent direct via Groq, but slightly slower than Llama Scout through the production backend in the warm benchmark. Keep `google/gemini-3.1-flash-lite` as the stable OpenRouter fallback.

## Next Checks

1. Run a real screenshot-region test from the app and inspect `category == "latency"` logs for `OCR wall`.
2. If real selected regions are very large, test app-side downscale/PNG recompression before upload.
3. Later: profile the core LangFlip Cyrillic layout-switch path separately from OCR/STT/Transform.
