# .sync

`manifest.tsv` records the SHA-256 of each synced doc at the moment of the last
sync — the **merge base** used to tell local edits from project edits.

Mode: **merge, ask on conflict.**

| Local vs base | Project vs base | Result |
|---|---|---|
| same | same | nothing to do |
| changed | same | local wins; pushed up to the project |
| same | changed | project wins; pulled down here |
| changed | changed | **conflict** — Cowork surfaces both and asks |

The manifest is gitignored: it is machine-local sync state, not shared history.
Git tracks *what the docs say*; the manifest tracks *what was last reconciled*.

Run `scripts/sync-check.sh` to see current drift.
