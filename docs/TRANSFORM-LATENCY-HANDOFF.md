# Transform Latency Handoff

Date: 2026-06-25

## Current Production Path

Sayful Cloud text transforms use:

App `BackendAssistant` -> Supabase Edge Function `/chat` -> provider.

The backend default text model is expected to be:

```text
groq/llama-3.3-70b-versatile
```

The `groq/` prefix is routed directly to Groq by the backend. Other models route
through OpenRouter.

## Changes Landed

- `/chat` now parses request body and resolves auth in parallel.
- `/chat` now runs rate-limit and quota reads in parallel.
- `/chat` returns the model response before quota metering; metering runs via
  `EdgeRuntime.waitUntil` when available.
- Backend OpenRouter chat now mirrors the app's BYOK OpenRouter options:
  `provider.sort = latency` and `reasoning.exclude = true`.
- App backend text calls now send operation-specific `temperature` and
  `maxTokens`:
  - rewrite sentence: `temperature=0`, dynamic cap `256`
  - fix selection: `temperature=0`, dynamic cap `512`
  - translate: `temperature=0.2`, cap `1024`
  - transform / Prompt Engineer: `temperature=0.3`, cap `2048`
  - dictation auto-format: `temperature=0`, dynamic cap `2048`
- Text correction / polish prompt is now stricter about preserving the author's
  wording and voice. It prioritizes punctuation, capitalization, paragraphing,
  list formatting, and quotes, while only changing words when the intended fix is
  strongly implied by context. It explicitly preserves slang/loanwords such as
  `полишинг`, `полішинг`, `апдейт`, `фича`, `фіча`, `баг`, `реліз`, and
  `дедлайн`.
- After a failed manual test, the prompt was tightened further for the primary
  value proposition: fast typo cleanup with minimal edits. Regression case:
  `давай я проерю как этр работакт на самом деле` must become a minimal
  correction like `Давай, я проверю, как это работает на самом деле.`, not an
  inferred rewrite such as `...этот рабочий процесс...`.

## Benchmarks

Bench script:

```bash
Scripts/chat-bench.sh backend 10
```

Short English proofread, real backend path:

| Model | Median | Quality Notes |
| --- | ---: | --- |
| backend default (`groq/llama-3.3-70b-versatile`) | 463-520 ms | Good |
| `groq/llama-3.1-8b-instant` | 431 ms | Faster, but failed Ukrainian meaning in tests |
| `groq/openai/gpt-oss-20b` | 497 ms | Empty output in observed backend parse |
| `groq/openai/gpt-oss-120b` | 680 ms | Empty output in observed backend parse |
| `google/gemini-3.1-flash-lite` | ~1000 ms | Good, slower |
| `deepseek/deepseek-v4-flash` | 2400-2600 ms | Slow / empty in some observed outputs |
| `qwen/qwen3.6-flash` | 6000-6800 ms | Too slow for hot path |
| `openai/gpt-5-nano` | ~4600 ms | Too slow / empty in observed backend parse |
| `openai/gpt-5-mini` | ~4700 ms | Too slow / empty in observed backend parse |

Ukrainian proofread:

| Model | Median | Result |
| --- | ---: | --- |
| `groq/llama-3.3-70b-versatile` | ~625 ms | Good: preserves meaning, fixes punctuation/apostrophe |
| `groq/llama-3.1-8b-instant` | ~514 ms | Bad: changed meaning |
| `google/gemini-3.1-flash-lite` | ~1035 ms | Good, slower |
| `deepseek/deepseek-v4-flash` | ~2726 ms | Empty output in observed backend parse |

Prompt Engineer / longer output:

| Path | Median |
| --- | ---: |
| backend default | ~745-819 ms |
| direct Groq 70B | ~480 ms |
| direct Groq gpt-oss-120b | ~1405 ms |

## Decision

Keep `groq/llama-3.3-70b-versatile` as the Sayful Cloud default for Transform,
Single-Shift fix, translation, and dictation auto-format. It is the best current
speed/quality tradeoff for English, Ukrainian, and Russian in observed tests.

Do not use `llama-3.1-8b-instant` as default despite speed; it changed meaning
in Ukrainian text. Do not use current OpenRouter Qwen/DeepSeek/OpenAI options
for the hot path; observed latency is too high.

## Prompt / Model Quality Pass

Additional quality pass on 2026-06-25 covered 12 RU/UA/EN/mixed cases:

- typo-heavy short polish,
- already-correct text,
- slang-heavy Russian and Ukrainian,
- explicit lists,
- mixed English/Russian product terms,
- quoted speech,
- a deliberately wrong-word sentence,
- longer paragraph with `во-первых / во-вторых / в-третьих`.

Compared models on the production backend path:

| Model | Quality summary | Latency shape |
| --- | --- | --- |
| `groq/llama-3.3-70b-versatile` | Best speed/voice balance after prompt tightening; preserves slang and product terms well. Needed explicit prompt rules for capitalization, `Сегодня я`, loanwords, and direct-speech quotes. | Usually ~470-800 ms |
| `groq/meta-llama/llama-4-scout-17b-16e-instruct` | Stronger with quotes/lists in some cases, but more likely to stylize or formalize (`юзеры` -> `пользователи`) and add expressive punctuation. | ~400-1700 ms depending output |
| `groq/openai/gpt-oss-120b` | Careful RU/UA correction, but more editorial and uses typographic punctuation/spacing that can feel less like the user's raw voice. | ~680-1300 ms |
| `google/gemini-3.1-flash-lite` | Very good list formatting and multilingual correction, but slower and sometimes normalizes slang (`короче` -> `Коротше`). | ~800-2000 ms |

Decision after this pass: keep Llama 70B as default and improve prompt first.
Llama 4 Scout remains an A/B candidate, but not a clear default for text polish.

Critical prompt rule: text-fix mode is a typo-correction engine first. It must
not add new concepts, rewrite for style, or expand one misspelled word into a
phrase. Formatting and structure improvements are secondary and should happen
only when the user's text makes them obvious.

## Suggested Next Manual Tests

1. Single-Shift selected-text fix on a short Ukrainian typo sentence.
2. Single-Shift selected-text fix on a short Russian typo sentence.
3. Both-Shift Prompt Engineer on a messy 1-2 paragraph instruction.
4. Custom Transform via Option+digit, if one is configured.

Watch latency logs:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.antonpinkevych.sayful" AND category == "latency"' --info --style compact
```

Expected hot-path logs are `AI wall=~450-800ms` for short/medium transforms,
with occasional provider spikes possible.
