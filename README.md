# godmode

**A personal knowledge system that turns saved Instagram reels into a Claude Code plugin
your AI coding tools read automatically at build time.**

Every reel you save quietly raises the floor on every project you build after it.

---

## The problem

I save a lot of Instagram reels about development — rate limiters, CI/CD, idempotency
keys, DB indexing, error handling. The kind of thing you don't know you need until you
need it. Three things go wrong:

1. **Saving is not learning.** The reels go into a folder nobody revisits.
2. **The knowledge is needed at build time, not browse time.** The moment a rate limiter
   matters is while writing a public endpoint — not while scrolling.
3. **Output quality plateaus.** There is no accumulating standard that makes each project
   better than the last.

The core failure is a **recall gap, not a capture gap.** Any solution that ends in "and
then you go read your notes" has not solved the problem. That rules out building a
searchable archive, which is the obvious answer and the wrong one.

## The approach

The output is not a notes app. It is a **generated Claude Code plugin** — a broadly-scoped
core skill, a set of contextually-loading specialist skills, and an MCP server for live
queries — regenerated as the knowledge base grows. Install it once and every project
inherits everything the system has learned. The knowledge arrives unprompted, at the
moment of relevant work.

---

## Architecture

```
CAPTURE                    CLOUD (always on)              LOCAL (Apple silicon)
─────────                  ─────────────────              ─────────────────────
IG DM share ──webhook──┐
iOS Shortcut ──HTTPS───┤   ┌────────────────────┐
Chrome extension ──────┼──►│ Ingest API         │──┐ inline CDN download
/capture (MCP) ────────┤   │ FastAPI + HMAC     │  │ (URL expires — cannot
Data-export ZIP ───────┘   └─────────┬──────────┘  │  be queued)
                                     ▼             │
                           ┌────────────────────┐  │   ┌──────────────────┐
                           │ Job queue          │◄─────│ Local fetch      │
                           │ Postgres           │  │   │ worker           │
                           │ FOR UPDATE         │──────│ yt-dlp +         │
                           │ SKIP LOCKED        │  │   │ gallery-dl       │
                           └─────────┬──────────┘  │   │ launchd, polls   │
                                     ▼             │   └──────────────────┘
                           ┌────────────────────┐  │
                           │ Object storage R2  │◄─┘
                           └─────────┬──────────┘
                                     ▼
                      ┌──────────────────────────────┐
                      │ 1. EXTRACT                   │
                      │    multimodal LLM, native    │
                      │    video, routed by kind     │
                      ├──────────────────────────────┤
                      │ 2. SYNTHESIZE → claims       │
                      ├──────────────────────────────┤
                      │ 3. MERGE  ← the critical one │
                      │    pgvector ANN narrows to   │
                      │    ~5, then LLM judges:      │
                      │    duplicate / refinement /  │
                      │    conflict / distinct       │
                      ├──────────────────────────────┤
                      │ 4. CLUSTER                   │
                      └──────────────┬───────────────┘
                                     ▼
                           ┌────────────────────┐
                           │ Knowledge store    │◄── review via table UI
                           │ canonical entries  │
                           └─────────┬──────────┘
                                     ▼
                           ┌────────────────────┐      ┌─────────────────┐
                           │ Plugin generator   │─push►│ private git repo│
                           │ → skills/ +        │      │ godmode-plugin  │
                           │   commands/        │      └────────┬────────┘
                           └────────────────────┘               │ installed
                                     ▲                          ▼
                                     └──────────── MCP server (stdio, in-editor)
```

**The merge stage is what makes this a brain rather than a pile.** Ten reels about auth
should yield one strong auth entry, not ten notes. Near-duplicates merge into and
strengthen the existing entry rather than accumulating beside it.

---

## Stack

| Layer | Choice | Why |
|---|---|---|
| Backend | Python 3.12 + FastAPI | Owns the video/ML/yt-dlp ecosystem; async, Pydantic schemas |
| Database | Postgres + pgvector | Relational store, vector index, and job queue in one engine |
| DB host | Supabase | Managed, and its table UI *is* the review interface for P2 |
| Object storage | Cloudflare R2 | S3-compatible, zero egress fees |
| Job queue | Postgres table, `SKIP LOCKED` | A broker is unjustifiable at this volume |
| Video understanding | Multimodal LLM with native video input | One call replaces an entire pipeline |
| Synthesis / merge judgement | Claude | Careful judgement over structured text |
| Local worker | Python + yt-dlp + gallery-dl + launchd | Residential IP; datacenter IPs get blocked |
| Output | MCP Python SDK (stdio), shipped inside the plugin | Same language as the backend |
| Review UI | Supabase table UI now, Next.js later | Deliberately deferred — see below |
| Deploy | Railway, GitHub Actions on push to `main` | Stable HTTPS URL, trivial deploys |

---

## Engineering decisions worth defending

These were argued out and written down with their rejected alternatives, so the reasoning
survives contact with a future maintainer who has forgotten it.

**One multimodal call over the whole video, not transcript + OCR.**
Whisper plus keyframe OCR is the "correct" answer at scale and the wrong one here. The
content is a *mix*: talking-head explainers, music-only slide reels where everything is
on-screen text, screen recordings of code, and carousels that aren't video at all.
Transcript-only covers exactly one of those four. Covering the rest by hand means
keyframe sampling, OCR, dedup, and stitching partial text back into meaning — a large
subsystem to hand-roll. At a few items per week, paying more per item to delete that
subsystem is straightforwardly correct. Measured cost: well under a cent per reel; the
entire ~100-item backfill lands in low single-digit dollars.

**Download DM media inline during the webhook request, never queued.**
The Instagram CDN URL is short-lived. "Async is cleaner" is the reasonable default and it
is a correctness bug here, not a performance trade-off.

**One ingest seam decouples the build from an external blocker.**
`POST /ingest` is the single internal function every capture client funnels into — the
webhook, the iOS Shortcut, the browser extension, the MCP command, and a manual CLI are
all *adapters* over it, not special paths. This is what lets the entire pipeline be built
and tested while Meta app review (unbounded latency) is still pending.

**Nothing is ever silently dropped.**
Unrecognised attachment types are logged with their raw payload and parked for replay.
Silent drops are the one unacceptable failure mode, so the queue has a `parked` state
alongside retries and backoff.

**The vector column's dimension is a gated decision, not a default.**
`vector(N)` is fixed at DDL time; changing it later is a column rewrite, not a re-embed.
So the schema is split across two migrations and anything carrying a vector waits until
the embedding model is chosen deliberately.

**Backfill runs after the merge logic works, not before.**
Pushing ~100 sources through an unproven extractor wastes the corpus — and a plugin
generated from 15 reels would be too thin to judge, giving a false read on whether the
whole idea works.

**The local fetch worker is isolated from the critical path.**
It's the one grey-area component, and `yt-dlp`/`gallery-dl` are volatile dependencies —
pinned versions, expected upstream breakage, and never positioned where their failure can
stop forward capture.

**Single user, permanently.** No `user_id` "for later." If a change only makes sense for a
second user, it's wrong.

---

## Build methodology

The repo is built by an AI agent following a written execution protocol
([`docs/ROADMAP.md`](docs/ROADMAP.md)) — task IDs, a binding dependency graph, a status
ledger treated as state rather than documentation, and **four human decision gates the
agent is forbidden to infer past**:

| Gate | Question | Cost of getting it wrong |
|---|---|---|
| **G1** | Are extracted claims actionable enough to act on? | Weeks of infrastructure around an idea that doesn't work |
| **G2** | How do shared carousels actually arrive from Meta? | Wrong cloud/local split; carousel capture silently unsupported |
| **G3** | Which embedding model, and therefore which dimension? | A column rewrite, not a re-embed |
| **G4** | Do the generated skills actually fire at the right moment? | The honest failure mode: a polished pipeline whose rules nobody reads |

The riskiest assumption — that a multimodal model reading a whole reel produces claims
worth acting on — is tested **first**, by a deliberately throwaway ~150-line script with no
database, no framework, and no API. Building the foundations first would have deferred that
discovery by weeks and risked scaffolding a hollow centre.

Two independent tracks run in parallel by design, so the Meta app-review dependency never
idles the build.

---

## Status

**Design complete; build in progress at the validation spike (T0).**

| | |
|---|---|
| ✅ | PRD, architecture, tech stack, and numbered requirements finalised |
| ✅ | Execution roadmap with dependency graph, gates, and status ledger |
| 🔄 | **T0** — extraction validation spike, in progress |
| ⬜ | G1 → foundations → forward capture → knowledge core → backfill → plugin generation |

No application code has been written yet. That is the plan working as intended, not a
delay: the roadmap puts a no-infrastructure validation spike ahead of all foundations
precisely so the central assumption is tested before anything is built around it.

---

## Repo layout

```
docs/01-PRD.md            Problem, users, scope, phases, risks
docs/02-ARCHITECTURE.md   Components, webhook routing, pipeline stages, data model
docs/03-TECH-STACK.md     Technology choices and why alternatives were rejected
docs/04-REQUIREMENTS.md   Numbered, prioritised requirements (stable IDs, cited in commits)
docs/05-BUILD-GUIDE.md    How to work in this repo
docs/ROADMAP.md           Execution protocol: task IDs, dependency graph, gates, ledger
CLAUDE.md                 Hard constraints for the AI agent building this
spikes/extraction/        T0 validation spike (throwaway by design)
```

---

*Single-user personal system. Built on an Apple silicon MacBook Pro.*
