# godmode — project context for Claude Code

> Read this before touching anything. It encodes decisions that were argued out
> and settled; re-deriving them from scratch will produce worse answers.

## ▶ Start here

**`docs/ROADMAP.md` is the execution protocol.** It defines what to build, in what order,
and when you may move on. At the start of every session:

1. Read this file (constraints).
2. Open `docs/ROADMAP.md` §4 and find the first task not marked `done`.
3. Read only the requirement rows and architecture section that task names.
4. State the task ID you are starting and whether its preconditions are met.

**Update the ROADMAP ledger at the end of every task.** It is state, not documentation — it
is how the next session knows where you left off.

**Stop at every 🚦 GATE.** Gates need a human decision or an external unblock. Do not infer
the answer or build past it.

**The first task is T0 — a throwaway extraction spike. Do not start with infrastructure.**

---

## 1. What this is

A personal system that turns saved Instagram content into **applied leverage** — not a
searchable archive. The user saves developer/design reels constantly and re-derives the
same knowledge repeatedly. Search is not the fix; the knowledge has to arrive *unprompted,
at the moment of relevant work*.

**The output is a generated Claude Code plugin** (skills + an MCP server), regenerated as
the knowledge base grows. The reels become the plugin; the plugin shows up in the editor.

**Single user. The user is the only user.** Multi-tenancy, org accounts, and social
features are out of scope — permanently, not "for now". If a change only makes sense for a
second user, it is wrong.

---

## 2. Current status

**Docs only. No code has been written yet.** Two external blockers gate the build, both
with unbounded latency and both already started:

| Blocker | What it is | Blocks |
|---|---|---|
| **M2 — Meta app to Live mode** | Business verification may be required. Nothing in Phase 1 is testable until it clears | All of P1 |
| **F1.0 — payload spike** | Share one of each content shape into the bot, log raw webhook payloads | P1 design |

**Do not start building Phase 1 handlers before F1.0 resolves.** Its outcome changes the
cloud/local split (see §4).

**Neither blocker should idle you.** `POST /ingest` is the seam (Architecture §3.0): every
capture client is an adapter over one internal function, so the entire pipeline is buildable
and testable through a manual CLI while Meta is pending. Roadmap tasks T0–T5 need nothing
external. If the Meta track is blocked, advance the other one.

One open decision: **the name of the in-editor capture slash command.** The user is
picking it. Do not invent one and bake it in.

---

## 3. Doc map

Everything in `docs/` is the spec. Read the relevant one before proposing a change.

| File | Contains | Read it when |
|---|---|---|
| `docs/01-PRD.md` | Problem, users, scope, phases, risks | Any "why" or "should we" question |
| `docs/02-ARCHITECTURE.md` | Components, webhook routing, pipeline stages, data model | Any structural or data-shape change |
| `docs/03-TECH-STACK.md` | Technology choices **and why alternatives were rejected** | Before proposing any dependency |
| `docs/04-REQUIREMENTS.md` | Numbered, prioritized requirements (F1.x, F3.x…) | Implementing anything; cite the requirement ID |
| `docs/05-BUILD-GUIDE.md` | How to work in this repo; near-term tactics | Starting out, or unsure how to drive a task |
| **`docs/ROADMAP.md`** | **Task IDs, dependency graph, gates, status ledger** | **Every session — this is the execution protocol** |

Requirement IDs are stable. Reference them in commits and PRs (`F1.6a`, not "the webhook thing").

---

## 4. Hard constraints

These are settled. **Challenge them explicitly if you think they're wrong — but do not
silently violate them.**

### Capture

- **The IG DM media URL is short-lived.** It must be downloaded *inline during the webhook
  request*, never queued for later. Deferring the fetch is a correctness bug, not a
  performance choice.
- **Route by attachment type, do not assume video.** Only `ig_reel` / `reel` are verified.
  `image`, `video`, `fallback`, `template`, `audio`, `file` all have defined handling in
  Architecture §3.1.
- **Unknown attachment types are logged with their raw payload and parked — never silently
  discarded.**

### The carousel problem

Meta documents **no** attachment type for shared feed posts or multi-image carousels, and
warns that unsupported shares may arrive as a `fallback` **with no payload at all**.
Carousels and infographics are a real part of the saved content mix.

**Consequence:** if carousels arrive as bare permalinks, the local worker is **not
backfill-only** — ongoing carousel capture depends on it. This is what F1.0 resolves. Do
not design around either outcome until the spike says which it is.

### Extraction

- **One multimodal call over the whole source**, routed by `kind`. Transcript-only was
  rejected deliberately: it covers exactly one of four content shapes.
- The four shapes are talking-head, text-on-screen slides (music-only audio), screen
  recordings of code, and carousels (not video at all).
- **Screen recordings need denser frame sampling** — code is often on screen for a second
  or two, and sparse sampling drops it silently with no error.
- Carousels use a **separate image-sequence path**, not the video path.

### Cloud vs local

| Runs where | What | Why |
|---|---|---|
| **Cloud** | Webhook, inline CDN downloads, pipeline | Meta gave us the URL; fetching it is normal API use |
| **Local (M4)** | Backfill permalinks, and possibly carousel permalinks | Needs session cookies and a residential IP; datacenter IPs get blocked |

The local worker is the **one grey-area component**. Keep it isolated so its breakage never
touches forward capture. `yt-dlp` and `gallery-dl` are **volatile dependencies** — pin
versions, expect periodic upstream breakage, never put them on a critical path that must
not fail.

### Non-negotiable

- **No secrets in the repo.** Session cookies, Meta tokens, API keys — env only. **The
  GitHub remote is public** (`Chintan1002/ReelLearning`), so anything committed is
  world-readable the moment it is pushed. Check `.gitignore` covers a new file's shape
  before adding it.
- **Never lose a capture.** Failures park with the raw payload for replay. Silent drops are
  the one unacceptable failure mode.
- Volume is a **few items per week, under 100 to backfill**. Optimizing for throughput is
  wasted work; optimizing for not-losing-things and low maintenance is the goal.

---

## 5. Sync with the Cowork project

These docs exist in two places: this folder, and a Claude project named
**"Basic Doc Creation and thinking"** under `godmode/`. **There is no background daemon.**
Sync happens only when a Cowork session runs it.

The mode is **merge, and ask on conflict**:

- `.sync/manifest.tsv` records the SHA-256 of each doc *as of the last sync* — a merge base.
- Local SHA differs from base → **you changed it here.**
- Project content differs from base → **it changed there.**
- **Both differ → conflict.** The Cowork session surfaces it and asks; it does not pick.

**What this means for you (Claude Code):** edit `docs/` freely and commit. Your changes are
detected, never silently overwritten. Just **commit before asking for a sync** so the diff
is clean.

Run `scripts/sync-check.sh` any time to see the current state.

---

## 6. Conventions

- Docs are the source of truth for intent; code follows them. If code must diverge, **update
  the doc in the same change** — a stale spec is worse than none.
- Cite requirement IDs in commit messages.
- **Commit and push to `origin/main` at the end of every task**, together with the ROADMAP
  ledger update (ROADMAP §7). The remote is `https://github.com/Chintan1002/ReelLearning.git`
  and is the durable record of progress — work that only exists locally does not count as
  progress. Do not batch a week of tasks into one push.
- Keep the four docs' numbering stable; append rather than renumber.
- Prefer boring, well-understood technology. This is a system that must keep working with
  near-zero maintenance attention, not a place to try things.

---

## 7. Working with the user

He thinks by arguing. Push back with reasons when something looks wrong — the docs are
sharper because several early assumptions got challenged rather than implemented. Vague
agreement is not useful here.
