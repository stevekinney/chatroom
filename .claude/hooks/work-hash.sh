#!/usr/bin/env bash
# Shared definition of "the current body of work" and its hash.
#
# Sourced by review-board-gate.sh and review-board-signoff.sh so the two cannot
# drift. If they computed the hash differently, a sign-off would never satisfy
# the gate and the board would be unpassable.

# Paths whose change constitutes a reviewable body of work. Documentation-only
# edits do not convene a four-agent board; a code or test change does.
WORK_SCOPE=(src scripts package.json bun.lock playwright.config.ts vite.config.ts)

# Echoes the hash, or nothing if there is no substantive work in flight.
compute_work_hash() {
  local uncommitted unpushed upstream

  uncommitted=$(git status --porcelain -- "${WORK_SCOPE[@]}" 2>/dev/null)
  if upstream=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null); then
    unpushed=$(git log --oneline "${upstream}..HEAD" -- "${WORK_SCOPE[@]}" 2>/dev/null)
  else
    unpushed=""
  fi

  [ -z "$uncommitted$unpushed" ] && return 0

  {
    printf '%s\n' "$uncommitted"
    printf '%s\n' "$unpushed"
    git diff HEAD -- "${WORK_SCOPE[@]}" 2>/dev/null
    # Untracked files are part of the work, so hash their contents too.
    git status --porcelain -- "${WORK_SCOPE[@]}" 2>/dev/null |
      sed -n 's/^?? //p' |
      while IFS= read -r f; do
        [ -f "$f" ] && { printf '%s\n' "$f"; cat -- "$f"; }
      done
  } 2>/dev/null | shasum -a 256 2>/dev/null | cut -d' ' -f1
}

REVIEW_BOARD=(test-integrity-auditor harness-skeptic contract-auditor a11y-ssr-auditor)
SIGNOFF_DIR="${TMPDIR:-/tmp}/claude-review-board"
