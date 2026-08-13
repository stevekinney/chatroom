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
#   `.claude` is in scope except its state directory and settings.local.json.
#   `.claude/hooks` is explicitly in scope. That does NOT mean neutering the
#   board is caught -- the gate sources this file before it computes scope, so a
#   self-excluding edit hides itself. See CLAUDE.md; a Stop hook cannot police
#   its own disablement, and pretending otherwise is worse than saying so.
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
# `.gitignore` (adding an ignore rule hides source, so the rule change is itself
# work) and `.claude` -- except its state directory, excluded just below, and
# `.claude/settings.local.json`, exempted via ARTIFACT_NAMES because Claude Code
# rewrites it on a permission grant.
WORK_DENY=(
  ':(exclude)CLAUDE.md'
  ':(exclude)AGENTS.md'
  ':(exclude)README.md'
  ':(exclude)ROADMAP.md'
  # NOT docs/ or .vscode/: a relative import or import.meta.glob resolves into
  # them, so excluding them made them a permanent home for unreviewed components
  # -- one board round on the import line, then everything after it was free.
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
# surface convenes the board, as does the config that decides one -- see the
# entries below. Work confined to `.claude` and `scripts` stays waivable, which
# is the proportionality the waiver exists for.
WAIVER_NEVER=(
  'src/'
  'static/'
  '.svelte'
  '.html'
  '.css'
  # Build config decides what SSRs and how it hydrates -- this repo has no
  # svelte.config.js, so vite.config.ts is where the sveltekit() plugin lives.
  # `--grounds formatting-only` cleared a rewrite setting `ssr.noExternal` and
  # nulling the adapter, which waives the exact review the waiver protects.
  'vite.config.ts'
  'svelte.config.js'
  'postcss.config.cjs'
  'tailwind.config.ts'
  # package.json pins the @lostgradient/* versions, so a `formatting-only` waiver
  # on a chat bump changed every ARIA attribute and every line of SSR output with
  # no board -- strictly upstream of the four config files above. The symlink
  # guard already treated it as render-deciding; the waiver did not.
  'package.json'
  'bun.lock'
)

# Build artifacts. `git status --ignored=matching -- ':(exclude)node_modules'`
# does NOT filter these: a collapsed ignored-directory entry is reported whole
# regardless of the pathspec, verified against `coverage/` and `node_modules/`
# both bare and as `/**`. So the exclusion the enumeration thought it had was
# inert, and the bound has to be applied to the paths themselves.
ARTIFACT_DIRS=(
  node_modules .svelte-kit dist build test-results playwright-report .turbo
  coverage .nyc_output .cache .next .direnv .output .vercel .netlify .wrangler
)

# Machine noise that is not work. `.DS_Store` changes when Finder opens a folder,
# and `.claude/settings.local.json` is rewritten by Claude Code on a permission
# grant -- so hashing them let the gate invalidate its own sign-off through an
# action it provoked, and demand a four-agent board on a Finder side effect.
ARTIFACT_NAMES=(.DS_Store Thumbs.db .localized .claude/settings.local.json)

# True when an ignore rule came from OUTSIDE the work tree. Written out three
# times before this existed and ordered correctly twice -- an absolute
# `core.excludesFile = ~/.gitignore` also ends in `/.gitignore`, so an in-tree
# arm placed first silently swallows the commonest external source. Git reports
# in-tree sources relative to the work tree, so a leading `/` decides. One
# function, so the ordering can only be got wrong once.
ignore_source_is_external() {
  local src
  src=$(git check-ignore -v -- "$1" 2>/dev/null | cut -d: -f1)
  case "$src" in
    '') return 1 ;;
    /*) return 0 ;;
    .gitignore|*/.gitignore) return 1 ;;
    *) return 0 ;;
  esac
}

# Every file inside an ignored directory that counts as work, one path per line.
# THE ONE WALK. There used to be four byte-identical `find` invocations whose
# `-prune` clause had to stay in agreement with `is_artifact`, unenforced -- the
# positional bug recurred three times that way. Here `-prune` is demoted to
# unconditionally-safe fast paths and every keep/drop answer comes from
# `is_artifact`, so the two rules cannot disagree because only one is asked.
#
# `-L` because the walk stopped one indirection short: a symlinked subdirectory
# inside an ignored directory yielded `-type l`, never `-type f`, so a component
# behind `tmp/parts -> /outside` was invisible from the first round. `-L` with a
# depth bound follows it without chasing cycles.
#
# Truncation past the cap travels as a terminal SENTINEL LINE, not a variable:
# every call site invokes this inside `$( )`, so stdout is the only channel out.
# An earlier version set a variable and was silently discarded -- the seventh
# instance of that trap in this file, and that one turned the bound into a
# fail-open. compute_work_hash checks for the sentinel in the MAIN shell, before
# the enumeration subshell, which is the only place WORK_ERROR survives.
WALK_HIDDEN_CAP=750
WALK_TRUNCATED_SENTINEL='__WALK_TRUNCATED__'
walk_hidden_dir() {
  local root_dir="$1" count=0 p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    is_artifact "$p" && continue
    count=$((count + 1))
    # A terminal sentinel LINE, not a variable: this runs inside `$( )` at every
    # call site, so stdout is the only channel out. Six separate bugs in this
    # file came from smuggling a non-filename property through it or re-deriving
    # it in the caller; the sentinel is that property travelling as data.
    if [ "$count" -gt "$WALK_HIDDEN_CAP" ]; then
      printf '%s\n' "$WALK_TRUNCATED_SENTINEL"
      return 0
    fi
    printf '%s\n' "$p"
  done <<< "$(find -L "$root_dir" -maxdepth 12 \
    \( -path '*/.git' -o \( \( -name node_modules -o -name .svelte-kit \) \
         ! -path 'src/*' ! -path 'static/*' ! -path '*/src/*' ! -path '*/static/*' \) \) -prune -o \
    -type f -print 2>/dev/null | LC_ALL=C sort)"
}

# True for a path inside a build artifact directory. A single left-to-right
# SEGMENT SCAN, first match wins: an artifact segment decides unless a `src` or
# `static` segment came first. Two earlier versions used two lists ordered
# opposite ways and produced the same ordering bug twice -- name-matching at any
# depth hid `src/routes/build/+page.svelte`, a route SvelteKit compiles, while
# anchoring at the path start missed `coverage/lcov-report/src/` and hashed 3000
# Istanbul files at 7s. One scan makes the hazard structural rather than per-list,
# so a future ARTIFACT_DIRS entry is safe by construction.
is_artifact() {
  local p="$1" seg d n
  # Left to right: the FIRST segment matching either list decides. An artifact
  # segment wins unless a rendered root came first.
  #   src/routes/build/x        -> keep   (src first)
  #   coverage/lcov/src/a.html  -> drop   (coverage first; Istanbul's own layout,
  #                                        which the old order hashed at 7s)
  #   .claude/worktrees/wt/src/ -> keep   (no artifact segment)
  local IFS=/
  for seg in $p; do
    [ -z "$seg" ] && continue
    case "$seg" in src|static) return 1 ;; esac
    for d in "${ARTIFACT_DIRS[@]}"; do
      [ "$seg" = "$d" ] && return 0
    done
  done
  # Basename-only noise, checked last so it can never shadow a rendered root.
  for n in "${ARTIFACT_NAMES[@]}"; do
    case "$n" in
      */*) [ "$p" = "$n" ] && return 0 ;;
      *)   case "$p" in "$n"|*/"$n") return 0 ;; esac ;;
    esac
  done
  return 1
}

# Source that either renders or decides what renders. The DECISION predicate for
# an ignored directory -- distinct from is_hashable (a blob denylist, too broad:
# a `.txt` would flip the whole directory and break the in-tree carve-out) and
# from renders() (a waiver question, whose only non-src/static arms are
# .svelte/.html/.css, which left `.ts`/`.js`/`.json` inside a hidden directory
# invisible -- confirmed shipped by a real vite build).
IS_SOURCE_EXT=(
  .svelte .html .css .scss .sass .less .styl .svx
  .ts .js .mjs .cjs .mts .cts .jsx .tsx .vue .json .svg
)
is_source() {
  local p="$1" e
  for e in "${IS_SOURCE_EXT[@]}"; do
    case "$p" in *"$e") return 0 ;; esac
  done
  return 1
}

# File types whose contents must reach the hash when something hides them.
# Deliberately NOT renders(): that predicate answers "may a waiver cover this",
# where the `src/`/`static/` prefix arms carry the load, so reusing it here left
# only the extension arms and silently dropped every `+page.ts`, `+page.server.ts`
# and `hooks.client.ts` inside a hidden directory -- load functions being the
# single commonest source of a hydration mismatch.
# A DENYLIST, matching this file's stated scope rule. The first version was an
# allowlist of extensions, which is the mistake the header warns about: `.scss`,
# `.mts`, `.jsx`, `.tsx` and `.vue` under a hidden `src/` all hashed to nothing
# and the gate exited 0 on them. Anything not obviously an opaque blob counts.
UNHASHABLE_EXT=(
  .png .jpg .jpeg .gif .webp .avif .ico .svgz .pdf .zip .gz .tgz .bz2 .xz .7z
  .woff .woff2 .ttf .otf .eot .mp4 .webm .mov .mp3 .wav .wasm .node .so .dylib
  .map .lock .bin .class .jar .pyc
)
is_hashable() {
  local p="$1" e
  for e in "${UNHASHABLE_EXT[@]}"; do
    case "$p" in *"$e") return 1 ;; esac
  done
  return 0
}

# True when a path reaches the browser OR decides what does -- WAIVER_NEVER now
# includes package.json and bun.lock, which pin the component versions and so are
# upstream of every rendered surface without rendering anything themselves. Used both to decide what a waiver may
# never cover and to decide which ignored paths must be hashed regardless of
# which ignore file hides them.
renders() {
  local p="$1" pattern
  for pattern in "${WAIVER_NEVER[@]}"; do
    case "$pattern" in
      */) case "$p" in "$pattern"*) return 0 ;; esac ;;
      *)  case "$p" in *"$pattern") return 0 ;; esac ;;
    esac
  done
  return 1
}

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
  if [ ! -f "$LAST_CLEARED_FILE" ]; then WORK_BASELINE=$(git rev-parse HEAD); return 0; fi
  if false; then
    WORK_ERROR="no review-board baseline recorded at ${LAST_CLEARED_FILE}. Establish one deliberately with: bash .claude/hooks/review-board-signoff.sh --initialize -- which itself refuses if sign-offs already exist on disk, since that means the baseline was deleted rather than never written. In that case restore the baseline file -- waiving does not work either, since it resolves the same baseline first."
    return 1
  fi
  local baseline
  baseline=$(cat "$LAST_CLEARED_FILE" 2>/dev/null)
  if [ -z "$baseline" ] || ! git rev-parse --verify --quiet "${baseline}^{commit}" >/dev/null 2>&1; then
    WORK_ERROR="the recorded baseline (${baseline:-empty}) no longer resolves — history was rewritten or the state file was damaged. Restore it to a commit that resolves. --initialize refuses here if sign-offs already exist, since that means this repo was gated and the file was damaged rather than never written."
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

  # The state directory must not be inside the hashed set. When an external
  # ignore rule put it there, a full four-PASS sign-off printed "cleared" and the
  # gate blocked anyway -- and every retry wrote two more signoff files, moving
  # the hash further from the one just approved. Livelock with no way out; this
  # turns that class into a message someone can act on.
  if [ -d "$STATE_DIR" ] && git check-ignore -q -- "$STATE_DIR" 2>/dev/null; then
    if ignore_source_is_external "$STATE_DIR"; then
      WORK_ERROR="${STATE_DIR} is hidden by an ignore source outside the work tree, which would make every sign-off invalidate itself. Move that rule into .gitignore, or stop ignoring the state directory."
      return 1
    fi
  fi

  # Two more places work hides that this cannot enumerate, so it refuses rather
  # than measuring less than it claims -- the same posture the stash guard takes.
  #
  # `-c core.fsmonitor=false` on both probes below: fsmonitor answers "is this
  # dirty" from a daemon's event stream, so a stale or lying one reports clean.
  #
  # A LINKED WORKTREE's uncommitted changes are invisible from the main
  # checkout: commit them and the branch tip shows up in the ref sweep, but the
  # uncommitted window is exactly when you stop and declare done, and CLAUDE.md
  # promotes worktrees as the normal workflow.
  local dirty_wt
  dirty_wt=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' |
    while IFS= read -r wt; do
      [ "$wt" = "$root" ] && continue
      [ -d "$wt" ] || continue
      [ -n "$(git -C "$wt" -c core.fsmonitor=false status --porcelain 2>/dev/null)" ] && { printf '%s (uncommitted)\n' "$wt"; continue; }
      # Detached: its HEAD is per-worktree and lives outside refs/, so committing
      # there does NOT make the work visible to the ref sweep. One flag away from
      # the documented workflow.
      git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1 || printf '%s (detached HEAD)\n' "$wt"
    done)
  if [ -n "$dirty_wt" ]; then
    WORK_ERROR="a linked worktree holds work this gate cannot see: $(printf '%s' "$dirty_wt" | tr '\n' ' '). Commit them there, or clean it, so the work is measurable."
    return 1
  fi

  # A DIRTY SUBMODULE or embedded repo. Keyed on GITLINKS, not on `.gitmodules`:
  # an embedded `git init` under `src/` produces a 160000 entry with no
  # `.gitmodules` at all, `git submodule foreach` reads that file, so the whole
  # check was skipped -- and `rm .gitmodules` turned it off in one command. The
  # gitlink diff saturates at `-dirty`, so content changes behind it are free.
  local gitlinks dirty_sub
  gitlinks=$(git ls-files -s -- . 2>/dev/null | awk '$1=="160000" {print substr($0, index($0,$4))}')
  if [ -n "$gitlinks" ]; then
    dirty_sub=$(printf '%s\n' "$gitlinks" | while IFS= read -r sm; do
      [ -z "$sm" ] && continue
      if [ ! -d "${root}/${sm}/.git" ] && [ ! -f "${root}/${sm}/.git" ]; then
        printf '%s (cannot enter)\n' "$sm"; continue
      fi
      [ -n "$(git -C "${root}/${sm}" -c core.fsmonitor=false status --porcelain 2>/dev/null)" ] && printf '%s\n' "$sm"
    done)
    if [ -n "$dirty_sub" ]; then
      WORK_ERROR="a submodule or embedded repository has changes this gate cannot see: $(printf '%s' "$dirty_sub" | tr '\n' ' '). Commit them inside it so the gitlink moves."
      return 1
    fi
  fi

  # A SYMLINK under a rendered root is stored as a blob holding its target path,
  # so the hash covers the 40-byte link and never the directory behind it. Point
  # one at a WORK_DENY path -- the four markdown files or the state dir -- get one
  # board round on the link
  # itself, and every later edit to the target is unreviewable while SvelteKit
  # still builds it. Refuse when the target escapes the reviewable set.
  local escaping
  escaping=$(
    # Escape set derived from WORK_DENY rather than hardcoded, so it cannot
    # drift from the list it mirrors. Today that means the four markdown files
    # and the state directory -- NOT `docs/`, which left WORK_DENY once the
    # bundler turned out to import from it, so a link there is not an escape.
    denied=""
    # Quoted: unquoted, bash reads `(` as pattern syntax and strips nothing.
    for __d in "${WORK_DENY[@]}"; do denied="${denied} ${__d#":(exclude)"}"; done
    # Build config at the repo root counts too: `svelte.config.js -> docs/cfg.js`
    # puts the routes directory, adapter and aliases behind a link into a
    # WORK_DENY path, and scanning only src/static missed it.
    { find src static -type l 2>/dev/null
      # Every name that decides what ships or how it hydrates. `.cjs` is the
      # required form for a PostCSS/Tailwind config in an ESM package and
      # rewrites every byte of CSS; package.json pins the @lostgradient/*
      # versions; and a link on the hooks themselves is a total bypass.
      find . -maxdepth 1 -type l \( -name '*.config.js' -o -name '*.config.ts' \
        -o -name '*.config.mjs' -o -name '*.config.cjs' -o -name '*.config.mts' \
        -o -name '*.config.cts' -o -name 'package.json' -o -name 'tsconfig*.json' \
        -o -name '.gitignore' \) 2>/dev/null | sed 's|^\./||'
      find .claude/hooks .claude/agents .claude/skills -maxdepth 2 -type l 2>/dev/null
    } | while IFS= read -r link; do
      # Resolve the WHOLE target. Taking `basename` of the readlink threw away
      # the target's directory, so a file symlink resolved to a nonexistent
      # sibling path that looked in-tree and was never flagged -- which left the
      # commonest shape, a `+page.svelte` that is a link, completely unguarded.
      linkdir=$(cd "$(dirname "$link")" 2>/dev/null && pwd -P) || continue
      raw=$(readlink "$link")
      case "$raw" in
        /*) abs="$raw" ;;
        *)  abs="${linkdir}/${raw}" ;;
      esac
      # Physical path of the target's parent, so `..` segments collapse.
      tdir=$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P)
      if [ -z "$tdir" ]; then printf '%s -> %s (unresolvable)\n' "$link" "$raw"; continue; fi
      target="${tdir}/$(basename "$abs")"
      case "$target" in
        "$root"/*)
          rel="${target#"$root"/}"
          for __d in $denied; do
            case "$rel" in
              "$__d"|"$__d"/*) printf '%s -> %s\n' "$link" "$rel"; break ;;
            esac
          done
          ;;
        *) printf '%s -> %s (outside the repo)\n' "$link" "$target" ;;
      esac
    done
  )
  if [ -n "$escaping" ]; then
    WORK_ERROR="a symlink under a rendered root or a build-config path points outside the reviewable set, so its contents can change without moving this hash: $(printf '%s' "$escaping" | tr '\n' '; '). Replace it with real files, or move the target inside the reviewable set."
    return 1
  fi

  # Files hidden by ignore sources OUTSIDE the work tree are hashed explicitly.
  # `.gitignore` is in scope, so a rule added there is reviewable; `.git/info/exclude`
  # and `core.excludesFile` are not, and a path listed in either is invisible to
  # `git add -A` with no artifact anywhere. Refusing to run whenever they exist was
  # the wrong call -- a global excludes file is a normal setup, and a gate that
  # blocks on it is one people disable. Seeing through them costs a bounded
  # enumeration and removes the hiding place instead.
  # Truncation check FIRST, in the main shell, because WORK_ERROR set inside the
  # enumeration below is discarded. Past the cap the gate used to go silent --
  # a 761-file ignored directory shipped an SSR'd route with no board -- so a
  # bound it cannot fully read is now a block that names the directory.
  local __hidden_dir __walk_out __trunc
  while IFS= read -r __hidden_dir; do
    [ -z "$__hidden_dir" ] && continue
    [ -d "$__hidden_dir" ] || continue
    # R5: `find`'s stderr is swallowed, so an UNREADABLE directory is
    # byte-identical on stdout to an empty one -- `chmod 000` was a one-command
    # fail-open. Probe readability explicitly before trusting an empty walk.
    if [ -n "$(find -L "$__hidden_dir" -mindepth 13 -print -quit 2>/dev/null)" ]; then
      WORK_ERROR="${__hidden_dir} nests deeper than this gate walks, so it cannot tell whether work hides down there. Flatten it, or move that content out of the work tree."
      return 1
    fi
    if [ -n "$(find -L "$__hidden_dir" -type d \( ! -perm -u+r -o ! -perm -u+x \) -print -quit 2>/dev/null)" ] ||
       [ -n "$(find -L "$__hidden_dir" -type f ! -perm -u+r -print -quit 2>/dev/null)" ] ||
       ! ls -- "$__hidden_dir" >/dev/null 2>&1; then
      WORK_ERROR="${__hidden_dir} cannot be read, so this gate cannot tell whether it hides work. Fix its permissions, or move it out of the work tree."
      return 1
    fi
    __walk_out=$(walk_hidden_dir "$__hidden_dir")
    # NO admission predicate here, deliberately. Deciding whether to verify the
    # bound by inspecting contents you have truncated is circular, and the
    # narrower predicate was applied to the directory PATH while the enumeration
    # below applies its own to the FILES -- so `tmp/` was checked by neither.
    case "$__walk_out" in *"$WALK_TRUNCATED_SENTINEL"*) __trunc=1 ;; *) __trunc="" ;; esac
    if [ -n "$__trunc" ]; then
      WORK_ERROR="${__hidden_dir} hides more than ${WALK_HIDDEN_CAP} files from this gate, which is more than it will read on every stop. Narrow the ignore rule, or move that content out of the work tree."
      return 1
    fi
  done <<< "$(git -c core.quotePath=false status --porcelain --ignored=matching -- . "${WORK_DENY[@]}" 2>/dev/null | sed -n 's/^!! //p')"

  local externally_hidden
  externally_hidden=$(
    git -c core.quotePath=false status --porcelain --ignored=matching -- . \
      "${WORK_DENY[@]}" \
      ':(exclude)node_modules' ':(exclude).svelte-kit' ':(exclude)dist' ':(exclude)build' \
      ':(exclude)test-results' ':(exclude)playwright-report' ':(exclude).turbo' 2>/dev/null |
      sed -n 's/^!! //p' |
      while IFS= read -r f; do
        src=$(git check-ignore -v -- "$f" 2>/dev/null | cut -d: -f1)
        if ignore_source_is_external "$f"; then __external=1; else __external=""; fi
        # An in-tree `.gitignore` rule is reviewable ONLY when it is new. A rule
        # already committed at the baseline needs no addition at all, and this
        # repo's own unanchored rules (`tmp/`, `test-results`, `node_modules`)
        # match at any depth -- so `src/routes/tmp/+page.svelte` was a real route
        # that SvelteKit builds and the gate never saw. A nested `.gitignore`
        # containing `*` generalizes it to any path. Anything that renders is
        # hashed no matter which ignore file hides it; the carve-out survives
        # only for paths that cannot render, so `.env` still stays out.
        # Expand BEFORE the render test. `git status --ignored=matching` emits the
        # collapsed `tmp/` for an ignored directory and never its files, so a
        # directory path could only ever hit renders()'s `src/`/`static/` prefix
        # arms -- the `.svelte`/`.css`/config suffix arms were structurally
        # unreachable. `tmp/HiddenDialog.svelte` was invisible while SvelteKit
        # compiled and SSR'd it, which is the docs/ hole through .gitignore.
        if [ -z "${__external:-}" ]; then
          if [ -d "$f" ]; then
            # is_hashable, not renders(): renders() answers "may a waiver cover
            # this", so its only non-src/static arms are .svelte/.html/.css and
            # four config names. A hidden directory of .ts/.js/.json was invisible.
            if [ -n "$(walk_hidden_dir "$f" | while IFS= read -r __i; do
                 is_source "$__i" && { echo hit; break; }
               done)" ]; then __external=1; fi
          elif renders "$f"; then
            __external=1
          fi
        fi
        case "${__external:-}" in
          1)
            # An individually-named file is hashed unless it is an artifact or
            # machine noise; a DIRECTORY yields only files that pass both bounds.
            # Note this means an externally-ignored `.env` IS hashed -- it stays
            # out of this repo only because `.gitignore` lists it too, making the
            # source in-tree. Directories are expanded because hashing the bare
            # path made a signed-off directory freely rewritable afterwards.
            if [ -d "$f" ]; then
              # Names first (cheap, always), then ONE batched read for the
              # hashable ones. A `cat` per file cost 1.7s at 600 files and 16s at
              # 6000 -- and `.claude/worktrees/**` is that shape in the workflow
              # CLAUDE.md promotes. Blobs contribute name plus size, so a rewrite
              # in place still moves the hash without reading bytes that mean
              # nothing to a reviewer.
              __names=$(walk_hidden_dir "$f")
              # The sentinel, not a re-derived count: `-ge CAP` was off by one and
              # emitted a truncation marker at exactly-cap where none occurred.
              case "$__names" in
                *"$WALK_TRUNCATED_SENTINEL"*)
                  printf 'externally-hidden-truncated:%s\n' "$f" ;;
              esac
              printf '%s\n' "$__names" | while IFS= read -r inner; do
                [ -z "$inner" ] && continue
                [ "$inner" = "$WALK_TRUNCATED_SENTINEL" ] && continue
                if is_hashable "$inner"; then printf 'externally-hidden:%s\n' "$inner"
                else printf 'externally-hidden-blob:%s:%s\n' "$inner" "$(shasum -a 256 < "$inner" 2>/dev/null | cut -d' ' -f1)"
                fi
              done
              printf '%s\n' "$__names" | while IFS= read -r inner; do
                [ -n "$inner" ] && is_hashable "$inner" && printf '%s\0' "$inner"
              done | xargs -0 cat 2>/dev/null
            elif [ -e "$f" ] && ! is_artifact "$f"; then
              if is_hashable "$f"; then
                printf 'externally-hidden:%s\n' "$f"
                cat -- "$f" 2>/dev/null
              else
                printf 'externally-hidden-blob:%s:%s\n' "$f" \
                  "$(shasum -a 256 < "$f" 2>/dev/null | cut -d' ' -f1)"
              fi
            fi
            ;;
        esac
      done
  )

  # --no-ext-diff --no-textconv on every diff below: a diff driver rewrites the
  # rendered output this hash is built from, and a textconv driver omits changed
  # paths entirely, so eight of ten changed files vanished from the hash while
  # the gate reported no work in flight.
  # A throwaway index so untracked files diff exactly like tracked ones. The
  # real index is never touched.
  tmpidx=$(mktemp 2>/dev/null) || { WORK_ERROR="could not create a temporary index"; return 1; }
  # Drop mktemp's zero-byte file: git rejects it as "index file smaller than
  # expected" and builds a valid one when the path is absent. In a LINKED
  # WORKTREE `${root}/.git` is a file rather than a directory, so an earlier
  # `${root}/.git/index` copy silently did nothing and left the empty file in
  # place, blocking permanently with no way to clear it -- in the workflow this
  # repo uses most. Not seeding the index at all makes that moot.
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
  diff=$(GIT_INDEX_FILE="$tmpidx" git diff --no-ext-diff --no-textconv "$baseline" -- . "${WORK_DENY[@]}" 2>/dev/null)
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
      extra="${extra}$(git diff --no-ext-diff --no-textconv "$baseline" "$tip" -- . "${WORK_DENY[@]}" 2>/dev/null)"
    done <<< "$(git for-each-ref --format='%(objectname)' 2>/dev/null)"
  fi
  local stashes
  stashes=$(git rev-list -g refs/stash 2>/dev/null | wc -l | tr -d ' ')
  [ "${stashes:-0}" != "0" ] && extra="${extra}
stashed-entries:${stashes}"

  if [ -z "$diff" ] && [ -z "$extra" ] && [ -z "$externally_hidden" ]; then return 0; fi

  # Seeded with identity so the stream is never empty and never portable
  # between repos or baselines.
  WORK_HASH=$(printf 'repo:%s\nbaseline:%s\n%s\n%s\n%s\n' "$root" "$baseline" "$diff" "$extra" "$externally_hidden" |
    shasum -a 256 2>/dev/null | cut -d' ' -f1)
  if [ -z "$WORK_HASH" ]; then
    WORK_ERROR="could not hash the working set (is shasum available?)"
    return 1
  fi
}

# Sets WAIVER_FORBIDDEN to the paths in the current body of work that a waiver
# may not cover, newline-separated; empty means the work is waivable. Returns
# non-zero with WORK_ERROR set for any state it cannot evaluate.
#
# Call it PLAINLY -- never as $(waiver_forbidden_paths). Printing the list to
# stdout meant the only sane call site was a command substitution, which runs
# the whole thing in a subshell and discards WORK_ERROR, so every error path
# read to the caller as "nothing forbidden, go ahead" and the refusal branch was
# dead code. The same subshell trap `compute_work_hash` documents, walked into
# by the shape of the interface rather than by the caller.
WAIVER_FORBIDDEN=""
waiver_forbidden_paths() {
  WORK_ERROR=""
  WAIVER_FORBIDDEN=""
  # Not `status`: zsh reserves it, and this file gets sourced interactively.
  local root baseline tmpidx names names_status p pattern stashes hidden
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$root" ]; then WORK_ERROR="not inside a git work tree"; return 1; fi

  # Not $(work_baseline): its WORK_ERROR assignment must survive.
  work_baseline || return 1
  baseline="$WORK_BASELINE"

  # A stash can carry a whole component and this cannot cheaply enumerate one,
  # so it refuses rather than waives what it cannot see.
  stashes=$(git rev-list -g refs/stash 2>/dev/null | wc -l | tr -d ' ')
  if [ "${stashes:-0}" != "0" ]; then
    WORK_ERROR="${stashes} stash entry/entries exist and a waiver cannot see inside them. Pop or drop them, or convene the board."
    return 1
  fi

  tmpidx=$(mktemp 2>/dev/null) || { WORK_ERROR="could not create a temporary index"; return 1; }
  # NOT seeded from the real index, matching compute_work_hash: copying it
  # carries cached stat data forward under a fresh mtime and defeats git's
  # racy-clean rule. The two functions decide the same question and must not
  # disagree about how they see the tree.
  rm -f "$tmpidx"
  GIT_INDEX_FILE="$tmpidx" git add -A -N -- . "${WORK_DENY[@]}" >/dev/null 2>&1
  # -z because core.quotePath C-quotes any non-ASCII path, and a quoted
  # `"src/routes/caf\303\251/+page.svelte"` starts with `"` rather than `src/`
  # and matches nothing -- an accent in a route segment waived the whole guard.
  # --no-renames because rename detection prints only the destination, so a
  # `git mv` of a component out of `src/` showed no forbidden path and deleted a
  # route with no reviewer. Not `-M0`, which reads like "no renames" and means
  # the opposite -- a 0% similarity threshold, i.e. detect them everywhere.
  names=$(GIT_INDEX_FILE="$tmpidx" git -c core.quotePath=false diff --name-only -z --no-renames \
    "$baseline" -- . "${WORK_DENY[@]}" 2>/dev/null | tr '\0' '\n')
  names_status=$?
  rm -f "$tmpidx" 2>/dev/null
  if [ $names_status -ne 0 ]; then WORK_ERROR="could not list changed paths against the baseline"; return 1; fi

  # Work parked on another branch is part of the body of work a waiver covers.
  if [ "$baseline" != "$EMPTY_TREE" ]; then
    while IFS= read -r tip; do
      [ -z "$tip" ] && continue
      git merge-base --is-ancestor "$tip" HEAD 2>/dev/null && continue
      names="${names}
$(git -c core.quotePath=false diff --name-only -z --no-renames "$baseline" "$tip" -- . "${WORK_DENY[@]}" 2>/dev/null | tr '\0' '\n')"
    done <<< "$(git for-each-ref --format='%(objectname)' 2>/dev/null)"
  fi

  # Files hidden by an ignore source outside the work tree never reach the diff
  # above, so a component concealed that way was waivable while the gate could
  # still see it. NOT identical to compute_work_hash's enumeration, deliberately
  # -- though both now use walk_hidden_dir, so the WALK itself is shared:
  # that one also applies is_hashable and is_artifact and folds in file CONTENTS,
  # because it decides what to hash. This one yields NAMES and lets WAIVER_NEVER
  # filter, because it decides what a waiver may cover. The empty-source arm also
  # arms are byte-identical now, since ignore_source_is_external replaced both
  # hand-written classifications. Do not "sync" the FILTERS: this yields names for
  # WAIVER_NEVER, that one yields names plus contents for the hash.
  hidden=$(
    git -c core.quotePath=false status --porcelain --ignored=matching -- . \
      "${WORK_DENY[@]}" \
      ':(exclude)node_modules' ':(exclude).svelte-kit' ':(exclude)dist' ':(exclude)build' \
      ':(exclude)test-results' ':(exclude)playwright-report' ':(exclude).turbo' 2>/dev/null |
      sed -n 's/^!! //p' |
      while IFS= read -r f; do
        src=$(git check-ignore -v -- "$f" 2>/dev/null | cut -d: -f1)
        if ignore_source_is_external "$f"; then __external=1; else __external=""; fi
        # Same expansion-before-test fix as compute_work_hash, applied separately
        # because the two enumerations deliberately differ (see the note above).
        if [ -z "${__external:-}" ]; then
          if [ -d "$f" ]; then
            # is_hashable, not renders(): renders() answers "may a waiver cover
            # this", so its only non-src/static arms are .svelte/.html/.css and
            # four config names. A hidden directory of .ts/.js/.json was invisible.
            if [ -n "$(walk_hidden_dir "$f" | while IFS= read -r __i; do
                 is_source "$__i" && { echo hit; break; }
               done)" ]; then __external=1; fi
          elif renders "$f"; then
            __external=1
          fi
        fi
        # Directory entries are collapsed by git, so `components/` matched no
        # WAIVER_NEVER pattern and a hidden component waived cleanly. Expand to
        # the real paths so they can be matched individually.
        if [ -n "${__external:-}" ]; then
          if [ -d "$f" ]; then
            # THE one enumerator. This was a fourth hand-rolled `find` that never
            # received `-L`, so a component behind `tmp/parts -> /outside` was
            # visible to the hash and invisible here: the gate blocked, and then
            # the waiver cleared the same work with no reviewer.
            walk_hidden_dir "$f" | grep -vxF "$WALK_TRUNCATED_SENTINEL"
          else printf '%s\n' "$f"
          fi
        fi
      done
  )
  [ -n "$hidden" ] && names="${names}
${hidden}"

  local out=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    for pattern in "${WAIVER_NEVER[@]}"; do
      case "$pattern" in
        */) case "$p" in "$pattern"*) out="${out}${p}
"; break ;; esac ;;
        *)  case "$p" in *"$pattern") out="${out}${p}
"; break ;; esac ;;
      esac
    done
  done <<< "$names"
  WAIVER_FORBIDDEN="$out"
}
