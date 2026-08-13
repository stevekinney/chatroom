#!/usr/bin/env bash
# Shared definition of "the current body of work" and its hash.
#
# Sourced by review-board-gate.sh and review-board-signoff.sh so the two cannot
# drift. If they computed the hash differently, a sign-off would never satisfy
# the gate and the board would be unpassable.
#
# The baseline is the last commit the board cleared, NOT a remote tracking
# branch. This repo has no remote, so an "unpushed commits" definition made the
# gate dead code the moment work was committed — and committing is exactly what
# you do before declaring done. Work is measured from the last sign-off forward,
# which also means committing after a PASS does not invalidate it: the hash
# covers content, not whether that content has been committed yet.

# Paths whose change constitutes a reviewable body of work. Documentation-only
# edits do not convene a four-agent board; a code or test change does.
WORK_SCOPE=(src scripts package.json bun.lock playwright.config.ts vite.config.ts)

REVIEW_BOARD=(test-integrity-auditor harness-skeptic contract-auditor a11y-ssr-auditor)
SIGNOFF_DIR="${TMPDIR:-/tmp}/claude-review-board"

# Persisted in the repo rather than TMPDIR: committed-but-unreviewed work must
# still be blocked in a later session, and TMPDIR does not survive that.
LAST_CLEARED_FILE=".claude/.review-board-state/last-cleared"

# The commit the board last cleared. On first use this initializes to HEAD, so
# installing the gate does not retroactively demand review of existing history.
# Every commit made after that point is in scope.
work_baseline() {
  local baseline
  if [ -f "$LAST_CLEARED_FILE" ]; then
    baseline=$(cat "$LAST_CLEARED_FILE" 2>/dev/null)
    if git rev-parse --verify --quiet "${baseline}^{commit}" >/dev/null 2>&1; then
      printf '%s' "$baseline"
      return 0
    fi
  fi
  baseline=$(git rev-parse HEAD 2>/dev/null) || return 1
  mkdir -p "$(dirname "$LAST_CLEARED_FILE")" 2>/dev/null
  printf '%s\n' "$baseline" > "$LAST_CLEARED_FILE" 2>/dev/null
  printf '%s' "$baseline"
}

# Records that the board cleared through the current HEAD.
mark_cleared() {
  mkdir -p "$(dirname "$LAST_CLEARED_FILE")" 2>/dev/null
  git rev-parse HEAD > "$LAST_CLEARED_FILE" 2>/dev/null
}

# Echoes the hash, or nothing if there is no substantive work in flight.
compute_work_hash() {
  local baseline uncommitted committed
  baseline=$(work_baseline) || return 0
  [ -z "$baseline" ] && return 0

  uncommitted=$(git status --porcelain -- "${WORK_SCOPE[@]}" 2>/dev/null)
  committed=$(git log --oneline "${baseline}..HEAD" -- "${WORK_SCOPE[@]}" 2>/dev/null)
  [ -z "$uncommitted$committed" ] && return 0

  {
    # Content only, deliberately: `git diff <baseline>` is identical whether a
    # change is committed or still in the working tree, so committing after a
    # PASS does not invalidate it while editing does.
    git diff "$baseline" -- "${WORK_SCOPE[@]}" 2>/dev/null
    git status --porcelain -- "${WORK_SCOPE[@]}" 2>/dev/null |
      sed -n 's/^?? //p' |
      while IFS= read -r f; do
        [ -f "$f" ] && { printf '%s\n' "$f"; cat -- "$f"; }
      done
  } 2>/dev/null | shasum -a 256 2>/dev/null | cut -d' ' -f1
}
