# TTS Latency Handoff

Date: 2026-06-25

## Current Production Path

Sayful Cloud text-to-speech uses:

App `CloudSpeechSynthesizer` -> Supabase Edge Function `/tts` -> provider.

The backend calls OpenRouter's OpenAI-compatible `/audio/speech` endpoint. The
provider API key stays server-side. The app sends text, voice, speed, optional
instructions, and now the selected model.

## Changes Landed

- `/tts` now parses the JSON request body and resolves auth in parallel.
- `/tts` now runs rate-limit and quota reads in parallel.
- `/tts` returns audio before quota metering; metering runs through
  `EdgeRuntime.waitUntil` when available.
- Backend default TTS model was changed to:

```text
google/gemini-3.1-flash-tts-preview
```

- Backend default voice was changed to:

```text
Kore
```

- The app's cloud TTS defaults and Developer settings were migrated from the
  removed OpenAI model to Gemini/Kore.
- The app now sends `Settings.shared.cloudTTSModel` on backend TTS requests
  instead of letting the backend silently choose.
- Added `Scripts/tts-bench.sh` for repeatable backend/direct TTS latency tests.

## Important Finding

The previous default model is no longer usable on OpenRouter:

```text
openai/gpt-4o-mini-tts-2025-12-15
```

Observed backend result: HTTP 502 from `/tts`, with a provider-side 400. The
OpenRouter model page now reports that this model is unavailable, and the live
speech model catalog no longer includes it.

## Benchmarks

Bench script:

```bash
Scripts/tts-bench.sh backend 5
```

Default Russian test phrase, real backend path:

| Model | Voice | Median total | Median TTFB | Notes |
| --- | --- | ---: | ---: | --- |
| `google/gemini-3.1-flash-tts-preview` | `Kore` | 3237-4269 ms | 3320-4187 ms | Best current RU/UA default candidate; provider spikes observed |
| `x-ai/grok-voice-tts-1.0` | `Eve` | ~3896 ms | ~3890 ms | Expressive candidate, slower/pricier |
| `hexgrad/kokoro-82m` | `af_nova` | ~1316 ms | ~1310 ms | Fastest observed, but not safe RU/UA default |
| `microsoft/mai-voice-2` | `en-US-Harper:MAI-Voice-2` | ~3466 ms | ~3460 ms | English quality candidate |
| `canopylabs/orpheus-3b-0.1-ft` | `tara` | ~16851 ms | ~16845 ms | Too slow for hot path |
| `mistralai/voxtral-mini-tts-2603` | `alloy` | 502 | 502 | Chosen voice/model pair failed |

The practical latency is still around 3.3 seconds for Gemini because the
current path buffers the full audio file before the app can play it. The backend
quick wins remove some server overhead, but they cannot turn full-file TTS into
instant playback.

## Decision

Use `google/gemini-3.1-flash-tts-preview` with voice `Kore` as the Sayful Cloud
default for now. It is the best observed quality/safety default for Russian and
Ukrainian among currently available OpenRouter speech models.

Keep `hexgrad/kokoro-82m` as a speed experiment, not the default. It is much
faster, but quality/language coverage risk is too high for the core user path.

## Next Optimization Options

1. Stream audio instead of buffering the full provider response.
   This is the real next lever for perceived latency. For MP3 providers, the
   backend can likely pipe the provider response body to the app. Gemini returns
   WAV-style audio in current tests, so streaming is trickier because classic
   WAV headers normally need the final byte length.

2. Return content type/file extension from `HTTPBackendClient.tts`.
   The app currently writes backend TTS bytes to a `.wav` file even when the
   provider returns `audio/mpeg`. `afplay` sniffs the content, but correct
   extension/content handling will be cleaner before streaming work.

3. Add a "fast voice" experiment.
   Test Kokoro on English and short phrases where speed matters more than
   multilingual quality. This could become an explicit Developer-mode option.

4. Explore direct provider routes only if a provider offers a meaningfully
   faster RU/UA voice with secure server-side key storage. Do not move provider
   API keys into the app binary.

## Manual Test Checklist

1. Open Preferences -> Developer and confirm the TTS model shows Gemini/Kore,
   not the removed OpenAI model.
2. Read a short Russian selection.
3. Read a short Ukrainian selection.
4. Read a longer mixed-language paragraph.
5. Watch latency logs:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.antonpinkevych.sayful" AND category == "latency"' --info --style compact
```

Expected current shape for Gemini: around 3-4.5 seconds before playback starts,
with provider spikes possible. Repeated results much above 5 seconds on short
text are a regression worth investigating.
