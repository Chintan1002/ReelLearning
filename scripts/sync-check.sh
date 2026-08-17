#!/usr/bin/env bash
# sync-check.sh — report drift between this folder and the Cowork project.
#
# Compares each doc's current SHA-256 against the merge base recorded in
# .sync/manifest.tsv at the last sync.
#
#   OK             unchanged since last sync
#   LOCAL-CHANGED  edited here; Cowork will pick this up on the next sync
#   UNTRACKED      new file; not yet synced to the project
#   MISSING        recorded in the manifest but gone from disk
#
# The project side can only be read by a Cowork session. Run a sync there to
# resolve; if BOTH sides moved, it will surface a conflict and ask.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MANIFEST=".sync/manifest.tsv"

if command -v sha256sum >/dev/null 2>&1; then
  hash_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "error: no sha256sum or shasum available" >&2; exit 1
fi

[ -f "$MANIFEST" ] || { echo "No manifest at $MANIFEST — never synced."; exit 0; }

echo "godmode sync status"
echo "base recorded: $(grep -m1 '^# synced_at' "$MANIFEST" | cut -d' ' -f3- || echo unknown)"
echo

drift=0

# Files recorded in the manifest
while IFS=$'\t' read -r path base _; do
  case "$path" in ''|\#*) continue ;; esac
  if [ ! -f "$path" ]; then
    printf '  %-14s %s\n' "MISSING" "$path"; drift=1; continue
  fi
  cur="$(hash_of "$path")"
  if [ "$cur" = "$base" ]; then
    printf '  %-14s %s\n' "OK" "$path"
  else
    printf '  %-14s %s\n' "LOCAL-CHANGED" "$path"; drift=1
  fi
done < "$MANIFEST"

# Docs on disk that the manifest has never seen
# (CLAUDE.md is deliberately local-only: editor context, not a project doc)
for f in docs/*.md; do
  [ -f "$f" ] || continue
  if ! cut -f1 "$MANIFEST" | grep -qxF "$f"; then
    printf '  %-14s %s\n' "UNTRACKED" "$f"; drift=1
  fi
done

echo
if [ "$drift" -eq 0 ]; then
  echo "In sync with the last recorded base."
else
  echo "Drift detected. Ask Cowork to sync; it will merge and flag any conflict."
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo
    echo "Note: uncommitted git changes. Commit before syncing for a clean diff."
  fi
fi
