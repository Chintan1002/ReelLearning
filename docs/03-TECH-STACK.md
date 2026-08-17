# godmode — Tech Stack

**Version:** 0.1 (draft)
**Date:** 2026-08-16
**Companion to:** `01-PRD.md`, `02-ARCHITECTURE.md`

---

## 0. The sizing constraint

Every choice below is made for **one user, ~100 existing sources, a few new per week.**

That is a genuinely tiny system. The main risk is not under-engineering — it is building a
distributed pipeline for a workload that fits comfortably in a single process. Where a
"proper" choice and a simple choice compete, this document picks the simple one and says
why.

**Rule applied throughout:** no component enters the stack unless it earns its keep at
*this* volume.

---

## 1. Stack at a glance

| Layer | Choice | One-line reason |
|---|---|---|
| Backend language | **Python 3.12** | Owns the video/ML/yt-dlp ecosystem outright |
| API framework | **FastAPI** | Async, Pydantic schemas, near-zero boilerplate |
| Database | **Postgres + pgvector** | Relational + vector + job queue in one engine |
| DB host | **Supabase** (decided in P0) | Managed + a usable table UI, which the P2 review step depends on |
| Object storage | **Cloudflare R2** | S3-compatible, **zero egress fees** |
| Job queue | **Postgres table** (`SKIP LOCKED`) | A broker is unjustifiable at this volume |
| Cloud host | **Railway** (or Fly.io) | Stable HTTPS URL, trivial deploys, cheap |
| Video understanding | **Multimodal LLM, native video** | One call replaces a whole pipeline |
| Rule synthesis / merge | **Claude** | Best at careful judgement over structured text |
| Embeddings | Small text-embedding model | Only used to narrow candidates before the LLM |
| Local worker | **Python + yt-dlp + launchd** | Runs on the M4, residential IP |
| MCP server | **MCP Python SDK** (stdio) | Same language as backend; ships in the plugin |
| Review UI | **Next.js + Tailwind + shadcn/ui** | Deployed on Vercel |
| Browser extension | **Chrome MV3, vanilla TS** | No framework needed for one button |
| iOS capture | **Apple Shortcuts** | Zero code |
| Plugin delivery | **Private git repo** | Native Claude Code plugin install path |

---

## 2. Backend — Python + FastAPI

**Chosen because** the two hardest dependencies in this system — `yt-dlp` and multimodal
model SDKs — are Python-first. Building the backend in TypeScript would mean a second
runtime purely to host the fetch worker, for no gain.

FastAPI specifically: async request handling matters for the webhook (which must respond
fast while downloading media), and Pydantic models double as the validation layer for
LLM JSON output — which is used heavily in the extraction pipeline.

**Rejected:**

- **Node/TypeScript** — would force a polyglot repo because of yt-dlp.
- **Django** — the ORM and admin are real conveniences, but the framework weight is
  unjustified for ~10 endpoints.

---

## 3. Database — Postgres + pgvector

One engine doing three jobs:

1. **Relational store** — sources, claims, entries, evidence.
2. **Vector index** — pgvector for merge-candidate search.
3. **Job queue** — a `jobs` table with `SELECT … FOR UPDATE SKIP LOCKED`.

**On skipping a dedicated vector DB (Pinecone, Chroma, Qdrant):** the corpus is a few
hundred to a few thousand vectors. Postgres does exact or approximate search over that in
single-digit milliseconds. A separate vector service would add a second consistency
domain — entries and their embeddings could drift apart — for zero measurable benefit.

**On skipping Redis/Celery/SQS:** the queue handles a few jobs per week with occasional
bursts of ~100 during backfill. `SKIP LOCKED` is a well-established, boring pattern that
gives durability, retries, and visibility for free, and one less service to operate.
Revisit only if throughput ever becomes a genuine constraint — it will not.

**Host: Supabase.** The alternative, Neon, is a slightly cleaner Postgres-native product
with scale-to-zero and branching — but Supabase ships a **usable table UI**, and the P2
review requirement leans on exactly that to avoid building a custom admin before P6. Since
the review step is a must-have and the UI is not, the bundled table view decides it.

**Decide this in P0, not later** — a P2 must-have depends on it.

---

## 4. Object storage — Cloudflare R2

Stores reel videos, screenshots, and the reference images that ship inside the taste skill.

**R2 over S3** for one specific reason: **zero egress fees.** Reference images get read
repeatedly during plugin generation and by Claude when the taste skill loads. On S3 that
is a small, permanent, annoying bill. On R2 it is free. S3-compatible API means the SDK is
the same either way.

**Lifecycle:** keep original media indefinitely — it is the only way to re-extract if the
extraction prompt improves later, which it will.

---

## 5. AI models

> **Deliberately unversioned.** Model names and capabilities move fast, and pinning a
> specific version in an architecture document guarantees it is stale before the build
> starts. What follows specifies the **capability required** and the **selection
> criteria**. Pick the current best-fit model at implementation time and record the actual
> choice in an ADR.

### 5.1 Video understanding — native multimodal

**Requirement:** accept a whole short video (frames + audio) in one call and return
structured JSON.

**Selection criteria:** native video input (not frames-as-images), reliable structured
output, long-enough context for a 60–90s reel, cheap enough that ~100 backfill items are
a rounding error.

**Currently the Gemini family is the natural fit** — native video input via the File API
is its distinguishing capability. Verify current model naming and pricing at build time.

**Must also handle still images** — carousels and infographics are part of the mix, so the
chosen provider needs a multi-image path alongside the video one. Same model family,
different prompt.

**Why not transcript + OCR (Whisper + keyframe OCR):** it is the "correct" engineering
answer at scale and the wrong one here. The content is a **mix** — talking-head explainers,
music-only slide reels where all content is on-screen text, screen recordings of code, and
carousels that are not video at all. Transcript-only covers exactly one of those four.
Covering the rest by hand means keyframe sampling, OCR, dedup, and stitching partial text
back into coherent meaning — a lot of machinery to hand-roll. At a few items per week,
paying more per item to delete that entire subsystem is straightforwardly correct.

### 5.2 Rule synthesis, merge judgement, skill generation — Claude

Three jobs needing careful reasoning over structured text rather than perception:

- **Atomisation** — turning a loose extraction into standalone, actionable claims.
- **Merge judgement** — duplicate / refinement / conflict / distinct. Judgement-heavy and
  the stage where errors are most expensive.
- **Skill generation** — writing `SKILL.md` bodies and, critically, trigger descriptions.

**Note the self-referential upside:** godmode generates skills to be consumed by Claude.
Having Claude write them means the generator and the consumer share the same instincts
about what makes a skill fire correctly.

### 5.3 Embeddings

Any current small text-embedding model. This is the least consequential choice in the
document — embeddings only narrow the candidate set from "everything" to "about five," and
the LLM makes the real decision. Optimise for cheap and fast.

**Two hard constraints:**

1. **Store `embedding_model` on every row.** Changing model later requires re-embedding the
   whole corpus; without the model name recorded, a mixed corpus silently corrupts
   similarity search with no visible symptom.
2. **The vector dimension is fixed at DDL time.** pgvector's `vector(N)` is not flexible,
   and small models vary (384 / 768 / 1024 / 1536). Choosing the model therefore also
   chooses the column width, and switching later means a **column rewrite**, not just a
   re-embed. Pick the model in P2 before writing the migration.

---

## 6. Local fetch worker

```
Python 3.12 · yt-dlp · httpx · launchd (KeepAlive)
```

- **`yt-dlp`** with `--cookies-from-browser chrome`, for video. Treat as a **volatile
  dependency** — its Instagram extractor breaks periodically and is repaired upstream. Pin
  a version, update deliberately, and expect occasional maintenance.
- **`gallery-dl`** (or equivalent) for **carousels and image posts**. yt-dlp is
  video-oriented; the saved content is a mix that includes carousels and infographics, so
  one fetcher does not cover it. Same volatility caveat applies.
- **Blast radius note:** breakage here never touches *reel* forward capture (cloud-side).
  It does affect carousel forward capture if those arrive as bare permalinks — pending the
  F1.0 spike.
- **`launchd`** over cron: `KeepAlive` restarts it after crashes and reboots, and it
  handles sleep/wake correctly. Cron would need its own supervision.
- **No inbound connectivity.** The worker polls the cloud API. Nothing is exposed on the
  laptop, and it works identically on any network.
- **Rate limiting is a feature.** Sleep 45–90s between fetches. The full backfill takes
  under two hours unattended.

---

## 7. MCP server

**MCP Python SDK**, stdio transport, distributed inside the plugin via `.mcp.json`:

```json
{
  "mcpServers": {
    "godmode": {
      "command": "${CLAUDE_PLUGIN_ROOT}/mcp/run.sh",
      "env": { "GODMODE_API": "https://…", "GODMODE_TOKEN": "…" }
    }
  }
}
```

**Thin proxy by design.** It holds no local database and does no sync — it forwards to the
cloud API. One source of truth, and no cache-invalidation problem when the knowledge base
updates.

**Packaging caveat:** Python's dependency story makes plugin distribution awkward. Use a
`uv`-managed venv created on first run, or ship a self-contained binary. This is a known
rough edge worth solving early rather than discovering during P4.

---

## 8. Generated plugin format

Structure is fixed by Claude Code's plugin spec (verified against current docs):

```
godmode-plugin/
├── .claude-plugin/plugin.json     # only plugin.json lives here — nothing else
├── skills/
│   ├── godmode-core/SKILL.md      # the always-on layer (broad trigger)
│   └── <slug>/SKILL.md            # frontmatter: name, description
│       └── references/*.png       # taste skill assets
├── commands/<capture-cmd>.md
└── .mcp.json
```

**Two spec rules that both fail silently if broken:**

1. `.claude-plugin/` contains **only** `plugin.json`. Every other directory sits at the
   plugin root.
2. **There is no plugin `CLAUDE.md`.** Per the reference: *"A `CLAUDE.md` file at the
   plugin root is not loaded as project context. Plugins contribute context through skills,
   agents, and hooks rather than CLAUDE.md."* The always-on layer is a broadly-triggered
   skill instead — optionally supplemented by a marker-delimited block the generator writes
   into `~/.claude/CLAUDE.md`, which sits outside the plugin.

`${CLAUDE_PLUGIN_ROOT}` resolves to the install directory — use it for all script and asset
paths. `${CLAUDE_PLUGIN_DATA}` persists across plugin updates, which is the right place for
any local cache added later.

**Delivery:** the generator commits and pushes to a **private** git repo; Chintan installs
and updates through the normal plugin flow. Private is non-negotiable — the plugin encodes
personal working patterns and is executed as instructions by an AI with tool access.

---

## 9. Frontend — review UI

```
Next.js (App Router) · Tailwind · shadcn/ui · Vercel
```

Scope is small and specific: review extracted entries, resolve merge conflicts, reject bad
rules, browse the knowledge base, trigger a plugin rebuild.

**On effort:** the *polished* Next.js app is deliberately P6. P2 still needs a **minimal**
review path — the Supabase table UI is sufficient there, which is part of why Supabase won
in §3. But godmode exists to stop shipping average-looking builds, so a godmode that itself
looks average would be a bad joke; the P6 UI doubles as the first real test of the taste
skill.

---

## 10. Capture clients

| Client | Tech | Notes |
|---|---|---|
| iOS Shortcut | Apple Shortcuts | Zero code. Share-sheet action → `POST /ingest` with optional note prompt |
| Chrome extension | MV3, vanilla TS | One button. Needs `activeTab` + `scripting`; `chrome.tabs.captureVisibleTab` for the screenshot. No framework |
| Slash command | Markdown in `commands/` | Calls the `capture_note` MCP tool — no HTTP client of its own |

---

## 11. Development and operations

| Concern | Choice |
|---|---|
| Dependency management | `uv` — fast, lockfiles, handles the MCP venv too |
| Migrations | Alembic |
| Testing | pytest; **record real LLM responses as fixtures** so pipeline tests don't hit APIs |
| Local dev | Docker Compose (Postgres + pgvector) |
| Webhook testing | `ngrok` / `cloudflared` to receive real Meta events locally |
| CI/CD | GitHub Actions → Railway on push to `main` |
| Error tracking | Sentry free tier |
| Secrets | Railway env vars; never committed |

**Two testing notes worth stating up front:**

1. **Fixture the LLM calls.** Pipeline logic (merge, clustering, generation) must be
   testable without API calls, or the test suite becomes too slow and expensive to run and
   will quietly stop being run.
2. **Test skill triggering explicitly.** PRD O2 flags this as the highest-risk requirement,
   and it is the one thing conventional testing will not catch. Budget real time in P4 for
   installing the plugin and checking whether skills actually fire in realistic situations.

---

## 12. Cost estimate

| Item | Monthly |
|---|---|
| Railway (backend) | ~$5 |
| Neon / Supabase | $0 (free tier) |
| Cloudflare R2 | ~$0 (well under free tier) |
| Vercel | $0 (hobby) |
| Video extraction | ~$1–3 one-off for the full backfill; cents/month ongoing |
| Synthesis + merge | Low single-digit dollars/month |
| **Total** | **≈ $5–10/month, plus a few dollars once for backfill** |

At a few reels per week, model cost is not a design constraint — which is exactly why §5.1
chose the expensive-per-item, cheap-to-build extraction path.

---

## 13. Decisions to revisit

| # | Decision | Revisit when |
|---|---|---|
| D1 | Postgres as job queue | Never, realistically. Only if volume grows 100× |
| D2 | Multimodal-over-whole-video extraction | If per-item cost ever becomes material, or if quality proves worse than transcript+OCR on real reels |
| D3 | Thin MCP proxy (no local cache) | If mid-build latency becomes noticeable |
| D4 | Python for the MCP server | If the venv packaging proves too fragile to ship — a Go/Rust single binary is the fallback |
| D5 | Merge similarity threshold | **In P3**, against the real backfill corpus. Cannot be guessed (PRD Q3) |
| D6 | Supabase over Neon | If the review UI moves fully custom in P6, the table-UI advantage disappears and either host is equivalent |
| D7 | Embedding model **and its dimension** | Must be decided in P2 before the migration; changing it later is a column rewrite |
</content>
