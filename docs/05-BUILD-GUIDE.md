# godmode — how to start building

**Companion to** `docs/01-PRD.md` … `docs/04-REQUIREMENTS.md`
**Audience:** you, in Claude Code, starting from an empty repo.

---

## 0. The most important thing on this page

**Do not start with P0 infrastructure.**

The docs put P0 (data model, ingest API, job queue, deploy) first because everything
depends on it. That's true for *build order*, but it's the wrong place to spend your first
session — because P0 is the part **least likely to be wrong**, and the part that gets you
**zero** information about whether godmode works.

The riskiest assumption in the whole design is D2:

> *A multimodal LLM reading a whole reel produces claims good enough to be worth acting on.*

If that's false, the data model, the queue, the merge logic and the plugin generator are
all scaffolding around a hollow centre — and you'd find out in P1, after weeks of work.

Testing it needs **no infrastructure at all**: five reels, one script, twenty minutes of
reading the output. Do that first. Everything else in this guide assumes it passed.

---

## 1. Start the slow things now

Both of these have unbounded external latency and neither needs code. Do them before you
open the editor.

| Do now | Why |
|---|---|
| **Submit the Meta app for Live mode** | Business verification may be required. This is M2, and *nothing* in P1 is testable until it clears |
| **Request your Instagram data export** | Meta takes hours to days to deliver it. It's the input to P3 backfill, and you'll want it sitting on disk long before you need it |

Neither blocks WP0–WP2 below. That's deliberate — the plan is built so the Meta dependency
never idles you.

---

## 2. WP0 — Validate extraction (first session, no infrastructure)

**Goal:** find out whether the core idea works, before building anything around it.

Pick **five reels you've actually saved**, deliberately covering all four shapes:

1. a talking-head explainer
2. a text-on-screen / slide reel with music-only audio
3. a screen recording or code walkthrough
4. a carousel or infographic *(not video — this is the one most likely to break)*
5. one more of whichever you save most

### What to tell Claude Code

> Read `CLAUDE.md` and `docs/03-TECH-STACK.md` §5.1.
>
> Build a throwaway spike in `spikes/extraction/` — **not** production code, no framework,
> no database. A single script that:
>
> 1. takes an Instagram permalink,
> 2. downloads it with `yt-dlp` (video) or `gallery-dl` (carousel/image),
> 3. sends the whole media to a multimodal model with native video input,
> 4. returns JSON: `summary`, `topics[]`, `claims[]` where each claim is standalone and
>    actionable with no reference back to the reel,
> 5. writes the JSON next to the media.
>
> Use `uv` for dependencies. Keep it under ~150 lines. Two prompts — one for video, one for
> image sequences.
>
> Then run it against the five permalinks in `spikes/extraction/inputs.txt` and show me the
> raw JSON for each.

### What you are judging

Read all five outputs yourself. Do not skim.

| Question | If the answer is no |
|---|---|
| Are the claims **actionable standalone**, or do they need the reel for context? | The atomisation prompt needs work — fixable |
| Did the **slide reel** work despite music-only audio? | Sampling or prompt issue — fixable |
| Did the **screen recording** capture the actual code? | Increase frame density (Arch §5) — fixable |
| Did the **carousel** work at all? | Check whether `gallery-dl` fetched it; this is the fragile path |
| Would you **act** on these claims in a real build? | **Stop. Reconsider D2 before building anything.** |

The last question is the real one. Everything else is tuning.

**Also record:** actual cost per item, and how long `yt-dlp` / `gallery-dl` took. If the
fetchers fail on your own saved content now, they'll fail worse in P3.

**Commit the spike.** It becomes your test fixtures — the tech stack doc requires recording
real LLM responses as fixtures (§11), and these are the first ones.

---

## 3. WP1 — F1.0, the payload spike

**Runs the moment the Meta app goes Live.** Independent of WP0; do it whenever it unblocks.

> Set up a webhook receiver that logs the complete raw JSON body of every event to a file
> and returns 200. Nothing else — no parsing, no storage. Expose it with `cloudflared` or
> `ngrok`.

Then, by hand: share one of each shape into the bot — talking-head reel, slide reel, screen
recording, **carousel**, **regular feed post** — and read the payloads.

**Record for each:** the attachment `type`, whether usable media came through, whether a
permalink came through, and whether anything arrived at all.

**Why this is blocking:** if carousels arrive as a `fallback` with no payload, the local
worker stops being backfill-only and becomes a dependency of forward capture. That changes
P1's scope. Don't design around either outcome until you know.

Write the answer into `docs/02-ARCHITECTURE.md` §3.1 and delete the "unresolved" note.

---

## 4. WP2 — P0 foundations (safe to build in parallel)

Nothing here depends on Meta. Start it while waiting.

**Build in this order**, one commit per step:

1. **Repo skeleton** — `uv` project, FastAPI app, Docker Compose with Postgres + pgvector,
   Alembic wired up, `.env.example`, a passing `/health` test.
2. **Data model + first migration** — `sources`, `jobs`. Hold off on the `entries` vector
   column: D7 says the embedding model *and its dimension* must be chosen first, and
   changing it later is a column rewrite, not a re-embed.
3. **Job queue** — the `SELECT … FOR UPDATE SKIP LOCKED` worker loop, with retries and a
   parked state. Test it with fake jobs.
4. **`POST /ingest`** — accepts `{permalink, kind, origin, note?}`, creates a `source`,
   enqueues `fetch_media`. **This is the seam that matters** (see §5).
5. **Wire WP0's spike in** as the real `extract` stage, replacing the throwaway script but
   reusing its prompts and fixtures.

### Prompt shape for each step

> Read `CLAUDE.md` and `docs/04-REQUIREMENTS.md`. Implement **[requirement IDs]**.
>
> Use plan mode first — show me the plan before writing code.
>
> Constraints: no secrets in the repo; unknown/unhandled inputs park with their raw payload
> rather than being dropped; tests must not hit live APIs (use the fixtures in
> `spikes/extraction/`).
>
> Cite the requirement IDs in the commit message.

---

## 5. The seam that makes the Meta blocker harmless

Build the pipeline so **the webhook is just one origin among several**:

```
IG DM webhook  ─┐
iOS Shortcut   ─┤
Chrome ext     ─┼──►  POST /ingest  ──►  jobs  ──►  fetch → extract → atomise → …
MCP capture    ─┤
Manual CLI     ─┘
```

The webhook handler's only job is: parse Meta's payload → download inline (the URL expires)
→ call the same internal ingest function everything else calls.

**Consequence:** you can build, run and test the entire pipeline end to end today, with a
one-line CLI that posts a permalink to `/ingest`. When Meta finally goes Live, you're adding
an adapter to a working system rather than discovering the pipeline's problems and the
webhook's problems simultaneously.

Add the manual CLI ingest in WP2. It stays useful forever as the debugging entry point.

---

## 6. Setting up Claude Code for this repo

```bash
cd ~/Desktop/PROJECTS/"Ai Reel Learner"
claude
```

`CLAUDE.md` at the repo root loads automatically at launch. **Don't run `/init`** — it
regenerates CLAUDE.md from codebase analysis, and yours contains argued-out decisions that
code analysis cannot recover. If you ever do run it, diff before committing.

Worth setting up once:

- **Plan mode** for anything touching 3+ files or a migration. `Shift+Tab` before sending,
  or launch with `claude --permission-mode plan`.
- **`/permissions`** — run it in-session and approve `uv` and `pytest` commands so you're
  not clicking through prompts all day. Let the command write the config itself rather than
  hand-editing `.claude/settings.json`; the schema is easy to get subtly wrong.
- **`claude -c`** to resume the last session in this directory. This is a multi-week build;
  you'll use it constantly.
- Optionally a `.claude/commands/` entry for your repeated checks once you know what they
  are. Don't pre-build these — wait until you've repeated something three times.

Verify CLAUDE.md is actually loading before you trust it: ask *"what are the hard
constraints on this project?"* in a fresh session. If it can't name the short-lived media
URL rule, it isn't loading.

---

## 7. Traps specific to this build

| Trap | Guard |
|---|---|
| **Deferring the media download** in the webhook because "async is cleaner" | The CDN URL expires. Inline is a correctness requirement, not a style choice |
| **Choosing the embedding model late** | `vector(N)` is fixed at DDL time. Decide in P2 *before* the migration or eat a column rewrite (D7) |
| **Building the pretty review UI early** | P2 needs only the Supabase table view. The Next.js app is P6 — it's the reward, not the task |
| **Generating the plugin before P3** | 15 reels produces something too thin to judge, and gives a false read on the whole idea |
| **Letting the local worker creep into the critical path** | `yt-dlp`/`gallery-dl` break periodically. Isolate them; never let their failure stop forward capture |
| **Tests that hit live model APIs** | They get slow and expensive, then quietly stop being run. Fixture from day one |
| **Silently dropping an unrecognised input** | The one unacceptable failure mode. Park it with the raw payload |

---

## 8. Realistic first week

| Session | Work | Depends on |
|---|---|---|
| 1 | Submit Meta app; request data export; **WP0 extraction spike** | Nothing |
| 2 | Read the WP0 output properly. Tune prompts, or stop and rethink D2 | Session 1 |
| 3 | WP2 steps 1–2 — skeleton, Compose, data model, first migration | Nothing |
| 4 | WP2 step 3 — job queue with retries and parking | Session 3 |
| 5 | WP2 steps 4–5 — `/ingest` + CLI, wire the spike in as `extract` | Sessions 2, 4 |
| *when Meta clears* | **WP1 payload spike**, then the webhook adapter | M2 |

At the end of that you can put a permalink in one end and get structured claims out the
other, with no Meta dependency and no guessing about whether extraction works.

That's the whole system's spine. Everything after it — merge, review, backfill, plugin
generation — hangs off a thing you've already seen work.

---

## 9. When the docs and reality disagree

They will. When it happens, **update the doc in the same commit as the code**. A stale spec
is worse than no spec, and these docs are the reason Claude Code makes good decisions in
this repo.

Then run `./scripts/sync-check.sh` and ask Cowork to sync, so the project copy doesn't drift.
