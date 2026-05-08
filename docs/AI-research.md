# AI on-device research — LangFlip 2026

Living document. Captures what's possible on macOS today, which models fit our
constraints, and how to integrate optional AI smarts without bloating the
default install.

---

## What we'd actually use AI for

Five concrete use-cases, ranked by ROI:

### 1. Smarter "should we flip this?" decision
Replace dictionary lookup with a small LM that gets context: surrounding 5–8
words plus the candidate. "Did the user mean this in language X, given the
sentence so far?" Captures the meaning of the wider context, handles names,
slang, code, jargon, mixed-language text without us curating an exception list.

Today: `руддщ` flips because dict says "hello" exists in EN. Doesn't know if
the user is in a Russian-language conversation or an English one. AI sees
context, decides.

### 2. Typo correction beyond layout flips
Once we own a small LM, we can catch typos that aren't layout-related:
`teh → the`, `recieve → receive`, `преввет → привіт`, `сегодня` written as
`седгодня`, etc. Today macOS auto-correct does some of this in apps that opt
in (Cocoa text views, Notes, Mail) — many editors, browsers, and chat clients
don't. We could fill the gap.

### 3. Word-level layout pair suggestions
For words like `что`/`що`, `подъезд`/`під'їзд` that exist as different
spellings in two languages — auto-suggest the version matching the surrounding
context. Today's rule-based code handles letter-position substitution but not
genuinely-different spellings.

### 4. Per-app behaviour learning
Watch which words the user tends to backspace-undo per app. Over time the
model can predict "you don't want auto-flip in this kind of context" without
the user adding the app to a blacklist. Less explicit, more magical.

### 5. Sentence-level rewrites in selection mode
Already shipped: select text + `⇧⇧` to flip its layout. With an LM we could
also: select sloppy text + `⇧⇧⌘L` (or similar) → "fix the typos and
formatting". Adjacent feature, not core, but fits the surface area.

---

## What "on-device" actually means on macOS today

Two viable paths:

### Apple's Foundation Models (built-in, free)
Apple ships **Foundation Models framework** in macOS 26 (Tahoe, our build
target). It exposes a system-managed on-device LM — single shared model,
loaded by the OS, accessible via `Foundation Models` Swift API. Notable:

- **Free** — no model files we ship, no extra disk
- **Privacy-first** — Apple guarantees local execution, no telemetry
- **Single model**, currently general-purpose. We can't pick a different
  one. We can guide it with system prompts.
- **Fast first call** because the model is already memory-resident
  (shared with other apps that use it).
- Requires macOS 26+ (we're on 13+). Would need a `#available(macOS 26, *)`
  fallback for old systems.

This is likely the **right default** for our use-case.

### Bundle-our-own (Core ML / MLX / GGUF runner)
For users on macOS 13–15 (no Foundation Models), or for power users who want
to pick a specific model, we'd run our own. Three runtime options:

| Runtime | Pros | Cons |
|---|---|---|
| **Core ML** (Apple) | First-party, GPU-accelerated, well-supported | Requires Core ML format conversion. Mostly classic ML; LLM support arrived 2024+ |
| **MLX** (Apple, open source) | Designed for Apple Silicon LLMs, growing model zoo, swift bindings | Pre-1.0, churn between releases |
| **llama.cpp** family (GGUF) | Best model selection, mature, runs every quantized model out there | C++ embed, Swift wrapper effort |

For a menu-bar utility, **MLX** is the sweet spot: native Apple Silicon perf,
reasonable bindings via [`mlx-swift-examples`](https://github.com/ml-explore/mlx-swift-examples),
respectable model selection.

---

## Models that could plausibly fit

Constraints: should run with ≤ 4 GB VRAM at int4/int8 quantization, finish a
single inference in < 200 ms on M-series, and either be multilingual or
specifically Slavic-language-aware.

### Tier 1 — actually small enough for a keyboard tool
| Model | Size (q4) | Multilingual? | Notes |
|---|---|---|---|
| **Apple Foundation Models** | ~3 GB | Yes (incl. UK + RU) | Free, Apple-managed, macOS 26+ |
| **Gemma 3 1B** (Google, open) | ~700 MB | Yes (140+ langs) | Released 2025, very fast on M-series |
| **Phi-3.5 Mini 3.8B** | ~2.2 GB | Yes | Microsoft, strong reasoning at small size |
| **Qwen 2.5 1.5B** (Alibaba) | ~1 GB | Yes (Russian, Ukrainian both well-covered) | Open weights, good multilingual perf |
| **Llama 3.2 1B / 3B** | 0.7 / 2.2 GB | English-first, OK Slavic | Most popular, biggest community |

### Tier 2 — if we ever need bigger
| Model | Size (q4) | Notes |
|---|---|---|
| **Gemma 3 4B** | ~2.5 GB | Step up if 1B is too dumb on edge cases |
| **Phi-3.5 14B** | ~9 GB | Way too big as a default but optional power-user mode |

### My pick for the optional-bundle path
**Qwen 2.5 1.5B int4** — best balance of size (~1 GB), Slavic-language
quality, and inference speed. Runs comfortably on the lowest-spec Apple
Silicon Mac.

---

## Distribution: small default, model on-demand

Goal: don't bloat the .dmg. Three layers:

### Layer 0: zero AI (today's behaviour)
The default app remains rules + dictionaries (~3 MB + Sparkle). Auto-flip
works without any model.

### Layer 1: Foundation Models (free, system-provided)
On macOS 26+, opt-in switch in Preferences > Behavior > "Use Apple
Intelligence for smarter detection". No download, no extra disk, just
flips a code path. Falls back to rules on older OSes.

### Layer 2: optional model download (for macOS 13–25 users + power users)
Preferences > Models pane. List of supported model bundles fetched on
demand:

```
   Model            Size     Status            Action
   ──────────────   ──────   ─────────────────  ─────────
   Qwen 2.5 1.5B    1.0 GB   Not downloaded     [Download]
   Gemma 3 1B       0.7 GB   Active             [Active]
   Phi-3.5 Mini     2.2 GB   Not downloaded     [Download]
```

- Models live in `~/Library/Application Support/LangFlip/Models/`
- Download from a CDN (GitHub Releases works for ≤ 2 GB; CloudFlare R2 free
  tier handles bigger).
- Verify SHA-256 + Sparkle-style EdDSA signature so the binary we run
  matches what Apple notarized.
- "Active" model selectable from the same pane. One model loaded at a time.

---

## What changes in the code

### Architecture sketch
```
                ┌──────────────────────────────────┐
                │       AutoFlip.suggestedFlip     │
                │   (rules-based, today's logic)   │
                └────────────────┬─────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │ Settings.aiAssist?      │
                    │  - off    → return rules result
                    │  - apple  → FoundationModelsAssistant
                    │  - bundle → MLXAssistant("Qwen-2.5-1.5B")
                    └─────────────────────────┘
                                 │
                                 ▼
                       Combined verdict
                       (cross-checked against rules)
```

The AI runs as a **second opinion**, not a replacement: only flip when
both the dict heuristic and the LM agree. Either alone can veto. This
preserves precision while raising recall.

### New files
```
Sources/LangFlip/AI/
  AIAssistant.swift            — protocol: shouldFlip(text, context) -> Decision?
  FoundationModelsAssistant.swift — wraps macOS 26 Foundation Models API
  MLXAssistant.swift           — wraps MLX runtime, lazy-load model
  ModelCatalog.swift           — list of downloadable models, hashes, URLs
  ModelDownloader.swift        — fetch + verify + install, async progress
```

### Settings additions
```
lf.aiMode             "off" | "apple" | "bundle:qwen-2.5-1.5b"
lf.activeModelID      String  (which downloaded model to load)
```

### Preferences UI
- New "Models" tab — only visible when AI is enabled.
- Manage downloads, switch active model, see disk usage.

---

## Technical risks / open questions

1. **First-token latency**. A 1.5B model on M1 Air takes ~50 ms warm. Cold
   start (model load from disk) is 2–4 s. Strategy: lazy-load on first
   typing event after launch, keep resident afterwards.

2. **Memory pressure**. 1 GB resident is fine for power Macs but heavy on
   8 GB MacBook Air. Need a "release model when idle for N minutes"
   policy. MLX makes this manageable.

3. **Foundation Models availability**. macOS 26 is recent — adoption will
   be uneven through 2026. Both code paths (rules-only and AI-on-Apple)
   need to coexist transparently for at least 2 years.

4. **Fine-tuning vs. prompting**. Out-of-the-box LMs are biased toward
   English. For Ukrainian/Russian-specific corrections we may need a
   small LoRA — adds another asset to ship and a training pipeline. Avoid
   in v1; revisit if base model accuracy on UK/RU is insufficient.

5. **Privacy story**. Selling point: "everything on-device, no telemetry,
   no cloud". Make sure download URLs don't leak more than version + UA.
   Consider mirroring models on our own infra to control privacy posture.

6. **Apple-store notarization for optional download**. The downloaded
   model files are data, not executables — should pass notarization
   without issue. The MLX *runtime* is library code we link statically
   into the app, signed at release time as part of LangFlip.

---

## Single-Shift grammar check — design notes

This is the headline AI feature. Single clean Shift tap (no other key
during press, no second tap within 350 ms) triggers an AI grammar /
typo pass on the last sentence and silently applies the fix.

### UX rules
- **No overlay for grammar fixes.** The flip overlay is for layout
  changes — the user wants visual confirmation the layout flipped.
  Grammar fixes are silent: they just happen, the user sees the
  diff in the text where they were already typing. An overlay would
  be noisy because grammar fixes can fire often.
- **No sound either** by default. Same rationale.
- **Default OFF** for the toggle. Single Shift is too low-friction
  to ship enabled — would surprise users.

### Speculative inference (latency hiding)
Naive flow:
```
Shift up → wait 350 ms → AI call (~200 ms) → apply
                                                ▲
                                          550 ms felt
```

Better flow — kick off the AI call as soon as Shift goes up; the
first 350 ms of the window are spent waiting for either a second
tap OR the inference result, whichever comes first:
```
Shift up + start AI ──┐
                      │ ── 350 ms tap window ──┐
                      │                        │
              AI returns (~200 ms)             │
                                               │
                      [no second tap]          ▼
                                          ~350 ms felt
```

If a second tap arrives within the window, we **cancel the
in-flight inference** (or let it complete and discard the result —
cheaper than retrying a second time later). Trade-off: a small
amount of wasted compute on every double-tap. With ~200 ms model
inference on M-series, the waste is negligible.

### "Last sentence" definition
Operate on the most recent sentence in the focused app's text:
- Walk back from the cursor through the WordBuffer (or, in
  selection-mode, the selected text).
- A sentence ends at `.`, `!`, `?`, newline, or the start of the
  buffer — whichever comes first.
- Cap at ~50 words. Beyond that we'd risk a slow / large AI call
  for diminishing benefit.

### Failure modes
- AI unreachable (download failed, model not yet warm) → silently
  skip, don't show any error. Grammar correction is best-effort.
- AI returns identical text → don't rewrite, don't show overlay.
- AI returns drastically different text (length differs by >2x or
  the diff covers >50% of the words) → reject, suspect bad output.
- Apple's Foundation Model unavailable on this OS → fall back to
  bundled MLX model if installed; otherwise toggle is hidden.

## Roadmap proposal

If we go for it, my suggested phases:

**Phase A — non-AI infrastructure (1 week)**
- Models tab in Preferences (placeholder UI).
- ModelDownloader with progress + SHA-256 verification.
- AIAssistant protocol + a no-op implementation.

**Phase B — Apple Foundation Models (2–3 days)**
- Wire FoundationModelsAssistant for macOS 26+.
- Settings toggle "Use Apple Intelligence".
- Two-vote agreement (rules + AI) for auto-flip.
- Ship as v0.5.

**Phase C — bundle MLX runtime + Qwen 2.5 1.5B (1–2 weeks)**
- Embed MLX, write MLXAssistant.
- Curate one model (Qwen 1.5B) on the catalog.
- Test inference latency, tune memory policy.
- Ship as v0.6.

**Phase D — model picker (1 week)**
- Expand catalog: Gemma 3 1B, Phi-3.5 Mini, etc.
- Sparkle-style signed downloads.
- Switch-active-model UI in Preferences > Models.
- Ship as v0.7.

**Phase E — typo correction beyond layout (TBD)**
- Standalone "AI proofreader" feature, sister to layout flip.
- Trigger via separate hotkey (e.g., quadruple-Shift) or on demand.

Total honest estimate: **6–8 weeks of focused work**. AI is the biggest
single feature we'd add and arguably the biggest accuracy jump.

---

## Open recommendations

If we want to ship "AI" *somehow* in the next month:
- Phase B alone (Foundation Models) is achievable, valuable, and free for users on macOS 26.
- Phases C–D are bigger but cleanly optional.
- Phase E is its own product surface; defer.

Suggest tackling **Phase B first** — biggest perceived bang for time, reuses
infrastructure already in place (Sparkle for updates, Preferences scaffolding
for the toggle, EventTap pipeline for the new "AI vote" hook).
