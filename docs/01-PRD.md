# godmode — Product Requirements Document

**Version:** 0.1 (draft)
**Date:** 2026-08-16
**Owner:** Chintan
**Status:** Finalised for build

---

## 1. Summary

**godmode** is a personal, compounding knowledge system that turns the things Chintan
saves and learns — mostly Instagram reels about development, plus design references and
his own hard-won lessons — into an **operating manual that his AI coding tools read
automatically at build time**.

The output is not a notes app. It is a **generated Claude Code plugin** (a broadly-scoped
core skill, a set of contextually-loading specialist skills, and an MCP server for live
queries) that is regenerated as the knowledge base grows. Install it once, and every
project inherits everything godmode has learned.

**One-line pitch:** every reel you save quietly raises the floor on every project you
build after it.

---

## 2. Problem

Chintan saves a large number of Instagram reels covering the tech that "vibecoders"
need but don't realise they need — rate limiters, CI/CD pipelines, custom 404 pages,
how to choose the right logic, how to prevent production-time issues.

Three things go wrong today:

1. **Saving is not learning.** The reels go into a folder that is never revisited. The
   knowledge is captured but not retained, and definitely not applied.
2. **The knowledge is needed at build time, not browse time.** The moment a rate limiter
   matters is when writing a public endpoint — not while scrolling. Even a perfectly
   organised note is useless if the recall has to be manual.
3. **The output quality plateaus.** Builds come out looking and feeling like average
   builds. There is no accumulating standard that makes each project better than the last.

The core failure is a **recall gap**, not a capture gap. Any solution that ends in "and
then you go read your notes" has not solved the problem.

---

## 3. Goals

| # | Goal | How we know it worked |
|---|---|---|
| G1 | Capture knowledge with near-zero friction, at the moment it appears | Capturing a reel takes ≤2 taps and no context switch |
| G2 | Convert raw sources into atomic, actionable, deduplicated rules | 10 reels about auth yield 1 strong auth entry, not 10 notes |
| G3 | Surface the right knowledge automatically during a build | Chintan does not open godmode to benefit from it |
| G4 | Raise the ceiling on build quality, not just correctness | New builds are visibly distinguishable from previous ones |
| G5 | Compound over time | The plugin measurably improves month over month |

### Non-goals (v1)

- **Not multi-user.** Single user, single tenant. No auth system beyond a personal token,
  no billing, no onboarding, no public knowledge base.
- **Not a social/discovery product.** godmode never recommends new content to consume.
- **Not a general note-taking app.** If it does not eventually become a rule that changes
  how something gets built, it does not belong here.
- **Not real-time build monitoring.** Watching the repo and interrupting with warnings is
  explicitly deferred (see §9, *Future*).
- **Not a replacement for Instagram's Saved folder.** Saving normally can continue in
  parallel; godmode does not need to be the only place things live.

---

## 4. User

Single user: Chintan. Computer Engineering student, builds side projects with AI coding
tools, saves dev-knowledge reels habitually, works on a MacBook Pro M4.

**Volume:** under 100 reels currently saved; a few new ones per week. This is small, and
the design should exploit that — optimise for **extraction quality over throughput**, and
avoid infrastructure that only pays off at scale.

---

## 5. The three knowledge categories

This is the central product insight. godmode holds three kinds of knowledge that behave
differently, come from different places, and must be handled differently.

### Category 1 — Technical rules
*Rate limiters, CI/CD, idempotency keys, custom 404s, DB indexing, error handling.*

- **Source:** primarily the saved reels.
- **Shape:** objective, checkable, reusable. `"Add a rate limiter to every public write
  endpoint — token bucket, return 429 with Retry-After."`
- **Difficulty:** easy. This is the category the pipeline handles best.

### Category 2 — Claude / tooling operating knowledge
*Which skills to invoke when, what belongs in a CLAUDE.md, when to use subagents vs. one
long thread, how to structure a prompt for a refactor vs. a greenfield build.*

- **Source:** mostly **Chintan himself**, learned mid-build. Some reels touch it.
- **Shape:** workflow rules. `"Give Claude the schema before asking for the query."`
- **Difficulty:** the *capture* is the hard part. This category stays empty unless it is
  effortless to record a lesson the second it is learned — hence the in-editor slash
  command (§6.4).

### Category 3 — Taste
*Spacing, type scale, motion, empty states, loading states, error copy, the polish that
separates a good product from an average one.*

- **Source:** **visual references** — screenshots and URLs of things Chintan admires,
  captured with a short note on *why*. Design reels contribute, but weakly.
- **Shape:** concrete and specific, tied to examples. Rules alone do not transfer taste;
  `"use good spacing"` is worthless. The reference image is the payload.
- **Difficulty:** highest. This is the category Chintan cares most about and the one
  reels are worst at teaching, which is why capture must be extended beyond video.

> **Design consequence:** the knowledge store must tag every entry with its category, and
> the taste category must be able to carry **image attachments** through to the generated
> skill, not just text.

---

## 6. Capture channels

All channels normalise to **one `sources` row plus one queued job**, so that adding a
channel later never changes the pipeline behind it. Most channels reach that through a
single `POST /ingest`; the Instagram webhook and the backfill importer have their own
entry points (they have channel-specific parsing and timing constraints) but call the same
internal normalisation function.

### 6.1 Instagram DM to a bot account — *primary, real-time*

Chintan shares a reel to a second Instagram account he owns (`@godmode.brain`, a
Professional account). Meta's Messaging webhook delivers it as an `ig_reel` attachment
containing a direct media `url`, a `title`, and a `reel_video_id`.

- Fully within Instagram's terms. No scraping, no cookies, no account risk.
- Hands over the **actual video file** — no download-from-permalink step required.
- The bot replies in the DM with what it extracted, giving an immediate correction loop.
- **No App Review needed.** Standard Access covers messaging with accounts that have a role
  on the app, and both accounts are Chintan's.

**Setup constraint — verified and non-obvious:** the Meta app **must be flipped to Live
mode** in the App Dashboard. Instagram does *not* deliver webhook notifications to apps in
Development mode. Live mode may require **business verification**, which has unbounded
external latency — so this must be started early, not discovered during the build.
(App Review and Live mode are different things; only the former is avoidable here.)

**Cost:** a behaviour change — Share instead of Save. Running both in parallel for a few
weeks is expected while the habit forms.

**Constraint:** the media URL is short-lived. It must be downloaded on webhook receipt,
not queued for later.

**Open risk — non-reel posts are not covered by the verified path.** The saved content is
a *mix*: talking-head explainers, text-on-screen slide reels, screen recordings, **and
carousels / infographics**. Only reels are documented (`ig_reel` / `reel`). The webhook's
documented attachment types are `image`, `audio`, `video`, `file`, `reel`, `ig_reel`,
`fallback`, `template` — with no stated behaviour for a shared feed post or multi-image
carousel, and an explicit warning that *"for unsupported shares… a fallback with no
payload might be sent."*

**Consequence:** a shared carousel may arrive with nothing usable attached. The fallback is
to capture its permalink and fetch it through the local worker — which means the local
worker is **not backfill-only**, and carousel support depends on the one grey-area
component. This must be settled by an empirical spike before P1 is designed (see
Requirements F1.0).

### 6.2 Meta data export — *backfill*

Instagram Settings → Accounts Center → Your information and permissions → Download your
information → **Saved** only, **JSON** format. Produces `saved_posts.json` containing a
permalink and timestamp per saved item.

This recovers the reels **already saved** — which forward capture will never see, and
which arguably hold more value than anything captured from today onward.

- Yields **permalinks only**, so a media-fetch step is required (see Architecture §4).
- Manual, email-delivered, hours to days of latency. Acceptable — it runs once at launch
  and quarterly thereafter.
- Expect **5–15% loss** to deleted or now-private posts. Record as `unavailable` and
  continue; never fail the batch.

### 6.3 iOS Shortcut

A "→ godmode" entry in the share sheet on iPhone and Mac. Captures URL + optional note
for anything that is not Instagram — YouTube Shorts, X threads, blog posts, GitHub repos.

### 6.4 Claude Code slash command — *Category 2 capture*

A command shipped inside the generated plugin (name TBD by Chintan) that captures a
lesson without leaving the editor:

```
/<name> remember: always give Claude the schema before asking for the query
```

This exists because Category 2 knowledge is generated **during** a build and evaporates
within minutes. Any capture path requiring a context switch will not be used.

Implemented as a thin command that calls a `capture_note` tool on the godmode MCP server,
which is already connected — so no separate auth or HTTP plumbing.

### 6.5 Browser extension — *Category 3 capture*

A "Send to godmode" button in desktop Chrome. Sends URL, page title, selected text, and
— critically — **a screenshot plus a why-note**. This is the primary intake for taste.

---

## 7. Processing requirements

1. **Extraction** — a multimodal LLM processes the whole video (frames + audio) in one
   pass and returns a structured reading: summary, topics, and candidate claims. Chosen
   over a transcript+OCR pipeline because at a few items per week the higher per-item cost
   is irrelevant, and it is dramatically less code to build and maintain.

   **The content mix makes this choice load-bearing, not just convenient.** The saved
   material spans four shapes, and no single cheaper method covers them:

   | Shape | Why transcript-only fails |
   |---|---|
   | Talking-head explainer | — (transcript alone would suffice) |
   | Text-on-screen / slide-style | Music-only audio; **all** content is on-screen |
   | Screen recording / code walkthrough | Content is rendered code; needs dense frame sampling |
   | Carousel / infographic | **Not video at all** — separate extraction path |

   Extraction must therefore **route by source kind**, not assume video. Carousels go
   through an image-sequence path; screen recordings need denser sampling than a
   talking-head reel to avoid missing code that is on screen only briefly.
2. **Atomisation** — each source yields 1–5 standalone claims. A claim must be actionable
   on its own, with no reference back to the reel it came from.
3. **Deduplication and merge** — every new claim is checked against existing knowledge.
   Near-duplicates **merge into and strengthen** the existing entry (adding evidence and
   any new specifics) rather than creating a second entry. This is what makes godmode a
   brain rather than a pile.
4. **Categorisation** — every entry is tagged Technical / Tooling / Taste, plus domain
   tags (auth, payments, frontend, deploy, …).
5. **Human review** — extraction will sometimes be wrong. Every entry must be
   correctable, and rejecting an entry must prevent it from being re-created by the same
   source later.

---

## 8. Output requirements

godmode's deliverable is a **generated Claude Code plugin**, rebuilt whenever the
knowledge base changes materially.

```
godmode-plugin/
├── .claude-plugin/plugin.json
├── skills/
│   ├── godmode-core/SKILL.md       # ~40 lines. Broad trigger — the "always-on" layer
│   ├── api-hardening/SKILL.md      # loads when writing endpoints
│   ├── shipping-checklist/SKILL.md # loads before deploy
│   ├── ui-polish/
│   │   ├── SKILL.md                # loads when touching frontend
│   │   └── references/*.png        # actual reference images (Category 3)
│   └── claude-workflow/SKILL.md    # loads when planning a build
├── commands/<capture-command>.md
└── .mcp.json                       # godmode MCP server
```

> **Verified constraint — no `CLAUDE.md` inside the plugin.** Claude Code's plugin
> reference states plainly: *"A `CLAUDE.md` file at the plugin root is not loaded as
> project context. Plugins contribute context through skills, agents, and hooks rather
> than CLAUDE.md."* An earlier draft of this design put the always-on rules in a plugin
> `CLAUDE.md`; that would have silently done nothing.
>
> **The always-on layer is therefore delivered two ways:**
> 1. **`skills/godmode-core/SKILL.md`** — a deliberately broad trigger description
>    ("use at the start of any coding task, when planning a build, or before shipping").
>    Model-invoked, so *near*-always-on rather than guaranteed.
> 2. **Optionally, a generated block written into `~/.claude/CLAUDE.md`** — outside the
>    plugin, delimited by markers so it can be rewritten idempotently. This *is*
>    genuinely always-on, at the cost of living outside the plugin's update mechanism.

**Why a plugin and not one rules file:** at ~100 reels the knowledge base will hold
several hundred rules. Concatenating them into one file would consume the context window
before any code is written, and long rules files get skimmed rather than followed. Skills
solve exactly this — each carries a description telling Claude *when* to load it, which is
precisely the "what skills and files to use when" requirement.

**Output requirements:**

| # | Requirement |
|---|---|
| O1 | The always-on core stays under ~40 lines — universal, always-true rules only |
| O2 | Each generated skill has a trigger description precise enough to fire reliably and not otherwise |
| O3 | The taste skill ships **reference images**, not just prose |
| O4 | An MCP server answers ad-hoc queries mid-build (`what do I know about auth?`) |
| O5 | The capture command is available in every project the plugin is installed in |
| O6 | Regeneration is one command, and updating is a normal plugin update |
| O7 | Every rule is traceable back to the source(s) that produced it |

---

## 9. Scope and phasing

> **Execution note.** `docs/ROADMAP.md` is the machine-readable build protocol derived from
> this table — task IDs, dependency graph, gates and a status ledger. This table is the
> *intent*; the roadmap is the *order of operations*. Keep them consistent.

| Phase | Deliverable | Rationale |
|---|---|---|
| **P−1** | **Validation spike — five real reels through a throwaway extraction script** | Added after the fact. D2 (multimodal extraction produces usable claims) is the riskiest assumption in this document and needs **no infrastructure** to test. Building P0 first defers the discovery by weeks and risks scaffolding a hollow centre |
| **P0** | Foundations — data model, ingest API, job queue, deploy skeleton | Everything depends on this |
| **P1** | Forward capture — IG DM webhook → extraction → claims | Proves the pipeline end-to-end on a handful of new reels, cheaply |
| **P2** | Knowledge core — dedup, merge, categorisation, **minimal** review interface | The part that makes it a brain |
| **P3** | Backfill — data export import + local fetch worker | Deliberately **after** P2: running the whole corpus through an unproven extractor wastes it |
| **P4** | Output — plugin generation, MCP server, capture command | The payoff. Needs real knowledge mass from P3 to be worth anything |
| **P5** | Taste layer — visual capture, image-carrying design skill | Highest value, highest difficulty — build it once the machine works |
| **P6** | UI and polish — the full Next.js review app | A tool about not shipping average builds should not itself look average |
| **Future** | *(post-P6, explicitly deferred)* Repo monitoring via plugin hooks — "you added a public POST route and there's no rate limiter"; auto-mining lessons from Claude session transcripts; sharing the plugin with others | Highest magic, highest annoyance risk. Revisit only once trigger quality is proven |

**Ordering note:** P3 before P4 is a deliberate call. Generating a plugin from 15 reels
would produce something too thin to judge, and would give a false read on whether the
whole idea works.

**Phase gates.** Four points require a human decision and must not be inferred by an agent:

| Gate | Question | Blocks | Cost of getting it wrong |
|---|---|---|---|
| **G1** — after P−1 | Are the extracted claims actionable enough to act on? | All of P0 | Weeks of infrastructure around an idea that does not work |
| **G2** — after F1.0 | How do shared carousels actually arrive? | P1 handler design | Wrong cloud/local split; carousel capture silently unsupported |
| **G3** — before P2 migration | Which embedding model, and therefore which vector dimension? | P2 schema | A column rewrite, not a re-embed (D7) |
| **G4** — after P4 | Do the generated skills actually fire at the right moment? | Whether any of this pays off | The honest failure mode in §10 — a pipeline whose rules nobody reads |

**Parallelism.** The Meta track (M2 → F1.0 → webhook) has unbounded external latency. The
P−1 → P0 track has none. They are independent by design: `POST /ingest` is the seam, and the
webhook is one origin among several. **Never idle on Meta.**

---

## 10. Success criteria

godmode is working if, three months in:

- **S1** — Chintan captures reels through godmode by reflex, without deciding to.
- **S2** — The plugin is installed and active in every new project, without being thought about.
- **S3** — At least one production-class mistake (missing rate limiter, no error state,
  no CI) is caught by a godmode skill **before** it ships.
- **S4** — Merge is working: the entry count grows much more slowly than the source count.
  Sources doubling should not double entries.
- **S5** — A build shipped after godmode is visibly better than one shipped before, on the
  taste axis specifically.

**The honest failure mode to watch for:** godmode becomes a beautifully-engineered
pipeline that produces rules nobody reads, because the generated skills never fire at the
right moment. Skill trigger quality (O2) is the highest-risk requirement in this document
and should be tested early and deliberately.

---

## 11. Key risks

| Risk | Severity | Mitigation |
|---|---|---|
| Habit doesn't form — Share never replaces Save | **High** | Quarterly data-export backfill acts as a safety net; bot's DM reply provides a reward loop |
| Generated skills don't trigger at the right time | **High** | Test trigger descriptions explicitly in P4; keep skills few and broad before splitting them |
| Extraction produces generic, useless rules | Medium | Atomic-claim prompt demands specificity; review UI catches it; reject-and-remember prevents recurrence |
| Backfill fetch breaks (Instagram extractor churn) | Medium | Isolated to one local worker; failures are per-item, not fatal; 5–15% loss accepted up front |
| **Live-mode / business verification blocks the webhook** | **High** | Unbounded external latency and the hard dependency for P1. Start it before any code is written (see M2) |
| **Shared carousels arrive with no usable payload** | **Medium-High** | Undocumented behaviour; possible `fallback` with no payload. Settle by spike (F1.0) before designing P1. Fallback path is permalink → local worker, which extends the grey-area component's role |
| Taste knowledge stays too vague to be useful | Medium | Reference images ship with the skill; require a why-note at capture time |
| Rules accumulate and contradict each other | Low (grows) | Merge step must detect conflict and surface it for a decision, not silently keep both |

---

## 12. Open questions

- **Q1** — Name of the Claude Code capture command (Chintan to decide).
- **Q2** — Should godmode ever *remove* a rule that turns out to be outdated advice, or
  only supersede it? (Leaning: supersede with a version history, never hard delete.)
- **Q3** — How aggressive should merging be? Too aggressive and distinct rules collapse
  into mush; too conservative and it becomes the pile it was meant to replace. Needs
  tuning against the real backfill corpus in P3.
</content>
