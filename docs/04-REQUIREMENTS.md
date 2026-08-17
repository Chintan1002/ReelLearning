# godmode — Requirements

**Version:** 0.1 (draft)
**Date:** 2026-08-16
**Companion to:** `01-PRD.md`, `02-ARCHITECTURE.md`, `03-TECH-STACK.md`

Legend — priority is **Must** / **Should** / **Could**.
(Deliberately *not* P0/P1/P2 — those labels are used for **phases**, per PRD §9, and the
collision made rows ambiguous.)

---

## Phase 0 — Foundations

| # | Req | Pri |
|---|---|---|
| F0.1 | **DB host decided (Supabase)** and Postgres with pgvector provisioned; Alembic migrations wired. Deciding here is required because F2.13 depends on the table UI | Must |
| F0.2 | Schema created per Architecture §6 (`sources`, `claims`, `knowledge_entries`, `entry_evidence`, `entry_assets`, `skills`, `plugin_builds`, `jobs`) | Must |
| F0.3 | FastAPI app deployed to a stable public HTTPS URL | Must |
| F0.4 | Job queue: claim via `SELECT … FOR UPDATE SKIP LOCKED`, with attempts, backoff, `run_after`, `last_error` | Must |
| F0.5 | Worker loop process, deployed alongside the API | Must |
| F0.6 | Bearer-token auth middleware on all non-webhook endpoints | Must |
| F0.7 | Cloudflare R2 bucket + presigned upload/download URL helpers | Must |
| F0.8 | Sentry error tracking | Should |
| F0.9 | Docker Compose local dev environment | Should |
| F0.10 | GitHub Actions → deploy on push to `main` | Should |

**Exit:** a job can be enqueued via API, picked up by a worker, and marked complete, in production.

---

## Phase 1 — Forward capture

### Instagram setup (manual, blocking)

| # | Req | Pri |
|---|---|---|
| F1.1 | Second Instagram account created and converted to Professional | Must |
| F1.2 | Meta app created with Instagram Messaging; personal account added with a role on the app. **No App Review needed** — Standard Access covers accounts you have a role on | Must |
| F1.2a | **App flipped to Live mode in the App Dashboard.** Instagram does *not* deliver webhooks to apps in Development mode. May require business verification — unbounded external latency, so start it first (see M2) | Must |
| F1.3 | `messages` webhook subscribed and verified | Must |

### Spike — resolve before designing the webhook handler

| # | Req | Pri |
|---|---|---|
| F1.0 | **Payload spike.** Share one of each content shape — talking-head reel, slide reel, screen recording, **carousel/infographic**, feed post — into the bot and log raw webhook payloads. Record which attachment `type` each produces and whether usable media or a permalink is present. Meta documents no type for carousels and warns a `fallback` may arrive with **no payload** | Must |

**Why this is a blocking spike:** carousels are part of the real content mix, and if they
arrive as bare permalinks, forward capture for that shape depends on the local worker —
which changes the P1 scope and the cloud/local split.

### Webhook

| # | Req | Pri |
|---|---|---|
| F1.4 | `GET /webhooks/instagram` echoes `hub.challenge` when `hub.verify_token` matches | Must |
| F1.5 | `POST /webhooks/instagram` verifies `X-Hub-Signature-256` HMAC **before parsing the body**; rejects mismatches | Must |
| F1.6 | Parses `ig_reel` / `reel` attachments → `url`, `title`, `reel_video_id` | Must |
| F1.6a | Routes **all** attachment types per Architecture §3.1: `image`/`video` downloaded inline; `fallback` with a permalink → `fetch_media` job for the local worker; `fallback` with no payload → DM back asking for a link; `template`/`audio`/`file` accepted and marked `not_relevant` | Must |
| F1.6b | An unknown or undocumented attachment type is **logged with its raw payload and parked**, never silently discarded | Must |
| F1.7 | **Downloads media inline during the request** — the CDN URL expires and cannot be deferred | Must |
| F1.8 | Idempotent on `(origin, external_id)`; duplicate delivery returns 200 without reprocessing | Must |
| F1.9 | Responds 200 within Meta's timeout; all non-download work is queued | Must |
| F1.10 | Non-reel message types (text, images, stories) accepted without error | Should |

### Extraction

| # | Req | Pri |
|---|---|---|
| F1.11 | `extract` job: one multimodal call per source → schema-validated JSON, **routed by `kind`** (Architecture §5, Stage 1) | Must |
| F1.11a | **Image-sequence extraction path** for `ig_carousel` / `image` sources — all images in order, no audio, separate prompt. Carousels are not video and the video path does not cover them | Must |
| F1.11b | Frame sampling dense enough for screen-recording reels, where code may be on screen only briefly | Must |
| F1.12 | Malformed LLM output retried ×2, then parked as `needs_review` — never silently dropped | Must |
| F1.13 | `quality: not_relevant` short-circuits the pipeline; source marked and no claims created | Must |
| F1.14 | `synthesize` job produces 1–5 atomic claims per source | Must |
| F1.15 | Claims are **actionable standing alone** — no reference to the source reel. Enforced by prompt and spot-checked | Must |
| F1.16 | Each claim carries `statement`, `detail`, `category`, `domains[]`, `applies_when` | Must |
| F1.17 | Bot replies in the DM summarising what was extracted | Should |

**Exit:** sharing a reel to `@godmode.brain` produces atomic claims in the database within ~2 minutes, unattended.

---

## Phase 2 — Knowledge core

| # | Req | Pri |
|---|---|---|
| F2.0 | **Embedding model chosen before the migration is written** — `vector(N)` fixes the dimension at DDL time, so a later change is a column rewrite, not just a re-embed (Tech Stack D7) | Must |
| F2.1 | Every claim embedded on creation; `embedding_model` column populated per row | Must |
| F2.2 | `merge` job: ANN search over `knowledge_entries`, top-5, configurable threshold | Must |
| F2.3 | LLM merge judge returns exactly one of `DUPLICATE` / `REFINEMENT` / `CONFLICT` / `DISTINCT` | Must |
| F2.4 | `DUPLICATE` → evidence attached, `strength` incremented, no new entry | Must |
| F2.5 | `REFINEMENT` → specifics merged into the existing entry, `version` bumped, evidence attached | Must |
| F2.6 | `CONFLICT` → **both flagged for human decision; never silently kept** | Must |
| F2.7 | Similarity threshold and merge prompt configurable without a deploy | Must |
| F2.8 | Claims retained pre-merge so any merge is reversible | Must |
| F2.9 | Every entry traceable to its source(s) via `entry_evidence` (PRD O7) | Must |
| F2.10 | Every entry tagged `technical` / `tooling` / `taste` | Must |
| F2.10a | Every entry carries an `is_universal` flag — a separate axis from `category`, gating eligibility for the always-on core skill | Must |
| F2.11 | Rejecting an entry records the originating `source_id`; reprocessing that source must not resurrect it | Must |
| F2.12 | `cluster` job groups entries into skill buckets; a cluster becomes its own skill above ~8 entries. **Must**, not Should — F4.4 is a must-have and cannot be built without it | Must |
| F2.13 | Minimal review interface to approve, edit, reject, and resolve conflicts. Supabase's table UI satisfies this (host decided in F0.1); a FastAPI admin page is the fallback | Must |
| F2.14 | Supersede rather than delete — `superseded_by` retains history (PRD Q2) | Should |

**Exit:** feeding 5 overlapping reels about one topic yields **one** strong entry, not five.

---

## Phase 3 — Backfill

| # | Req | Pri |
|---|---|---|
| F3.1 | Meta data export requested and `saved_posts.json` obtained | Must |
| F3.2 | `POST /import/saved-posts` parses `saved_saved_media[]` → permalink + timestamp + creator handle | Must |
| F3.2a | Import handles **non-reel saved items** (carousels, feed posts, infographics) — the export mixes them freely. Classify `kind` at fetch time from what actually comes back, not from the URL alone | Must |
| F3.3 | Import deduplicates against existing sources; safe to re-run on a later export | Must |
| F3.4 | One `fetch_media` job enqueued per imported permalink | Must |
| F3.5 | Local worker daemon on the M4, supervised by `launchd` with `KeepAlive` | Must |
| F3.6 | Worker **polls** the cloud (`POST /jobs/claim`); no inbound connectivity to the laptop | Must |
| F3.7 | `yt-dlp` with `--cookies-from-browser chrome`; version pinned. **Carousels/images need an image-capable fetcher** (e.g. `gallery-dl`) — yt-dlp is video-oriented and will not cover the full mix | Must |
| F3.8 | Randomised 45–90s delay between fetches | Must |
| F3.9 | Deleted/private posts marked `unavailable` — **terminal, not retried, does not fail the batch** | Must |
| F3.10 | Media uploaded via short-TTL presigned URL; worker never holds storage credentials | Must |
| F3.11 | Worker resumes cleanly after sleep, network loss, or restart | Must |
| F3.12 | Backfill progress visible (pending / done / unavailable / failed counts) | Should |
| F3.13 | **Merge threshold tuned against the real corpus** (PRD Q3 / Tech Stack D5) | Must |

**Exit:** ~100 saved reels imported, fetched, extracted, and merged into a coherent knowledge base, with ≤15% loss.

---

## Phase 4 — Output

### Plugin generation

| # | Req | Pri |
|---|---|---|
| F4.1 | Generator renders the store into the plugin layout, commits, and pushes to a **private** git repo | Must |
| F4.2 | `.claude-plugin/` contains **only** `plugin.json` — all other dirs at plugin root (spec requirement; failure is silent) | Must |
| F4.2a | **No `CLAUDE.md` is written inside the plugin** — the spec states it is not loaded as project context. Writing one would fail silently | Must |
| F4.3 | `skills/godmode-core/SKILL.md` is the always-on layer: hard-capped at ~40 lines, `is_universal` entries only, ordered by `strength`, with a deliberately broad trigger description (PRD O1) | Must |
| F4.3a | Optional: generator writes a marker-delimited block (`<!-- godmode:start -->…<!-- godmode:end -->`) into `~/.claude/CLAUDE.md`, idempotently rewritten each build, for genuine always-on loading | Could |
| F4.4 | One `SKILL.md` per cluster, with `name` and `description` frontmatter | Must |
| F4.5 | Trigger descriptions name **concrete situations**, not topics (PRD O2) | Must |
| F4.6 | `plugin.json` version incremented per build; recorded in `plugin_builds` | Must |
| F4.7 | Regeneration is one command / one API call | Must |
| F4.8 | Generated plugin validated (loads without error) before push | Should |
| F4.9 | **Skill triggering tested manually in realistic scenarios** — the one risk conventional tests cannot catch | Must |

### MCP server

| # | Req | Pri |
|---|---|---|
| F4.10 | Stdio MCP server registered via plugin `.mcp.json` using `${CLAUDE_PLUGIN_ROOT}` | Must |
| F4.11 | `search_knowledge(query, category?)` | Must |
| F4.12 | `capture_note(text, category?)` writing to `/ingest` | Must |
| F4.13 | `preflight(project_description)` returning a tailored checklist | Should |
| F4.14 | `explain_entry(entry_id)` returning detail + sources | Should |
| F4.15 | Dependency packaging solved (uv venv on first run, or a self-contained binary) | Must |
| F4.16 | Fails gracefully when the cloud API is unreachable — never blocks a Claude Code session | Must |

### Capture command

| # | Req | Pri |
|---|---|---|
| F4.17 | Command in `commands/` (name TBD — PRD Q1), calling `capture_note` | Must |
| F4.18 | Captured note reaches the pipeline and is categorised, defaulting to `tooling` | Must |

**Exit:** plugin installed; a real project benefits from a skill firing without Chintan invoking it.

---

## Phase 5 — Taste layer

| # | Req | Pri |
|---|---|---|
| F5.1 | Chrome MV3 extension with a single "Send to godmode" action | Must |
| F5.2 | Captures URL, title, selection, **and a screenshot** (`chrome.tabs.captureVisibleTab`) | Must |
| F5.3 | **Prompts for a why-note** — required, not optional. Taste does not transfer without it | Must |
| F5.4 | Image/URL extraction produces structured design observations: layout, type scale, colour, motion, microcopy, empty/loading/error states | Must |
| F5.5 | Taste entries store reference images in `entry_assets` | Must |
| F5.6 | Generated taste skill **ships the reference images** under `skills/<slug>/references/` and points at them from the body (PRD O3) | Must |
| F5.7 | Taste rules are concrete and example-anchored; generic advice ("use good spacing") rejected at review | Must |
| F5.8 | iOS Shortcut: share-sheet action → `/ingest` with optional note prompt | Should |

**Exit:** a frontend build produces visibly better output because the taste skill fired with real references attached.

---

## Phase 6 — UI and polish

| # | Req | Pri |
|---|---|---|
| F6.1 | Next.js review UI: browse, search, filter by category/domain | Should |
| F6.2 | Edit, approve, reject, and supersede entries | Should |
| F6.3 | Conflict resolution view | Should |
| F6.4 | Source explorer — see what a reel produced, re-run extraction | Should |
| F6.5 | Trigger plugin rebuild from the UI | Should |
| F6.6 | Stats: sources vs. entries over time (the merge-effectiveness signal, PRD S4) | Could |
| F6.7 | Mobile-usable — review happens on a phone | Could |
| F6.8 | Quarterly reminder to re-run the data export backfill | Could |

---

## Non-functional requirements

| # | Req | Pri |
|---|---|---|
| N1 | Capture is never blocked by processing — `/ingest` returns immediately | Must |
| N2 | No capture is ever lost: everything persists before any LLM call | Must |
| N3 | Every pipeline stage independently retryable; failure is resumable without redoing prior work | Must |
| N4 | Webhook responds within Meta's timeout | Must |
| N5 | Backfill completes unattended in under ~2 hours for ~100 items | Should |
| N6 | Running cost ≤ $10/month | Should |
| N7 | Original media retained indefinitely, to allow re-extraction with improved prompts | Must |
| N8 | Generated plugin repo is **private** | Must |
| N9 | Secrets in the host secret manager; never committed | Must |
| N10 | LLM responses fixtured so pipeline tests run without API calls | Should |
| N11 | Embedding model name stored per row (re-embedding must be detectable) | Must |
| N12 | MCP failure degrades gracefully — never blocks a coding session | Must |
| N13 | Local worker failure never affects forward capture | Must |

---

## Manual / operational tasks

| # | Task | When |
|---|---|---|
| M1 | Create second IG account, convert to Professional | Before P1 |
| M2 | Create Meta app, add personal account role, **flip app to Live, complete business verification if prompted** | **Start before P0 code** — unbounded external latency, hard blocker for P1 |
| M3 | Request Meta data export (Saved only, JSON) — takes hours to days | Start early in P2 so it's ready for P3 |
| M4 | Decide the capture command name (PRD Q1) | Before P4 |
| M5 | Create private git repo for the generated plugin | Before P4 |
| M6 | Tune merge threshold against the real corpus | During P3 |
| M7 | Manually test skill triggering in real projects | During P4 |
| M8 | Re-run data export backfill | Quarterly |

> **Two items have unbounded external latency and both sit on the critical path.**
> **M2 (Live mode + business verification)** blocks P1 entirely — start it before writing
> any code. **M3 (data export)** blocks P3 — request it at the *start* of P2, not when P3
> begins. Neither can be compressed by working harder.

---

## Traceability — PRD goals → requirements

| PRD | Requirement |
|---|---|
| G1 low-friction capture | F1.1–F1.10, F4.17, F5.1–F5.3, F5.8, N1 |
| G2 atomic deduplicated rules | F1.11–F1.16, F2.0–F2.11 |
| G3 automatic surfacing | F2.12, F4.1–F4.16 |
| G4 raise the quality ceiling | F5.1–F5.7 |
| G5 compounding | F2.4, F2.5, **F3.1–F3.13**, F2.14, F4.7, F6.6 |
| O1 always-on core size cap | F4.2a, F4.3, F4.3a |
| O2 reliable skill triggers | F4.5, F4.9, M7 |
| O3 taste skill ships images | F5.5, F5.6 |
| O4 live MCP queries | F4.10–F4.14 |
| O5 capture command everywhere | F4.17, F4.18 |
| O6 one-command regeneration and normal plugin update | F4.1, F4.7 |
| O7 traceability | F2.9 |

*Backfill (F3.x) traces to G5 — it is the mass that makes compounding visible at all, and
the corpus P4's output quality depends on.*

---

## The three requirements most likely to decide whether this works

Stated plainly, because everything else is ordinary engineering:

1. **F4.5 / F4.9 — skill trigger quality.** If skills don't fire at the right moment, every
   other requirement in this document is wasted work. There is no automated test for this.
   This risk *rose* once F4.2a established that there is no plugin-level `CLAUDE.md`: with
   no guaranteed always-on channel inside the plugin, everything now depends on triggers
   firing. F4.3a exists as the escape hatch if they prove unreliable.
2. **F2.3–F2.6 — merge judgement.** Bad merging gives either a pile of duplicates or a mush
   of collapsed distinct rules. This is what makes godmode a brain instead of a folder.
3. **F5.3 — the required why-note.** Taste does not transfer through rules. Without the
   *why*, Category 3 produces generic advice and the "not average builds" goal quietly fails.
</content>
