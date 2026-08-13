#!/usr/bin/env bash
# Shared definition of "the current body of work" and its hash.
#
# Sourced by review-board-gate.sh and review-board-signoff.sh so the two cannot
# drift. If they computed the hash differently, a sign-off would never satisfy
# the gate and the board would be unpassable.
#
# Design rules, each earned by an adversarial pass that broke an earlier version:
#
#   Fail closed. Any state this cannot evaluate is a BLOCK, never an allow. A
#   gate that cannot see the work must not clear it.
#
#   Scope is a denylist, not an allowlist. An allowlist of source directories
#   left everything else unreviewable, including this gate's own definition, so
#   `.claude/hooks` is explicitly in scope and neutering the board is reviewable
#   work like anything else.
#
#   Untracked content is hashed through a throwaway git index. Reading paths out
#   of `git status --porcelain` missed whole new directories (reported as one
#   entry) and quoted non-ASCII names, so a new feature could be signed off
#   sight unseen and rewritten afterwards.
#
#   The hashed stream is seeded with the repo root and baseline. An empty stream
#   used to hash to the SHA of "" — a constant that cleared that entire class of
#   work in every repo sharing a TMPDIR.

# Paths that do NOT constitute reviewable work. Everything else does, including
# all of `.claude` and `.gitignore` (adding an ignore rule hides source, so the
# rule change is itself work).
WORK_DENY=(
  ':(exclude)CLAUDE.md'
  ':(exclude)AGENTS.md'
  ':(exclude)README.md'
  ':(exclude)ROADMAP.md'
  ':(exclude)docs'
  ':(exclude).vscode'
  ':(exclude).claude/.review-board-state'
)

REVIEW_BOARD=(test-integrity-auditor harness-skeptic contract-auditor a11y-ssr-auditor)

# Kept beside the baseline rather than in TMPDIR: macOS reaps /var/folders, an
# unset TMPDIR silently relocates it, and a shared /tmp path let a sign-off from
# one repo clear work in another.
STATE_DIR=".claude/.review-board-state"
LAST_CLEARED_FILE="${STATE_DIR}/last-cleared"
SIGNOFF_DIR="${STATE_DIR}/signoffs"
NOTES_SENTINEL='--- notes (not parsed by the gate) ---'

# Git's empty tree, used as the baseline when HEAD is unborn so a freshly
# scaffolded project is gated rather than free.
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# Set by compute_work_hash. Callers read these directly and must NOT wrap the
# call in a command substitution: that runs it in a subshell, where assignments
# to these are discarded and every error silently reads as "no work".
WORK_ERROR=""
WORK_HASH=""

# Echoes the baseline, or sets WORK_ERROR. Never silently re-baselines: a
# missing or unresolvable baseline used to adopt HEAD, which declared all
# existing unreviewed work reviewed and made `rm -rf` the easiest bypass.
WORK_BASELINE=""
work_baseline() {
  WORK_BASELINE=""
  if ! git rev-parse HEAD >/dev/null 2>&1; then
    WORK_BASELINE="$EMPTY_TREE"
    return 0
  fi
  if [ ! -f "$LAST_CLEARED_FILE" ]; then
    WORK_ERROR="no review-board baseline recorded at ${LAST_CLEARED_FILE}. Establish one deliberately with: bash .claude/hooks/review-board-signoff.sh --initialize"
    return 1
  fi
  local baseline
  baseline=$(cat "$LAST_CLEARED_FILE" 2>/dev/null)
  if [ -z "$baseline" ] || ! git rev-parse --verify --quiet "${baseline}^{commit}" >/dev/null 2>&1; then
    WORK_ERROR="the recorded baseline (${baseline:-empty}) no longer resolves — history was rewritten or the state file was damaged. Re-establish it deliberately with: bash .claude/hooks/review-board-signoff.sh --initialize"
    return 1
  fi
  WORK_BASELINE="$baseline"
}

mark_cleared() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  git rev-parse HEAD > "$LAST_CLEARED_FILE" 2>/dev/null
}

# Sets WORK_HASH and WORK_ERROR. An empty WORK_HASH means either "no work"
# (WORK_ERROR empty) or "could not evaluate" (WORK_ERROR set); callers check
# WORK_ERROR first. Call it plainly -- never as $(compute_work_hash).
compute_work_hash() {
  WORK_ERROR=""
  WORK_HASH=""
  local baseline root tmpidx diff extra
  local -a status_bits

  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$root" ]; then WORK_ERROR="not inside a git work tree"; return 1; fi

  # Not $(work_baseline): its WORK_ERROR assignment must survive.
  work_baseline || return 1
  baseline="$WORK_BASELINE"

  # Index bits that hide modifications from both status and diff.
  if git ls-files -v -- . 2>/dev/null | grep -q '^[a-z]'; then
    WORK_ERROR="assume-unchanged or skip-worktree bits are set on tracked files, which hides changes from this gate. Clear them with: git update-index --no-assume-unchanged <path>"
    return 1
  fi

  # A throwaway index so untracked files diff exactly like tracked ones. The
  # real index is never touched.
  tmpidx=$(mktemp 2>/dev/null) || { WORK_ERROR="could not create a temporary index"; return 1; }
  if [ -f "${root}/.git/index" ]; then cp "${root}/.git/index" "$tmpidx" 2>/dev/null || :; fi
  GIT_INDEX_FILE="$tmpidx" git add -A -N -- . "${WORK_DENY[@]}" >/dev/null 2>&1
  diff=$(GIT_INDEX_FILE="$tmpidx" git diff "$baseline" -- . "${WORK_DENY[@]}" 2>/dev/null)
  local diff_status=$?
  rm -f "$tmpidx" 2>/dev/null
  if [ $diff_status -ne 0 ]; then WORK_ERROR="git diff against the baseline failed"; return 1; fi

  # Work parked elsewhere: branches carrying commits the current HEAD does not,
  # and stashes. Both let you stand somewhere clean and declare done.
  #
  # Compared by CONTENT, not by commit list. Hashing `git log` subjects made the
  # hash change the moment you committed, which invalidated a sign-off over a
  # change that was already reviewed -- the diff against the baseline is
  # identical whether work is committed or not, and that is the property worth
  # keeping.
  extra=""
  if [ "$baseline" != "$EMPTY_TREE" ]; then
    while IFS= read -r tip; do
      [ -z "$tip" ] && continue
      git merge-base --is-ancestor "$tip" HEAD 2>/dev/null && continue
      extra="${extra}$(git diff "$baseline" "$tip" -- . "${WORK_DENY[@]}" 2>/dev/null)"
    done <<< "$(git for-each-ref --format='%(objectname)' refs/heads 2>/dev/null)"
  fi
  local stashes
  stashes=$(git rev-list -g refs/stash 2>/dev/null | wc -l | tr -d ' ')
  [ "${stashes:-0}" != "0" ] && extra="${extra}
stashed-entries:${stashes}"

  if [ -z "$diff" ] && [ -z "$extra" ]; then return 0; fi

  # Seeded with identity so the stream is never empty and never portable
  # between repos or baselines.
  WORK_HASH=$(printf 'repo:%s\nbaseline:%s\n%s\n%s\n' "$root" "$baseline" "$diff" "$extra" |
    shasum -a 256 2>/dev/null | cut -d' ' -f1)
  if [ -z "$WORK_HASH" ]; then
    WORK_ERROR="could not hash the working set (is shasum available?)"
    return 1
  fi
}
