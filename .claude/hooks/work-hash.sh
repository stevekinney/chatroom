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

# Grounds on which work may be cleared WITHOUT convening the board, because
# four adversarial agents are disproportionate to it. A waiver is not a silent
# bypass: it names one of these, carries a written reason, and is recorded
# beside the sign-offs, so the judgement can be audited after the fact.
WAIVER_GROUNDS=(
  formatting-only
  comments-only
  revert-of-cleared
  generated-artifact
  advisor-approved
)

# Paths a waiver may never cover, however honestly the ground was chosen.
# Every ground makes a claim about the diff, and nothing verifies that claim, so
# a mistaken `formatting-only` on a component was a complete, silent bypass of
# the a11y and hydration review -- demonstrated with a `role="dialog"` and no
# focus trap clearing the gate under all five grounds. Anything with a rendered
# surface convenes the board; work confined to `.claude`, scripts, and config
# stays waivable, which is the proportionality the waiver exists for.
WAIVER_NEVER=(
  'src/'
  'static/'
  '.svelte'
  '.html'
  '.css'
)

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
  local head
  # Not `git rev-parse HEAD >file`: on an unborn HEAD that prints the literal
  # string "HEAD" to stdout and exits 128, writing a baseline that resolves to a
  # moving target -- which makes committing hide the work all over again.
  head=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
  [ -n "$head" ] || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  printf '%s\n' "$head" > "$LAST_CLEARED_FILE"
}

# Sets WORK_HASH and WORK_ERROR. An empty WORK_HASH means either "no work"
# (WORK_ERROR empty) or "could not evaluate" (WORK_ERROR set); callers check
# WORK_ERROR first. Call it plainly -- never as $(compute_work_hash).
compute_work_hash() {
  WORK_ERROR=""
  WORK_HASH=""
  local baseline root tmpidx diff extra real_index
  local -a status_bits

  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$root" ]; then WORK_ERROR="not inside a git work tree"; return 1; fi

  # Not $(work_baseline): its WORK_ERROR assignment must survive.
  work_baseline || return 1
  baseline="$WORK_BASELINE"

  # Index bits that hide modifications from both status and diff. `git ls-files -v`
  # marks assume-unchanged with a lowercase letter and skip-worktree with an
  # uppercase S specifically (all other uppercase letters are ordinary tracked
  # states: H, M, R, C, K, ?) -- matching all of `[a-z]` was silently blind to
  # skip-worktree, which is the cheaper of the two bits to set as a bypass.
  if git ls-files -v -- . 2>/dev/null | grep -qE '^([a-z]|S)'; then
    WORK_ERROR="assume-unchanged or skip-worktree bits are set on tracked files, which hides changes from this gate. Clear them with: git update-index --no-assume-unchanged <path> or git update-index --no-skip-worktree <path>"
    return 1
  fi

  # Ignore sources that live OUTSIDE the work tree hide new files with no tracked
  # evidence: `.gitignore` is in scope so adding a rule there is reviewable, but
  # these are not, so a path listed here is invisible in both directions.
  local exclude_file
  exclude_file=$(git rev-parse --git-path info/exclude 2>/dev/null)
  if [ -n "$exclude_file" ] && [ -f "$exclude_file" ] && grep -qE '^[[:space:]]*[^#[:space:]]' "$exclude_file" 2>/dev/null; then
    WORK_ERROR="\`.git/info/exclude\` has active rules. It hides files from this gate and is not itself reviewable, unlike .gitignore. Move the rules into .gitignore, or clear them."
    return 1
  fi
  if [ -n "$(git config --get core.excludesFile 2>/dev/null)" ]; then
    WORK_ERROR="\`core.excludesFile\` is set. It hides files from this gate and lives outside the repo, so neither the rule nor what it hides is reviewable. Unset it with: git config --unset core.excludesFile"
    return 1
  fi

  # A throwaway index so untracked files diff exactly like tracked ones. The
  # real index is never touched.
  tmpidx=$(mktemp 2>/dev/null) || { WORK_ERROR="could not create a temporary index"; return 1; }
  # Drop mktemp's zero-byte file: git rejects it as "index file smaller than
  # expected" and builds a valid one when the path is absent. In a LINKED
  # WORKTREE `${root}/.git` is a file rather than a directory, so the old
  # `${root}/.git/index` copy silently did nothing and left the empty file in
  # place, blocking permanently with no way to clear it -- in the workflow this
  # repo uses most. `--git-path` resolves correctly in both layouts.
  # Deliberately NOT seeded from the real index. Copying it carries the cached
  # stat data forward under a fresh mtime, which turns off git's racy-clean rule:
  # entries whose cached mtime is at or after the index's own mtime get
  # re-compared by content, and a new mtime puts every entry strictly in the past.
  # With whole-second stat granularity (Apple/Homebrew git has no nanosecond
  # support) any same-second, same-size, in-place edit then reads as clean and the
  # gate allows real unreviewed changes. Letting git build the index fresh costs a
  # full scan and buys correctness, which is the only thing this is for.
  rm -f "$tmpidx"
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

# Paths in the current body of work that a waiver may not cover. Prints one per
# line; empty output means the work is waivable. Fails closed: any state it
# cannot evaluate returns non-zero with WORK_ERROR set, and the caller must
# refuse the waiver rather than read the empty list as permission.
#
# Deliberately built from its own throwaway index rather than reusing the hash,
# because the hash is a digest and cannot be asked which files it covered.
waiver_forbidden_paths() {
  WORK_ERROR=""
  # Not `status`: zsh reserves it, and this file gets sourced interactively.
  local root baseline tmpidx names names_status p pattern
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$root" ]; then WORK_ERROR="not inside a git work tree"; return 1; fi

  # Not $(work_baseline): its WORK_ERROR assignment must survive.
  work_baseline || return 1
  baseline="$WORK_BASELINE"

  tmpidx=$(mktemp 2>/dev/null) || { WORK_ERROR="could not create a temporary index"; return 1; }
  rm -f "$tmpidx"
  local real_index
  real_index=$(git rev-parse --git-path index 2>/dev/null)
  if [ -n "$real_index" ] && [ -f "$real_index" ]; then cp "$real_index" "$tmpidx" 2>/dev/null || :; fi
  GIT_INDEX_FILE="$tmpidx" git add -A -N -- . "${WORK_DENY[@]}" >/dev/null 2>&1
  names=$(GIT_INDEX_FILE="$tmpidx" git diff --name-only "$baseline" -- . "${WORK_DENY[@]}" 2>/dev/null)
  names_status=$?
  rm -f "$tmpidx" 2>/dev/null
  if [ $names_status -ne 0 ]; then WORK_ERROR="could not list changed paths against the baseline"; return 1; fi

  # Branches and stashes too: a waiver covers the whole body of work, and work
  # parked elsewhere is part of it.
  if [ "$baseline" != "$EMPTY_TREE" ]; then
    while IFS= read -r tip; do
      [ -z "$tip" ] && continue
      git merge-base --is-ancestor "$tip" HEAD 2>/dev/null && continue
      names="${names}
$(git diff --name-only "$baseline" "$tip" -- . "${WORK_DENY[@]}" 2>/dev/null)"
    done <<< "$(git for-each-ref --format='%(objectname)' refs/heads 2>/dev/null)"
  fi

  while IFS= read -r p; do
    [ -z "$p" ] && continue
    for pattern in "${WAIVER_NEVER[@]}"; do
      case "$pattern" in
        */) case "$p" in "$pattern"*) printf '%s\n' "$p"; break ;; esac ;;
        *)  case "$p" in *"$pattern") printf '%s\n' "$p"; break ;; esac ;;
      esac
    done
  done <<< "$names"
}
