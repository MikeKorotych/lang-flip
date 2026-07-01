# WS1 — Backend Proxy + Google Sign-In (Bake-off Spec)

> **Status:** approved direction, not started. Author hand-off doc — an executing
> agent should be able to build the whole thing from this file.
> **Decision date:** 2026-06-24.
> **Scope owner:** LangFlip internal relaunch (see `docs/INTERNAL-RELAUNCH-PLAN.md`).

---

## 0. TL;DR

Build the corporate AI backend **"properly"** — a server that holds the provider
key, authenticates users with Google, splits them into buckets by email domain,
enforces quotas, and **proxies** all STT / LLM / TTS / OCR calls to OpenRouter
server-side. The macOS app never holds a provider key; it only holds a session token.

We implement the backend **twice, in two branches, against one shared API
contract**, then compare and keep the winner:

- `backend/supabase` — Supabase Auth (Google) + Postgres + Edge Functions.
- `backend/railway` — custom server (Node+Fastify **or** Python+FastAPI) + Postgres on Railway.

The macOS app's AI-layer refactor is **shared** (written once); only how it
acquires a bearer token differs between branches.

---

## 1. Why (rationale)

- A key baked into a distributed `.app` is trivially extractable (`strings`,
  Hopper, network capture, memory). Acceptable only for a throwaway,
  budget-capped internal demo — **not** for real distribution.
- The secure design is a **thin backend proxy**: the OpenRouter key lives only in
  server env; the app authenticates and the server makes provider calls,
  enforcing per-user quotas. This simultaneously solves (a) user separation and
  (b) key security.
- With a backend, a separate "corporate build" / `AppEdition` compile flag is
  largely unnecessary: everyone downloads the same app and the backend decides
  the bucket by domain. The open-source / **BYOK** path stays for self-hosters.

## 2. Non-goals / hard constraints

- **No provider key in the app bundle.** Ever. Not even obfuscated.
- **No secrets in git.** Backend secrets live in the platform's env/secret store.
  This doc and any backend live in a **separate private repo** or a gitignored
  area — never the public MIT app repo.
- **BYOK preserved.** The existing "OpenAI / compatible cloud (BYOK)" mode must
  keep working for open-source users who bring their own key (direct to provider,
  not through our backend).
- **No interim baked-key demo** (explicit user decision): the pitch waits for the
  real backend.

## 3. Assumptions (confirmed 2026-06-24)

| Param | Value |
|---|---|
| Corporate email domain | `uni.tech` (config: `CORPORATE_DOMAIN`) |
| Free-tier quota | 1000 words / week (config: `FREE_WEEKLY_WORDS`) |
| Corporate quota | effectively unlimited; soft abuse cap e.g. 100k words/week (`CORP_WEEKLY_WORDS`) |
| Provider | OpenRouter (OpenAI-compatible) — key only on server |
| Default STT model | `Qwen3 ASR Flash` (best Cyrillic/UK/RU in field use); curated list below |
| Default text model | `deepseek/deepseek-v4-flash` (cheap proofreading) |
| Paid tier | later, via RevenueCat **Web Billing** (direct-distribution app, not Mac App Store) |

---

## 4. Architecture

```
 macOS app                         Backend (one of two impls)            OpenRouter
 ─────────                         ───────────────────────────           ──────────
 Google sign-in  ───────────────►  verify identity, upsert user
                 ◄───────────────  session bearer token (JWT)
 bearer + audio  ──/v1/transcribe►  authZ → quota check → meter ──────►  STT  ──┐
 bearer + text   ──/v1/chat──────►  authZ → quota check → meter ──────►  LLM    │ key
 bearer + text   ──/v1/tts───────►  authZ → quota check → meter ──────►  TTS    │ ONLY
 bearer + image  ──/v1/ocr───────►  authZ → quota check → meter ──────►  VLM  ──┘ here
                 ◄───────────────  result (+ updated quota headers)
```

- **AuthN:** Google OAuth 2.0 (PKCE) from the native app.
- **AuthZ + buckets:** backend maps verified email domain → role.
- **Metering:** backend counts feature usage as weighted quota units and
  decrements the user's weekly quota server-side.
- **Secrets:** `OPENROUTER_API_KEY` in server env only.

---

## 5. Shared API contract (BOTH branches implement identically)

Base URL differs per branch/env (`API_BASE_URL`). All `/v1/*` require
`Authorization: Bearer <token>`. JSON unless noted. All errors:
`{ "error": { "code": string, "message": string, "details"?: any } }`.

### 5.1 Auth

> **Note on the bake-off:** Supabase Auth issues its **own** session JWT via the
> Supabase SDK, so on the Supabase branch `/auth/google` may be handled by
> Supabase directly and the app uses `supabase-swift`. On the Railway branch we
> implement `/auth/google` ourselves. The app abstracts this behind a
> `BackendAuth` protocol → "give me a valid bearer token". The `/v1/*` calls are
> **identical** (bearer auth) on both.

- `POST /auth/google`
  - Body: `{ "idToken": string }` (Google ID token from the native OAuth flow)
  - Server: verify signature against Google JWKS; check `iss ∈ {accounts.google.com, https://accounts.google.com}`, `aud == GOOGLE_CLIENT_ID`, `exp`; require `email_verified == true`. Derive `domain` from `email` (or `hd` claim). Upsert user; assign `role = (domain == CORPORATE_DOMAIN) ? "corporate" : "free"`.
  - 200: `{ "accessToken", "refreshToken", "expiresIn", "user": { "id","email","role","quota": { "used","limit","resetAt" } } }`
  - 401: invalid/expired Google token.
- `POST /auth/refresh` — Body `{ "refreshToken" }` → 200 (new access token); 401 if invalid/revoked.
- `GET /me` → 200 `{ "user": { "id","email","role","quota": {...} } }`
- `POST /auth/signout` (optional): revoke refresh token. 204.

### 5.2 Proxy endpoints

All return `429 { error.code: "quota_exceeded", details: { resetAt } }` when quota
exhausted. All include headers `X-Quota-Used`, `X-Quota-Limit`, `X-Quota-Reset`.
Quota headers use weighted quota units, not raw words.

- `POST /v1/transcribe` — **multipart/form-data**: `audio` (m4a/wav/mp3), `language?`, `model?` → 200 `{ "text", "words" }`. Meters by returned word count.
- `POST /v1/chat` — `{ "system","input","temperature?","maxTokens?","model?" }` → 200 `{ "text","words" }`. Meters by output words.
- `POST /v1/tts` — `{ "text","voice?","model?","speed?","instructions?" }` → 200 `audio/*` bytes; header `X-Words`. Meters by input words.
- `POST /v1/ocr` — `{ "imageBase64","model?" }` → 200 `{ "text","words" }`. Meters by returned words.

### 5.3 Metering rule (precise)

- **Word** = maximal run of non-whitespace (`text.split(/\s+/).filter(Boolean).length`), counted on output text (transcribe/ocr/chat) or input text (tts).
- **Quota unit** = raw word count × feature weight, rounded up.
- Default weights:
  - `transcribe`: `STT_WORD_WEIGHT=1`
  - `chat`: `CHAT_WORD_WEIGHT=1`
  - `ocr`: `OCR_BASE_UNITS=20` plus extracted words × `OCR_WORD_WEIGHT=1`
  - `tts`: `TTS_WORD_WEIGHT=14`
- OCR has a small base charge because image input has a fixed provider cost
  even when the screenshot contains very little text.
- TTS reserves its weighted quota before the provider call and refunds it if
  the provider fails, because generated speech is materially more expensive.
- Output-metered features (transcribe/ocr/chat) decrement **after** a successful
  provider call. Usage increments must be atomic in Postgres; never overwrite a
  stale `used + words` client/server snapshot.
- Quota window = **calendar week, UTC Monday** (`period_start`). `resetAt` = next Monday 00:00 UTC.
- `limit` = `FREE_WEEKLY_WORDS` (free) or `CORP_WEEKLY_WORDS` (corporate), interpreted as weighted quota units.

### 5.4 Limits / validation

- Max audio 25 MB (`MAX_AUDIO_BYTES`), image 8 MB, text 20k chars.
- Unauthenticated `/v1/*` → `401 { code: "unauthenticated" }`.
- Per-user rate limit (~60 req/min) → `429 { code: "rate_limited" }` (distinct from `quota_exceeded`).
- HTTPS only.

---

## 6. Data model (Postgres — both branches)

```sql
create table app_user (
  id            uuid primary key default gen_random_uuid(),
  google_sub    text unique not null,
  email         text not null,
  domain        text not null,
  role          text not null check (role in ('corporate','free')),
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz
);

create table usage_week (
  user_id       uuid not null references app_user(id) on delete cascade,
  period_start  date not null,            -- UTC Monday
  words_used    integer not null default 0,
  primary key (user_id, period_start)
);

create table usage_event (              -- optional audit; NO content stored
  id            bigserial primary key,
  user_id       uuid not null references app_user(id) on delete cascade,
  kind          text not null,            -- transcribe|chat|tts|ocr
  words         integer not null,
  model         text,
  created_at    timestamptz not null default now()
);
create index on usage_event (user_id, created_at);
```

- **Privacy:** never persist transcript / prompt / audio. Store only counts + model id.
- Refresh tokens: hashed `refresh_token` table (Railway) or Supabase Auth's built-in sessions (Supabase).

---

## 7. Auth flow (macOS → Google → backend)

1. User taps "Sign in with Google" (onboarding gate or Settings).
2. App generates PKCE `code_verifier` + `code_challenge`.
3. `ASWebAuthenticationSession` → Google authorize URL (`client_id`, loopback `redirect_uri=http://127.0.0.1:<port>`, `response_type=code`, `scope=openid email profile`, `code_challenge`, `S256`). Public/native client, no secret.
4. Google redirects to loopback with `?code=…`.
5. App exchanges `code`+`code_verifier` at `https://oauth2.googleapis.com/token` → `id_token`.
6. App `POST /auth/google { idToken }` → backend verifies, upserts, returns our access/refresh tokens.
7. Tokens → **Keychain** (reuse `KeychainStore`, e.g. accounts `backend-access-token`, `backend-refresh-token`).
8. On `/v1/*` 401 → `/auth/refresh`; if that fails → sign in again.

> **Supabase shortcut:** `supabase-swift` `signInWithOAuth(.google)` returns a
> Supabase session directly (steps 5–6 collapse); role assigned server-side via
> trigger/function on user insert.

---

## 8. Branch A — `backend/supabase`

- **Auth:** Supabase Auth, Google provider (Google client id/secret in dashboard); app uses `supabase-swift`.
- **Role:** Postgres trigger on `auth.users` insert/update → upsert `app_user` with role from domain (or Edge Function `assign-role`); optional custom claim.
- **Proxy:** one Edge Function per endpoint under `supabase/functions/`. Each: validate Supabase JWT → load `app_user` → check `usage_week` → call OpenRouter (`Deno.env.get("OPENROUTER_API_KEY")`) → increment usage + insert `usage_event` → return + quota headers.
- **Secrets:** `supabase secrets set OPENROUTER_API_KEY=… CORPORATE_DOMAIN=uni.tech …`.
- **DB:** migrations in `supabase/migrations/`; RLS: users read only their own rows; functions write via service role.
- **Deploy:** `supabase link` + `supabase functions deploy`.

## 9. Branch B — `backend/railway`

- **Stack:** Node 20 + Fastify + TypeScript (recommended) **or** Python 3.12 + FastAPI.
- **Auth:** implement `/auth/google` — verify Google ID token (`google-auth-library` / `google.oauth2.id_token`); issue own JWT (`jsonwebtoken` / `pyjwt`), short expiry + hashed rotating refresh token.
- **Proxy:** `/v1/*` handlers; middleware `requireAuth → loadUser → checkQuota → callOpenRouter → meter`.
- **DB:** Railway Postgres; migrations via Prisma/Drizzle (Node) or Alembic (Py).
- **Deploy:** Railway service from branch; env in dashboard; `/healthz`.
- **Structure (Node):**
  ```
  backend/railway/
    src/{server.ts, auth/, routes/{transcribe,chat,tts,ocr}.ts, lib/{openrouter,quota,jwt,google}.ts, db/}
    prisma/schema.prisma
    package.json  Dockerfile  railway.json
  ```

---

## 10. macOS app changes (SHARED — written once)

Files: `AI/AIAssistantManager.swift`, `AI/OpenAIAssistant.swift`,
`CloudTranscriber.swift`, `CloudSpeechSynthesizer.swift`, `Settings.swift`,
`KeychainStore.swift`, onboarding, Settings UI.

1. **`BackendClient`** (new): wraps `API_BASE_URL` + bearer; `transcribe/chat/tts/ocr`; auto-refresh on 401; surfaces quota headers.
2. **`BackendAuth`** (new): protocol with two impls — `SupabaseAuth` (supabase-swift) and `CustomAuth` (`/auth/google` + PKCE via `ASWebAuthenticationSession`). Both expose `currentBearerToken()/signIn()/signOut()`. Lets us A/B both backends behind one interface.
3. **AI mode:** add `.backend` to the cloud path. Signed in → route transcribe/chat/tts/ocr through `BackendClient`. **BYOK stays** (direct-to-provider) when chosen.
4. **Onboarding:** sign-in step after permissions; "Use my own key (advanced)" → BYOK.
5. **Settings:** account section (email, role, "X words left this week"; sign out / switch). Hide provider/key/model fields in `.backend` mode (also closes the deferred WS4 "Advanced" hiding).
6. **Keychain:** store backend access/refresh tokens; never a provider key in `.backend` mode.
7. **Quota UX:** `429 quota_exceeded` → "weekly limit reached" (+ later upgrade CTA); network/5xx → "service unavailable," NOT "set API key."

---

## 11. Comparison rubric (decide the winner) — score 1–5

| Criterion | How to measure |
|---|---|
| Dev effort / LOC | lines + hours to first end-to-end call |
| Time-to-first-call | empty project → working `/v1/chat` |
| Auth ergonomics | code to get Google login + JWT working |
| Audio handling | multipart upload + optional streaming |
| Latency / cold starts | p50/p95 on `/v1/chat`, `/v1/transcribe` |
| Cost | monthly at ~300 users |
| Ops / maintenance | deploys, logs, migrations |
| Vendor lock-in | effort to migrate off |
| App integration | cleanliness of the Swift client |

Keep the winner; archive the other branch.

---

## 12. Security requirements

- `OPENROUTER_API_KEY` only in server env; never logged or returned.
- Validate Google token fully (sig, iss, aud, exp, email_verified).
- Short access JWT (≤1h) + rotating refresh (hashed at rest).
- HTTPS/HSTS; per-user rate limiting; input size caps (§5.4).
- Never persist user content (transcripts/prompts/audio) — counts+model only.
- CORS locked to actual needs.
- Rotate the demo OpenRouter key (it was pasted into chat) + hard budget cap before real traffic.

---

## 13. Prerequisites / setup checklist (BEFORE building)

- [ ] **Google Cloud project** + **OAuth 2.0 client** (iOS/Desktop, loopback redirect). Capture `GOOGLE_CLIENT_ID`; configure consent screen.
- [ ] **Supabase project** (branch A): URL + anon + service-role keys; enable Google auth provider.
- [ ] **Railway project** (branch B): Postgres plugin + service; CLI/deploy token.
- [ ] **OpenRouter** key as a server secret in each platform; **budget cap set**; key **rotated**.
- [ ] Repo home: **separate private repo** for the backend (recommended), NOT the public MIT app repo.
- [ ] Env matrix: `GOOGLE_CLIENT_ID`, `OPENROUTER_API_KEY`, `CORPORATE_DOMAIN`, `FREE_WEEKLY_WORDS`, `CORP_WEEKLY_WORDS`, `DEFAULT_STT_MODEL`, `DEFAULT_TEXT_MODEL`, `JWT_SECRET` (Railway), `MAX_AUDIO_BYTES`.

> **Blocker (2026-06-24):** Supabase/Railway MCP integrations were disconnected in
> this environment; provisioning needs them reconnected or CLI access + the
> credentials above.

---

## 14. Execution order (milestones, each independently verifiable)

- **M0 — Contract freeze.** This doc is the contract (stub OpenAPI if helpful).
- **M1 — Branch A skeleton (Supabase):** project + migrations + `/v1/chat` Edge Function calling OpenRouter via secret. *Verify:* authed `curl` to `/v1/chat` returns cleaned text; quota decrements.
- **M2 — Branch B skeleton (Railway):** server + DB + `/auth/google` + `/v1/chat`. *Verify:* same `curl` passes.
- **M3 — Full endpoints, both:** add `/transcribe`, `/tts`, `/ocr`, `/me`, `/auth/refresh`, quota + rate limit + validation. *Verify:* shared test script passes.
- **M4 — macOS shared client:** `BackendClient` + `BackendAuth` (both impls) + Google login + Keychain tokens; route AI through backend; keep BYOK. *Verify:* `@uni.tech` and non-corp Google accounts both work end-to-end on each branch; free account hits the 1000-word wall + limit UI.
- **M5 — Onboarding + account UI + quota UX.** Hide provider/key/model in backend mode (closes WS4 Advanced hiding).
- **M6 — Bake-off comparison:** fill §11 with real numbers; pick winner; archive loser; write decision note.
- **M7 (later) — Billing:** RevenueCat Web Billing for free→paid upgrade.

### Shared test script (sketch)

```
# expects $TOKEN (bearer) and $BASE
curl -sf -X POST $BASE/v1/chat -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"system":"Fix grammar. Output only the corrected text.","input":"i dont knows why this works"}'
curl -sf -X POST $BASE/v1/transcribe -H "Authorization: Bearer $TOKEN" \
  -F audio=@sample.m4a -F language=uk
curl -sf $BASE/me -H "Authorization: Bearer $TOKEN"
```

---

## 15. Curated model defaults (server config, overridable per request)

- **STT:** default `Qwen3 ASR Flash` (best Cyrillic/UK/RU). Curated to test: NVIDIA Parakeet TDT 0.6B v3, Mistral Voxtral Mini Transcribe, OpenAI GPT-4o Transcribe, Google Chirp 3.
- **Text:** default `deepseek/deepseek-v4-flash`.
- **TTS:** default `openai/gpt-4o-mini-tts` via OpenRouter; voice `nova`.
- **OCR/vision:** default `google/gemini-3.1-flash-lite`.
- In `.backend` mode the client never needs to know model ids.

---

## 16. Open questions / decisions still needed

1. Node+Fastify vs Python+FastAPI for Railway (recommend Node+TS).
2. Refresh strategy on Railway: rotating hashed refresh (recommended) vs long JWT.
3. Streaming `/v1/chat` and `/v1/tts` now, or buffer first? (Buffer first.)
4. Separate private backend repo name/owner.
5. Calendar-week (this doc) vs rolling-7-day quota window.
6. Corporate soft-cap value + spend alerting.
