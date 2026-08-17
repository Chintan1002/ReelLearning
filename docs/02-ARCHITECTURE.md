# godmode — Architecture

**Version:** 0.1 (draft)
**Date:** 2026-08-16
**Companion to:** `01-PRD.md`

---

## 1. Architectural principles

1. **One ingest door.** Every capture channel normalises to **one `sources` row plus one
   queued job**, through a single internal `normalise_and_enqueue()` function. Most
   channels reach it via `POST /ingest`; the Instagram webhook and the backfill importer
   have their own endpoints (channel-specific parsing and timing) but call the same
   function. Adding a channel must never change the pipeline behind it.
2. **Everything is a job.** Capture only writes a row and enqueues work. No capture path
   blocks on an LLM call, so a slow model can never lose a reel.
3. **Keep the grey area small and local.** Exactly one component does anything Instagram
   doesn't officially sanction, and it runs on Chintan's own machine.
4. **Size for one user.** ~100 sources, a few per week. Reject any component that only
   earns its keep at scale — no Kafka, no Redis, no Celery, no Kubernetes.
5. **The knowledge store is the product.** The plugin is a *render* of it. It must be
   possible to throw away and regenerate the plugin at any time with zero loss.

---

## 2. System overview

```
 CAPTURE                          CLOUD (always on)                    LOCAL (M4)
┌──────────────────┐
│ IG Share →       │  webhook    ┌──────────────────────────┐
│ @godmode.brain   │───────────► │  Ingest API (FastAPI)    │──┐ INLINE download
└──────────────────┘             │  • verify HMAC           │  │ of IG DM CDN URL
┌──────────────────┐  HTTPS      │  • normalise → source    │  │ (expires — cannot
│ iOS Shortcut     │───────────► │  • enqueue job           │  │  be queued)
└──────────────────┘             └───────────┬──────────────┘  │
┌──────────────────┐  HTTPS                  │                 │
│ Chrome extension │───────────►             ▼                 │
└──────────────────┘             ┌──────────────────────────┐  │
┌──────────────────┐  MCP        │  Job queue (Postgres)    │  │
│ /capture cmd     │───────────► │  SELECT … FOR UPDATE     │  │
│ (in Claude Code) │             │  SKIP LOCKED             │  │
└──────────────────┘             └───────────┬──────────────┘  │
┌──────────────────┐                         │                 │
│ Data export ZIP  │──upload───►             │                 │
│ (saved_posts)    │                         │                 │
└──────────────────┘                         │                 │
                                             │  ┌──────────────┼──────────────────────┐
                                             │  │ fetch_media  │ jobs (permalinks)    │
                                             │  │              │      ┌──────────────┐│
                                             │  └──── poll ───────────│ Local fetch  ││
                                             │                 │      │ worker       ││
                                             │     ┌─── upload ───────│ yt-dlp+cookie││
                                             │     │           │      │ launchd      ││
                                             ▼     ▼           │      └──────────────┘│
                                  ┌──────────────────────────┐ │                      │
                                  │  Object storage (R2)     │◄┘                      │
                                  │  video / images          │◄───────────────────────┘
                                  └───────────┬──────────────┘
                                              ▼
                                  ┌──────────────────────────┐
                                  │  EXTRACTION              │
                                  │  multimodal LLM → raw    │
                                  └───────────┬──────────────┘
                                              ▼
                                  ┌──────────────────────────┐
                                  │  SYNTHESIS → claims      │
                                  └───────────┬──────────────┘
                                              ▼
                                  ┌──────────────────────────┐
                                  │  DEDUP & MERGE           │
                                  │  pgvector ANN + LLM judge│
                                  └───────────┬──────────────┘
                                              ▼
                                  ┌──────────────────────────┐
                                  │  KNOWLEDGE STORE         │◄──── review UI (Next.js)
                                  │  canonical entries       │
                                  └───────────┬──────────────┘
                                              ▼
                                  ┌──────────────────────────┐         ┌──────────────┐
                                  │  PLUGIN GENERATOR        │────────►│ git repo     │
                                  │  → skills/ + commands/   │  push   │ godmode-     │
                                  └──────────────────────────┘         │ plugin       │
                                              ▲                        └──────┬───────┘
                                              │ HTTPS                         │ /plugin
                                              │                               │  update
                                              │            ┌──────────────────▼───────┐
                                              └────────────│ MCP server (stdio)       │
                                                           │ runs LOCALLY in Claude   │
                                                           │ Code, ships in plugin    │
                                                           └──────────────────────────┘
```

---

## 3. Capture layer

### 3.0 The ingest seam — every origin funnels into one function

**Architectural rule, not a build convenience.** All capture clients converge on a single
internal ingest function; each client is a thin adapter that normalises its input and calls
it.

```
IG DM webhook   ─┐   (parses Meta payload, downloads inline)
iOS Shortcut    ─┤
Chrome extension─┼──►  POST /ingest  ──►  sources row + fetch_media job  ──►  pipeline
MCP capture tool─┤        (the seam)
Manual CLI      ─┘
```

**Three consequences worth stating:**

1. **The webhook is not a special path.** It is one adapter among five. Pipeline logic must
   never assume a source arrived from Instagram.
2. **The build decouples from Meta.** The Meta app reaching Live mode has unbounded external
   latency; the manual CLI adapter lets the entire pipeline be built and tested before it
   clears. Meta then becomes an adapter added to a working system, rather than the pipeline
   and the webhook being debugged simultaneously.
3. **The CLI adapter is permanent**, not scaffolding. It stays the debugging entry point and
   the way to replay a source after an extraction-prompt improvement.

---

### 3.1 Instagram DM webhook

Two endpoints:

- `GET /webhooks/instagram` — Meta's subscription handshake. Echo `hub.challenge` when
  `hub.verify_token` matches.
- `POST /webhooks/instagram` — message events.

> **Prerequisite:** the Meta app must be in **Live** mode. Instagram does not deliver
> webhook notifications to apps in Development mode, regardless of tester roles. Live mode
> may require business verification. App Review is separate and is *not* required here —
> Standard Access covers messaging with accounts that have a role on the app.

**Security:** verify the `X-Hub-Signature-256` header (HMAC-SHA256 of the raw body with
the Meta app secret) before parsing. Reject on mismatch. This is the only publicly
reachable unauthenticated endpoint in the system, so it is the one to get right.

**Handler contract — must complete fast:**

1. Verify signature.
2. Extract `entry[].messaging[].message.attachments[]` and **route by type**:

   | Attachment type | Handling |
   |---|---|
   | `ig_reel`, `reel` | Verified path. `url` + `title` + `reel_video_id` → download inline |
   | `image` | Single image or (possibly) a shared feed post → download inline |
   | `video` | Treat as reel |
   | `fallback` | **May carry no payload.** If a permalink is present, store it and enqueue `fetch_media` for the local worker. If not, DM back asking for a link |
   | `template`, `audio`, `file` | Accept, mark `not_relevant`, do not fail |

   > **Unresolved (spike required).** Meta documents no attachment type for a shared feed
   > post or multi-image **carousel**, and warns that *"for unsupported shares… a fallback
   > with no payload might be sent."* Since carousels/infographics are part of the real
   > content mix, resolve this empirically before building P1 — share one of each shape
   > into the bot and log the raw payloads.
3. Insert a `sources` row (`kind='ig_reel'`, `origin='ig_dm'`, `external_id=reel_video_id`).
   Record a permalink if one can be derived; if not, accept that no permalink exists for
   this source (see §9 on the expiry fallback).
4. **Download the media immediately.** The `payload.url` is a short-lived CDN link and
   will expire — this cannot be deferred to a queued job.
5. Upload to object storage, enqueue `extract`, return `200`.

> **Important distinction:** this CDN URL is handed to us by Meta's own API, so fetching
> it from a cloud IP is entirely normal. Only *permalink-based* fetching (backfill) needs
> to originate from a residential IP. This is why forward capture has no local dependency.

**Idempotency:** Meta retries on non-2xx. Key on `(origin, external_id)` with a unique
constraint and treat a conflict as success.

**Reply loop:** after extraction completes, send a DM back via the Messaging API
summarising what was learned. This is a product feature (correction loop + reward), not
just a debug aid.

### 3.2 Authenticated ingest — Shortcut, extension, MCP

`POST /ingest` with a bearer token.

```json
{
  "kind":   "ig_reel | ig_carousel | image | url | note",
  "origin": "ig_dm | shortcut | extension | mcp | backfill",
  "url":            "https://…",
  "note":           "why this matters / what I learned",
  "media_base64":   "…",
  "captured_at":    "2026-08-16T10:00:00Z"
}
```

Always returns immediately with a `source_id`. All real work is queued.

### 3.3 Backfill import

`POST /import/saved-posts` accepts the `saved_posts.json` from the Meta data export.
Parses `saved_saved_media[]` → `{ title: creator_handle, string_map_data["Saved on"]:
{ href, timestamp } }`, inserts one `source` per permalink (`origin='backfill'`,
deduplicated against existing rows), and enqueues a `fetch_media` job per item.

---

## 4. Media acquisition — the cloud/local split

| Path | Where it runs | Why |
|---|---|---|
| IG DM CDN URL (reels, images) | **Cloud**, inline in webhook | Meta gave us the URL; fetching it is normal API use. Must be immediate — the URL expires |
| **DM `fallback` with permalink only** | **Local (M4)** | Likely the carousel case. Same constraints as backfill |
| Backfill permalink | **Local (M4)** | Requires session cookies and a residential IP; datacenter IPs get blocked and flagged |
| Non-Instagram URL | Local or cloud | Local by default for consistency; no strong constraint |

> **Consequence of the carousel case:** the local worker is **not backfill-only**. If
> shared carousels arrive as bare permalinks, forward capture of that content type depends
> on the local worker being alive — so an offline laptop delays those captures (they queue
> and resume; nothing is lost). Reels remain fully cloud-side and unaffected.

### Local fetch worker

A small daemon on the MacBook, run under `launchd`:

```
loop:
  job = POST /jobs/claim  {types: ["fetch_media"], worker_id: "m4-local"}
  if none: sleep 60; continue
  media = yt-dlp(job.url, cookies_from_browser=chrome)
  if unavailable:  POST /jobs/{id}/fail {reason: "unavailable"}   # deleted/private — terminal
  else:
      upload to presigned R2 URL
      POST /jobs/{id}/complete {media_key}
  sleep(random 45–90s)      # deliberate pacing
```

**Design notes:**

- **Pull, not push.** The worker polls the cloud. No inbound connectivity to the laptop,
  no tunnel, nothing to expose. It works from any network and simply idles when the
  laptop sleeps.
- **Deliberately slow.** One item per ~60s. The entire ~100-item backfill finishes in
  under two hours unattended. There is no reason to go faster and every reason not to.
- **`unavailable` is terminal, not an error.** 5–15% of backfilled reels will be gone.
  Mark and move on; never retry, never fail the batch.
- **Isolated blast radius.** This is the only component that can break due to upstream
  changes. If the Instagram extractor breaks, forward capture is entirely unaffected.

---

## 5. Extraction pipeline

Four queued stages, each independently retryable. A source's `status` tracks progress, so
a failure at any stage is resumable without redoing prior work.

### Stage 1 — `extract`

**Routed by source kind** — the content is a genuine mix and one path does not fit all:

| `kind` | Path | Note |
|---|---|---|
| `ig_reel` (talking head) | Whole video, default sampling | Audio carries most of it |
| `ig_reel` (slide / text-on-screen) | Whole video, default sampling | Multimodal reads the on-screen text; this is why transcript-only was rejected |
| `ig_reel` (screen recording) | Whole video, **denser frame sampling** | Code can be on screen only briefly; sparse sampling silently drops it |
| `ig_carousel` / `image` | **Image-sequence path** — all images in order, no audio | Not video; separate prompt |
| `url` | Fetched page text + screenshot | — |
| `note` | Text only, skip straight to Stage 2 | — |

Reel sub-shapes are not known in advance, so the pipeline uses one denser default rather
than trying to classify first — a wasted extra pass costs more than a few extra frames.

One multimodal LLM call per source. Returns structured JSON:

```json
{
  "summary": "…",
  "topics": ["rate-limiting", "api-design"],
  "category_hint": "technical | tooling | taste",
  "candidate_claims": [
    { "statement": "…", "specifics": "…", "applies_when": "…" }
  ],
  "visual_notes": { "layout": "…", "type_scale": "…", "motion": "…" },
  "quality": "high | low | not_relevant"
}
```

`quality: not_relevant` short-circuits the pipeline — not every saved reel is knowledge,
and the system must be able to say so.

### Stage 2 — `synthesize`

Turns candidates into **atomic claims**. The hard requirement, enforced by prompt and by
review: a claim must be **actionable standing alone**, with no reference to its source.

- Bad: `"This reel talks about rate limiting."`
- Bad: `"Use good spacing."`
- Good: `"Rate-limit every public write endpoint. Token bucket, per-API-key. Return 429
  with a Retry-After header."`

Each claim carries: `statement`, `detail`, `category`, `domains[]`, `applies_when`.

### Stage 3 — `merge` — *the critical stage*

This is what separates a brain from a pile.

```
embed(claim.statement)
neighbours = ANN search over knowledge_entries
             cosine SIMILARITY >= ~0.80, top 5
             i.e. in pgvector:  1 - (a <=> b) >= 0.80
             (note: <=> returns cosine DISTANCE, where 0 = identical)

if no neighbours:
    create new entry
else:
    LLM judge (claim, neighbours) → one of:
      DUPLICATE   → attach evidence to existing entry, discard claim
      REFINEMENT  → merge specifics into existing entry, bump version, attach evidence
      CONFLICT    → create entry, flag both for human decision  ← never silently keep both
      DISTINCT    → create new entry
```

**Why two steps:** vector similarity alone cannot tell "always use JWTs" from "never use
JWTs" — they are semantically adjacent and practically opposite. The embedding narrows
the candidate set cheaply; the LLM makes the actual call.

**Conflict handling matters.** Reels contradict each other constantly. Silently keeping
both produces a plugin that gives contradictory advice, which is worse than no plugin.
Conflicts surface in the review UI and wait for a decision.

**Tuning is deferred to P3** (PRD Q3). The right similarity threshold and merge
aggressiveness cannot be guessed — they need the real backfill corpus.

### Stage 4 — `cluster`

Entries are grouped into skill buckets by embedding clustering plus an LLM naming pass. A
cluster becomes its own skill once it exceeds ~8 entries; below that it folds into a
general bucket. This keeps the plugin from fragmenting into forty half-empty skills.

---

## 6. Data model

```sql
-- Raw captures
sources (
  id,
  kind,                       -- ig_reel|ig_carousel|image|url|note
  origin,                     -- ig_dm|shortcut|extension|mcp|backfill
  external_id, permalink, author_handle,
  note,                       -- user's why-note at capture
  media_key,                  -- object storage path
  status,                     -- pending|fetching|extracting|synthesized|done
                              -- |unavailable|failed|needs_review
  raw_extraction jsonb,
  captured_at, created_at,
  UNIQUE (origin, external_id)
)

-- Atomic claims (pre-merge, kept for traceability)
claims (
  id, source_id, statement, detail, category, domains text[],
  applies_when,
  embedding vector(N),        -- N fixed at migration time; see note below
  embedding_model text,       -- required by N11 — makes re-embedding detectable
  disposition,                -- new|duplicate|refinement|conflict|rejected
  entry_id                    -- what it merged into
)

-- Canonical knowledge — the actual brain
knowledge_entries (
  id, title, statement, detail_md,
  category,                   -- technical|tooling|taste
  is_universal bool,          -- eligible for the always-on core skill
  domains text[], applies_when,
  strength int,               -- evidence count; drives ordering in generated skills
  embedding vector(N),
  embedding_model text,
  skill_slug,
  status,                     -- active|superseded|rejected
  superseded_by, version, created_at, updated_at
)

entry_evidence (entry_id, source_id, claim_id)   -- traceability (PRD O7)
entry_assets   (entry_id, media_key, caption)    -- reference images for taste skill

-- Generated output
skills        (slug, name, trigger_description, body_md, last_generated_at)
plugin_builds (id, version, git_sha, entry_count, generated_at)

-- Queue
jobs (
  id, type, payload jsonb, status, attempts,
  locked_by, locked_at, run_after, last_error
)
```

**On embedding dimension:** `vector(N)` is fixed at DDL time, so the dimension is decided
by whichever embedding model is chosen in P2 (384/768/1024/1536 are all common). Changing
model later requires a **column rewrite plus full re-embed**, not just a re-embed. Storing
`embedding_model` per row is what makes that situation detectable rather than silently
corrupting similarity search.

**On `is_universal`:** the `category` enum (`technical|tooling|taste`) answers *what kind*
of knowledge an entry is. Eligibility for the always-on core skill is a separate axis — a
taste rule can be universal, and most technical rules are not — so it gets its own flag
rather than being overloaded onto `category`.

**On rejection:** a rejected claim records its `source_id`. Re-processing that source must
not resurrect it (PRD §7.5).

**On the queue:** Postgres with `SELECT … FOR UPDATE SKIP LOCKED` is genuinely sufficient
here. At a few jobs per week, a dedicated broker is pure operational cost. Revisit only if
throughput ever becomes a real constraint — it will not.

---

## 7. Output generation

### 7.1 Plugin generator

Renders the knowledge store into the plugin layout, then commits and pushes to a git repo.
Chintan runs a normal plugin update to pick it up.

```
.claude-plugin/plugin.json      version = plugin_builds.version
skills/godmode-core/SKILL.md    top ~15 entries where is_universal, by strength
skills/<slug>/SKILL.md          one per cluster
skills/ui-polish/references/    images from entry_assets
commands/<name>.md              capture command
.mcp.json                       godmode MCP server registration
```

**No plugin `CLAUDE.md` — verified.** Claude Code's plugin reference is explicit: *"A
`CLAUDE.md` file at the plugin root is not loaded as project context. Plugins contribute
context through skills, agents, and hooks rather than CLAUDE.md."* Writing one would fail
silently, which is the worst kind of failure.

**The always-on layer** is therefore `skills/godmode-core/SKILL.md`, with a deliberately
broad trigger ("use at the start of any coding task, when planning a build, or before
shipping"). Because skills are model-invoked, this is *near*-always-on, not guaranteed.

**Optional genuine always-on:** the generator can additionally write a marker-delimited
block into `~/.claude/CLAUDE.md`:

```
<!-- godmode:start v42 -->   … rules …   <!-- godmode:end -->
```

Idempotent — rewritten in place on each build. This is truly always loaded, at the cost of
living outside the plugin's update mechanism. Treat as opt-in.

**Core-skill discipline (PRD O1).** Hard-capped at ~40 lines. Only entries flagged
`is_universal` — always true, cheap to state. Everything else must earn its way into a
specialist skill. If this cap is relaxed, godmode degrades into the single-huge-file design
that was explicitly rejected.

**`SKILL.md` generation.** Frontmatter carries `name` and `description`; the description
is the trigger and is **the highest-risk artefact in the system** (PRD O2). Generate it to
name concrete situations, not topics:

- Weak: `"Knowledge about APIs."`
- Strong: `"Use when creating or modifying an HTTP endpoint, adding a route, or exposing
  a public API — covers rate limiting, auth, validation, idempotency, and error contracts."`

**Taste skill.** Ships actual reference images alongside the markdown. The skill body
points at them so Claude can look at the reference rather than read an abstraction of it.
This is the mechanism that makes Category 3 transfer at all.

### 7.2 MCP server

A thin stdio server, distributed inside the plugin, that proxies to the cloud API over
HTTPS with a personal token. No local database, no sync — one source of truth.

| Tool | Purpose |
|---|---|
| `search_knowledge(query, category?)` | "What do I know about auth?" |
| `preflight(project_description)` | Checklist for what's about to be built |
| `capture_note(text, category?)` | Backs the slash command (PRD §6.4) |
| `explain_entry(entry_id)` | Full detail + sources behind a rule |

The slash command is a thin wrapper that calls `capture_note` — reusing the MCP
connection means no separate HTTP client, credential, or auth path inside the command.

---

## 8. Cloud / local responsibility split

| Component | Location | Reason |
|---|---|---|
| Ingest API + webhook | Cloud | Meta requires a stable public HTTPS URL |
| Postgres + pgvector | Cloud (managed) | Single source of truth; must outlive the laptop |
| Object storage | Cloud | Media must survive; egress-free storage matters for image-carrying skills |
| Extraction workers | Cloud | Pure API calls; no residential-IP requirement |
| **Media fetch (permalinks)** | **Local M4** | Residential IP + browser cookies; the only grey-area component |
| Plugin generator | Cloud, pushes to git | Output is a git repo, reachable from anywhere |
| MCP server | Local (stdio, in plugin) | Runs inside Claude Code by design |
| Review UI | Cloud | Reachable from phone; needed for conflict resolution |

---

## 9. Failure modes

| Failure | Behaviour |
|---|---|
| Meta CDN URL expires before download | Source marked `failed` and the bot **DMs back asking for a re-share**. Note the `ig_reel` payload carries `url`/`title`/`reel_video_id` but *not* a permalink, so there is generally nothing for the local worker to re-fetch — re-sharing is the honest recovery path |
| Webhook delivery missed | Quarterly data-export backfill recovers it — the safety net for a missed habit |
| yt-dlp extractor breaks | `fetch_media` jobs fail and retry with backoff; forward capture completely unaffected |
| Reel deleted / now private | Terminal `unavailable`. Expected for 5–15% of backfill |
| LLM returns malformed JSON | Schema-validated; retry twice, then park for manual review |
| Laptop asleep during backfill | Jobs sit in the queue and resume on next poll. No timeout, no loss |
| Merge collapses distinct rules | Claims are retained pre-merge, so any merge is reversible |
| Generated skill never triggers | The silent killer. No automatic detection — requires deliberate testing in P4 |

---

## 10. Security

- Single tenant. No user table, no roles, no sessions beyond a personal token.
- Webhook HMAC verification on every request, before body parsing.
- Bearer token for `/ingest`, `/jobs/*`, and MCP; rotatable via env var.
- Secrets in the host's secret manager, never in the repo.
- **The generated plugin repo must stay private** — it encodes personal working patterns
  and, more practically, is executed as instructions by an AI with tool access.
- Presigned, short-TTL upload URLs for the local worker; it never holds storage credentials.
</content>
