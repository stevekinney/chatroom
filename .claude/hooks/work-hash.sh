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
#   self-excluding edit hides itself. See CLAUDE.md; the gate cannot police its
#   own disablement, and pretending otherwise is worse than saying so.
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
# does NOT filter these on git's side: a collapsed ignored-directory entry is
# reported whole regardless of the pathspec, verified against `coverage/` and
# `node_modules/` both bare and as `/**`. `path_is_denied` now applies those
# excludes to the paths themselves once they are back from git, so the two
# enumerations that pass artifact excludes DO get them honored -- but this list
# is still what bounds the walk everywhere else, including the enumeration that
# passes WORK_DENY alone and every per-FILE decision `is_artifact` makes inside
# a directory that was not excluded at all. Deriving the bound from the paths
# is the load-bearing half either way; the pathspec was never the mechanism.
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
# A file whose name contains a literal NEWLINE byte cannot be represented by
# this walk's own newline-terminated `printf '%s\n' "$p"` output without
# corruption -- it would split across what every caller reads as two
# "lines", losing its own directory prefix in the process, and silently drop
# out of the hash entirely (confirmed: a `role="dialog"` component behind a
# newline-containing directory name cleared a four-PASS sign-off, rewritten,
# with no refusal). Detected on the INPUT side instead, where `find -print0`
# keeps the byte intact within one NUL-delimited record: read via `-d ''`,
# and a record containing an embedded `\n` after that read is unambiguously
# a path this walk cannot safely emit, not a record-boundary artifact.
NEWLINE_IN_PATH_SENTINEL='__WALK_NEWLINE__'
walk_hidden_dir() {
  local root_dir="$1" count=0 p
  # `./` prefix if relative and not already so: a directory literally named
  # `-lab` passed bare to `find` is parsed as an unknown OPTION FLAG
  # (`illegal option -- l`), not a path -- stderr swallowed below the same
  # way an unreadable directory's is, so the whole directory silently
  # dropped out of the walk with no refusal. `${root_dir#/}` unchanged means
  # no leading `/` was stripped, i.e. the path was already relative.
  [ "${root_dir#/}" = "$root_dir" ] && root_dir="./$root_dir"
  while IFS= read -r -d '' p; do
    [ -z "$p" ] && continue
    case "$p" in
      *$'\n'*)
        printf '%s\n' "$NEWLINE_IN_PATH_SENTINEL"
        return 0
        ;;
    esac
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
  done < <(find -L "$root_dir" -maxdepth 12 \
    \( -path '*/.git' -o \( \( -name node_modules -o -name .svelte-kit \) \
         ! -path 'src/*' ! -path 'static/*' ! -path '*/src/*' ! -path '*/static/*' \) \) -prune -o \
    -type f -print0 2>/dev/null | LC_ALL=C sort -z)
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
  local -a __segs
  # Left to right: the FIRST segment matching either list decides. An artifact
  # segment wins unless a rendered root came first.
  #   src/routes/build/x        -> keep   (src first)
  #   coverage/lcov/src/a.html  -> drop   (coverage first; Istanbul's own layout,
  #                                        which the old order hashed at 7s)
  #   .claude/worktrees/wt/src/ -> keep   (no artifact segment)
  #
  # `IFS=/ read -ra`, not `local IFS=/; for seg in $p`: the old form left
  # `$p` UNQUOTED to get word-splitting on `/`, which also re-enables
  # PATHNAME EXPANSION -- `local IFS=` changes the splitting character, not
  # whether globbing happens. A path segment that is itself a glob (`tmp/*/
  # Modal.svelte`) expanded against the CWD, and `node_modules` is always
  # present in a real checkout, so a bare `*` segment always matched
  # ARTIFACT_DIRS and the file silently dropped out of the walk -- `set -f`
  # would have the same effect but needs restoring on every return path in a
  # function with several; `read -ra` never expands at all, by construction.
  IFS=/ read -ra __segs <<< "$p"
  for seg in "${__segs[@]}"; do
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

# True when $1 is one of the denied paths in $2... , or sits underneath one.
#
# DIRECTION IS THE WHOLE HAZARD HERE, and getting it backwards is a fail-OPEN.
# A path is denied only when it IS a denied path or lives UNDER one. The
# reverse test -- dropping a path because a denied path lives under IT --
# would drop an ignored `.claude/` on account of `.claude/.review-board-state`
# and take `.claude/hooks`, this gate's own definition, out of the hash with it.
# So an ancestor of a denied path is deliberately KEPT and left to be walked.
#
# Trailing slashes are stripped from both sides because `git status
# --ignored=matching` reports a collapsed directory as `foo/` while the pathspec
# that named it has no slash. This is DEFENSIVE, not load-bearing, and an
# earlier version of this comment claimed otherwise -- that without the strip
# "the filter is inert in exactly the case it exists for", which is false and
# was caught by building the strip-less variant: the suite stays 121/0 and
# `path_is_denied '.claude/.review-board-state/' '.claude/.review-board-state'`
# still answers denied, because the `"$__d"/*` arm below matches `foo/` against
# `foo/*` with `*` binding the empty string. What the strip actually buys is a
# pathspec spelled WITH a trailing slash matching a path below it (`foo/bar.ts`
# against a deny of `foo/`), which no call site uses today. Kept because it is
# free; described honestly because a false claim about what a line is holding up
# is how the next reader deletes the wrong one.
#
# Patterns are QUOTED inside `case` so a denied path containing a glob
# character matches literally rather than as a pattern -- the same reason the
# symlink-escape block quotes its own `${__d#":(exclude)"}`.
path_is_denied() {
  local __p="${1%/}" __d
  shift
  for __d in "$@"; do
    __d="${__d%/}"
    [ -z "$__d" ] && continue
    [ "$__p" = "$__d" ] && return 0
    case "$__p" in "$__d"/*) return 0 ;; esac
  done
  return 1
}

# Prints the first source file hiding inside the state directory, or nothing.
#
# `path_is_denied` making WORK_DENY real on the ignored-content walk closed a
# livelock and, on its own, opened the one hole this file already learned not to
# leave: `.claude/.review-board-state` is the ONLY directory in WORK_DENY, and a
# denied directory the bundler can resolve an import into is verbatim the `docs/`
# mistake WORK_DENY's own comment records. Demonstrated, not theorised -- an
# `Evil.svelte` written here stopped moving the hash AND dropped out of
# WAIVER_FORBIDDEN, so one board round on a tracked `import` line bought
# unlimited unreviewed edits to a component vite still bundles, SSRs and
# hydrates, and `--grounds formatting-only` would be recorded over it.
#
# Refusing is both the fail-closed answer and the ACTIONABLE one, which is the
# whole point: the pre-fix behaviour hashed such a file, so the gate drifted with
# no explanation and every retry made it worse. That is the livelock CHR-19 set
# out to kill. Naming the file kills it without trading it for a silent allow --
# the same shape as the external-ignore guard, which also refuses by name rather
# than hiding what it cannot review.
#
# NOT conditional on the directory being ignored. Unignored, it is excluded from
# the diff by the pathspec instead (which git honours for `git add`), so a source
# file here is invisible in that configuration too -- pre-fix included. This
# closes both.
#
# Silent in normal operation: nothing the sign-off flow writes here has a source
# extension. Either walk sentinel counts as a hit, since a directory this cannot
# finish reading is exactly the state rule one says to block on.
state_dir_hides_source() {
  [ -d "$STATE_DIR" ] || return 0
  walk_hidden_dir "$STATE_DIR" | while IFS= read -r __sp; do
    [ -z "$__sp" ] && continue
    case "$__sp" in
      "$NEWLINE_IN_PATH_SENTINEL"|"$WALK_TRUNCATED_SENTINEL")
        printf '%s
' "$__sp"; break ;;
    esac
    if is_source "$__sp"; then printf '%s
' "$__sp"; break; fi
  done
}

# Prints "!! "-prefixed paths from `git status --porcelain --ignored=matching`
# with the prefix stripped, one per output line -- using -z on the git side
# to correctly read a path containing a literal `"`, `\`, tab, or other
# control byte, none of which `-c core.quotePath=false` alone reaches (that
# flag suppresses non-ASCII quoting only; git still C-quotes those other
# bytes regardless of it). A quoted line broke every consumer downstream of
# it -- `sed -n 's/^!! //p'` on the QUOTED text, not the real path, so
# `[ -d "$f" ]`, `renders`, and `is_source` all silently missed it and an
# unreviewed, quote-containing component cleared the board.
#
# A path containing a literal NEWLINE byte is read correctly here -- `-z` /
# `read -d ''` do not confuse it with a record boundary -- but re-emitting
# it via `printf '%s\n'` for compatibility with every existing newline-based
# consumer in this file would corrupt it one line downstream, the same class
# of silent bypass the four bytes above caused before this function existed.
# Rather than emit the corrupting line, this refuses via the same terminal-
# SENTINEL convention `walk_hidden_dir` already uses for truncation: every
# call site checks for it and sets WORK_ERROR, so the failure mode is a
# refusal a person can act on, not a directory silently dropped from the
# hash. This is deliberately a NARROW guard (detect-and-refuse) rather than
# the full NUL-safe rewrite of every downstream consumer that a complete fix
# would need -- confirmed real and demonstrated as a live silent ALLOW by
# three independent review rounds before this refusal was added.
#
# Optional leading `-C <dir>` runs against that repo instead of the current
# one (an embedded gitlink or a linked worktree), matching git's own flag.
#
# The `:(exclude)` pathspecs callers pass are honored by git for an
# individually-named FILE and NOT for a collapsed ignored DIRECTORY:
# `--ignored=matching` reports such a directory as one entry and emits that
# entry whole regardless of any exclude pathspec -- confirmed against git
# 2.55.0 in all three spellings (bare, trailing slash, `/**`), with
# `:(exclude)CLAUDE.md` as a working control on a file. So `WORK_DENY` was
# passed at all three call sites and did nothing for `.claude/.review-board-
# state/`, which stayed out of the hash only because `is_source` happens to
# reject `.signoff` and the extensionless `last-cleared`. A `.ts` written
# there DID move the hash, a rewrite moved it again, and the same file one
# level down in `signoffs/` moved it a third time. Fails CLOSED -- such a file
# gets hashed rather than hidden -- so the risk was the livelock class the
# STATE_DIR guard in compute_work_hash exists to diagnose, not an unreviewed
# component reaching main.
#
# Applied HERE rather than at the three call sites, so the exclusion is real
# once instead of three times and a fourth call site cannot be added without
# it -- the same reason walk_hidden_dir is THE ONE WALK and
# ignore_source_is_external is one function. The deny set is DERIVED from the
# pathspecs actually passed, not a second copy of WORK_DENY, so it cannot
# drift from the list it mirrors. Only the literal `:(exclude)<path>` form
# yields a deny prefix; a positive pathspec (`.`) or a magic form this does
# not recognize yields none, which leaves today's over-inclusive behavior
# rather than guessing at a bound. The two `-C` call sites pass no excludes at
# all, so this is a no-op for them by construction.
ignored_matching_paths() {
  local __raw __stripped __repo="" __arg
  local -a __deny=()
  if [ "$1" = "-C" ]; then
    __repo="$2"
    shift 2
  fi
  for __arg in "$@"; do
    # Quoted: unquoted, bash reads `(` as pattern syntax and strips nothing.
    case "$__arg" in
      ':(exclude)'*) __deny[${#__deny[@]}]="${__arg#":(exclude)"}" ;;
    esac
  done
  git ${__repo:+-C "$__repo"} -c core.fsmonitor=false -c core.quotePath=false \
      -c status.showUntrackedFiles=all status --porcelain -z --ignored=matching -- "$@" 2>/dev/null |
    while IFS= read -r -d '' __raw; do
      __stripped="${__raw#"!! "}"
      [ "$__stripped" = "$__raw" ] && continue
      [ -z "$__stripped" ] && continue
      # BEFORE the newline refusal, not after: a denied path is not work, and
      # refusing over one would block on the gate's own state directory --
      # an unactionable message, which is the livelock class this filter is
      # closing rather than a safety check worth keeping there.
      #
      # `${#__deny[@]}` guard, not a bare `"${__deny[@]}"`: stock macOS
      # /bin/bash (3.2) treats expanding an EMPTY array under `set -u` as an
      # unbound variable and dies, which at the two `-C` call sites -- the
      # ones that pass no excludes -- would take out the gitlink and worktree
      # checks entirely.
      if [ ${#__deny[@]} -gt 0 ] && path_is_denied "$__stripped" "${__deny[@]}"; then
        continue
      fi
      case "$__stripped" in
        *$'\n'*)
          printf '%s\n' "$NEWLINE_IN_PATH_SENTINEL"
          continue
          ;;
      esac
      printf '%s\n' "$__stripped"
    done
}

# Also force-adds any TRACKED-but-IGNORED path into the materialized index
# at $1 ($2... is the same pathspec the -A -N call that built it used).
# `git add -A -N` on a FRESH, empty throwaway index has no notion of what
# the real index already tracks, so a path matching `.gitignore` that was
# previously force-tracked (`git add -f`) is skipped entirely -- not staged
# as new, not staged as modified, simply absent, in every materialized
# index built this way regardless of the path's actual content. A diff
# built from that index then reports such a path as "does not exist" no
# matter what it holds: confirmed by force-adding two completely different
# bodies of content to the same ignored, tracked path in two commits and
# getting the IDENTICAL empty diff both times against baseline -- a real
# hash collision, not just an omission, since neither state ever moves the
# hash away from whatever it already was. `-f -N` on the SPECIFIC path,
# not a bulk re-add, reads fresh content straight from the working tree
# rather than carrying any cached state forward, so it does not reopen the
# racy-clean hole the surrounding function's seeding choice already avoids.
add_ignored_tracked() {
  local idx="$1"
  shift
  local __tp
  # -z / -c core.quotePath=false / -d '': without them, a force-tracked
  # ignored path containing any of FIVE bytes git quotes on output --
  # non-ASCII, `"`, `\`, a control byte under 0x20, or a literal newline --
  # comes back C-quoted, `git add -f -N -- "$__tp"` on that literal quoted
  # string matches no pathspec, exits nonzero into the swallowed
  # `2>/dev/null`, and the path stays absent from the throwaway index: the
  # exact collision this function exists to close, reopened. NOT the same
  # guarantee as `-c core.quotePath=false` alone, used elsewhere in this
  # file where only non-ASCII quoting is the concern (a gitlink path, say)
  # -- that flag suppresses quoting for non-ASCII bytes specifically and
  # does nothing for the other four classes. `-z` is the one that removes
  # quoting for all five, which is why it is required here and not optional
  # alongside the flag.
  # `< <(...)` (process substitution), NOT `... | while`: a pipe runs its RHS
  # in a SUBSHELL, so a `WORK_ERROR` assignment made inside the loop below
  # would be discarded the moment the pipe exits -- the exact class of bug
  # this file's other loops already route around via the sentinel-line
  # convention. Process substitution keeps the `while` itself in THIS shell,
  # so a plain assignment here reaches the caller normally.
  #
  # `ls-files`'s own exit status, not just the loop body's: hardening the
  # `git add -f` call above and leaving THIS command's failure unchecked
  # reopens the identical collision one line up -- an unreadable or corrupt
  # `.git/index` (`chmod 000`, or a few garbage bytes written into it) makes
  # `git ls-files --cached --ignored` exit nonzero with its stderr swallowed
  # below; the loop then simply never iterates, no WORK_ERROR is set, and
  # the force-tracked ignored path stays silently absent from the throwaway
  # index -- reproduced with the real git binary, no fault injection needed.
  # `$?` after `done < <(...)` reads the WHILE loop's own exit status, not
  # the substituted command's, so the producer writes its exit code to a
  # file instead -- the file survives the process-substitution subshell
  # exiting, unlike a variable assigned inside it.
  local __lsf_ec_file
  __lsf_ec_file=$(mktemp 2>/dev/null) || { WORK_ERROR="could not create a temporary file"; return 1; }
  while IFS= read -r -d '' __tp; do
    [ -z "$__tp" ] && continue
    # `./` prefix: a path git reports beginning with `:` (pathspec magic
    # syntax, e.g. a directory literally named `:magic`) is otherwise
    # parsed as a magic pathspec rather than a literal path and matches
    # nothing -- the identical collision, reopened a third way. `./x` and
    # `x` name the same path for any ordinary pathspec, so this is safe
    # unconditionally rather than only when the leading byte is `:`.
    #
    # Checked, not swallowed: an unchecked failure here is silent in the
    # fail-OPEN direction -- the path stays absent from the throwaway index
    # exactly as if `-z`/`-d ''` had never been added, so two different
    # bodies of the same force-tracked ignored path hash identically. Every
    # existing probe for this function only exercises the healthy path;
    # confirmed live by a `git` shim that fails only this one call.
    if ! GIT_INDEX_FILE="$idx" git add -f -N -- "./$__tp" >/dev/null 2>&1; then
      WORK_ERROR="could not stage the tracked-but-ignored path ${__tp} into the index this gate hashes from, so its real content cannot be verified. Investigate why \`git add -f\` fails there, or move that content out of the work tree."
      rm -f "$__lsf_ec_file" 2>/dev/null
      return 1
    fi
  done < <(git -c core.quotePath=false ls-files -z --cached --ignored --exclude-standard -- "$@" 2>/dev/null; echo $? > "$__lsf_ec_file")
  local __lsf_ec
  __lsf_ec=$(cat "$__lsf_ec_file" 2>/dev/null)
  rm -f "$__lsf_ec_file" 2>/dev/null
  if [ "$__lsf_ec" != "0" ]; then
    WORK_ERROR="could not list tracked-but-ignored paths (git ls-files exited ${__lsf_ec:-nonzero}), so this gate cannot tell whether any are hidden from it. Investigate the index (is it readable?), or move that content out of the work tree."
    return 1
  fi
}

# Resolves a symlink's raw readlink() target against the directory the link
# lives in, echoing the (possibly still relative-with-..) absolute path.
# A plain top-level function, deliberately: stock macOS /bin/bash is 3.2,
# and its parser cannot handle a `case` statement whose text sits lexically
# inside a `$( ... )` command substitution -- ANY case/esac there, regardless
# of pattern, is a syntax error (reproduced with `case "$1" in *) ... esac`
# alone). A function defined at the top level parses fine; only the call
# site's literal text (no case/esac in it) ends up inside the substitution
# that invokes it. Every case below that can run inside a `VAR=$( ... )`
# block in this file must live in a function like this one for that reason.
resolve_symlink_target() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s\n' "$2/$1" ;;
  esac
}

# Prints "link -> rel" if target is inside root and matches one of the
# space-separated $denied patterns, or "link -> target (outside the repo)"
# if target escapes root entirely. Prints nothing if target is inside root
# but not denied. See resolve_symlink_target for why this is a function.
report_symlink_escape() {
  local link="$1" target="$2" root="$3" denied="$4" rel __d
  case "$target" in
    "$root"/*)
      rel="${target#"$root"/}"
      for __d in $denied; do
        case "$rel" in
          "$__d"|"$__d"/*) printf '%s -> %s\n' "$link" "$rel"; return 0 ;;
        esac
      done
      ;;
    *) printf '%s -> %s (outside the repo)\n' "$link" "$target" ;;
  esac
}

# True when a path reaches the browser OR decides what does -- WAIVER_NEVER now
# includes package.json and bun.lock, which pin the component versions and so are
# upstream of every rendered surface without rendering anything themselves. Used both to decide what a waiver may
# never cover and to decide which ignored paths must be hashed regardless of
# which ignore file hides them.
#
# Matched lowercase. This repo's filesystem is case-insensitive (`core.
# ignorecase=true`, APFS default) and WAIVER_NEVER's patterns are plain
# lowercase strings compared byte-for-byte -- `assets/Theme.CSS` waived
# cleanly under every ground because it is not a byte-for-byte match for
# `.css`, even though it is the exact file `assets/theme.css` on disk. `src/`
# stays safe because git normalizes `SRC/...` back to the tracked `src/...`
# once anything is tracked there, but the extension arms outside `src/` had
# no such backstop.
renders() {
  local p pattern
  p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
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
  if [ ! -f "$LAST_CLEARED_FILE" ]; then
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
  local baseline root tmpidx diff extra

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

  # ...and must not become a hiding place either. See state_dir_hides_source.
  local __state_src
  __state_src=$(state_dir_hides_source)
  if [ -n "$__state_src" ]; then
    WORK_ERROR="${STATE_DIR} holds source this gate would otherwise stop measuring: ${__state_src}. Nothing that renders, or that decides what renders, may live in the board's own state directory. Move it into the tree, where it is reviewable."
    return 1
  fi

  # Two more places work hides that this cannot enumerate, so it refuses rather
  # than measuring less than it claims -- the same posture the stash guard takes.
  #
  # `-c core.fsmonitor=false` on both probes below: fsmonitor answers "is this
  # dirty" from a daemon's event stream, so a stale or lying one reports clean.
  # `-c status.showUntrackedFiles=all`: a `status.showUntrackedFiles=no` set
  # anywhere this reads from (global config, or the linked worktree's own
  # per-worktree config) makes `git status --porcelain` report clean while an
  # entirely untracked, unreviewed component sits right there -- one config
  # line, no `.gitignore` involved. `--ignore-submodules=none -c
  # diff.ignoreSubmodules=none`: the same shape of lie, for a submodule nested
  # inside what this probes.
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
      if [ -n "$(git -C "$wt" -c core.fsmonitor=false -c status.showUntrackedFiles=all \
          -c diff.ignoreSubmodules=none status --porcelain --ignore-submodules=none 2>/dev/null)" ]; then
        printf '%s (uncommitted)\n' "$wt"; continue
      fi
      # Same index-bits check as the outer repo, run INSIDE the worktree:
      # git's index is per-worktree, so a `skip-worktree`/`assume-unchanged`
      # bit set there hides a modification from THAT worktree's own status
      # and diff the identical way it does for the outer repo -- and this
      # gate promotes worktrees as the normal workflow, so this is not a
      # contrived shape. The outer check at the top of this function never
      # sees it; it only ever reads the outer repo's own index.
      if git -C "$wt" ls-files -v -- . 2>/dev/null | grep -qE '^([a-z]|S)'; then
        printf '%s (index bits)\n' "$wt"; continue
      fi
      # Same shape as the gitlink check below: a linked worktree's OWN
      # committed `.gitignore` can hide a component from status entirely,
      # a different mechanism than showUntrackedFiles and not covered by
      # forcing it. A worktree of THIS repo shares this repo's own src/
      # layout, so is_artifact's src-first rule applies to these paths the
      # same way it does to the main checkout's, without the path-shape
      # mismatch an embedded repo's OWN root introduces.
      __wt_ignored_hit=$(ignored_matching_paths -C "$wt" . |
        while IFS= read -r __wip; do
          [ "$__wip" = "$NEWLINE_IN_PATH_SENTINEL" ] && { echo hit; break; }
          is_artifact "$__wip" || { echo hit; break; }
        done)
      [ -n "$__wt_ignored_hit" ] && { printf '%s\n' "$wt"; continue; }
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
  #
  # Read from a MATERIALIZED index (git add -A -N into a throwaway index),
  # not the real one: `git ls-files -s` on the real index sees a gitlink only
  # once the embedded repo has been `git add`-ed to the superproject. An
  # embedded repo that never was -- `cd src/lib/vendor && git init` and
  # nothing else -- produces no entry there at all, so this whole guard was
  # a no-op for it: a signed-off tree could have a fresh embedded repo's
  # content freely rewritten afterward with nothing here to catch it. `-N`
  # (intent-to-add) surfaces every gitlink, tracked or not, without staging
  # real content.
  # Also -c status.showUntrackedFiles=all -c diff.ignoreSubmodules=none
  # --ignore-submodules=none, same as the worktree probe above and for the
  # same reason: a `status.showUntrackedFiles=no` set inside the EMBEDDED
  # repo's own config (not this repo's, so nothing here would ever see the
  # setting itself) makes its status report clean with an untracked,
  # unreviewed component sitting right there. `--ignored=matching`,
  # additionally: the embedded repo's own `.gitignore` can hide a component
  # from status entirely, committed or not, so this cannot rely on "clean
  # status" meaning "nothing here" -- it must also inspect what that repo
  # ignores. Piped through `is_artifact`, which already tells this file
  # what a real build artifact looks like, so an embedded repo's own
  # `node_modules` -- entirely ordinary -- does not brick every gate run.
  #
  # KNOWN LIMITATION, not fixed: `is_artifact` runs on paths relative to
  # the GITLINK's own root, not the outer repo's. That is correct for
  # `node_modules` (an artifact regardless of where the embedded repo
  # sits), and wrong for an embedded route that happens to share a name
  # with an ARTIFACT_DIRS entry: an embedded `build/+page.svelte`, ignored
  # by that repo's OWN `.gitignore`, reads as an artifact and is skipped --
  # even though SvelteKit would compile it as a real route once the
  # gitlink sits under `src/routes/`. Confirmed: two completely different
  # bodies of such a file hash identically, both before and after a
  # signed-off review. Prefixing the outer path fixes that case and breaks
  # the node_modules one instead (once "src" precedes anything,
  # is_artifact's src-first rule stops looking further), so the two
  # directions cannot both be satisfied by this function as designed. Left
  # disclosed rather than guessed at with an untested fix.
  local gitlink_idx gitlinks dirty_sub
  gitlink_idx=$(mktemp 2>/dev/null) || { WORK_ERROR="could not create a temporary index"; return 1; }
  rm -f "$gitlink_idx"
  GIT_INDEX_FILE="$gitlink_idx" git add -A -N -- . "${WORK_DENY[@]}" >/dev/null 2>&1
  add_ignored_tracked "$gitlink_idx" . "${WORK_DENY[@]}"
  if [ -n "$WORK_ERROR" ]; then rm -f "$gitlink_idx" 2>/dev/null; return 1; fi
  # core.quotePath=false: without it a non-ASCII gitlink path (a repo under
  # `src/lib/café`) comes back C-quoted, `[ -d ]` on the quoted string fails,
  # and the gitlink reads as "(cannot enter)" -- the fail-closed direction,
  # but a misleading message for what is actually an ordinary path. Scoped
  # to non-ASCII only, deliberately: a gitlink path containing one of the
  # other four bytes `ignored_matching_paths`'s comment names (`"`, `\`, a
  # control byte, a newline) still reads as "(cannot enter)" here, since no
  # `git ls-files -s` in this file switches to `-z` -- also fail-closed, so
  # not a bypass, just the same misleading message for a rarer path shape.
  gitlinks=$(GIT_INDEX_FILE="$gitlink_idx" git -c core.quotePath=false ls-files -s -- . 2>/dev/null | awk '$1=="160000" {print substr($0, index($0,$4))}')
  rm -f "$gitlink_idx" 2>/dev/null
  if [ -n "$gitlinks" ]; then
    dirty_sub=$(printf '%s\n' "$gitlinks" | while IFS= read -r sm; do
      [ -z "$sm" ] && continue
      if [ ! -d "${root}/${sm}/.git" ] && [ ! -f "${root}/${sm}/.git" ]; then
        printf '%s (cannot enter)\n' "$sm"; continue
      fi
      if [ -n "$(git -C "${root}/${sm}" -c core.fsmonitor=false -c status.showUntrackedFiles=all \
          -c diff.ignoreSubmodules=none status --porcelain --ignore-submodules=none 2>/dev/null)" ]; then
        printf '%s\n' "$sm"; continue
      fi
      # Same index-bits check as the outer repo and the worktree guard
      # above, run INSIDE the embedded repo: its index is its own, so a
      # `skip-worktree`/`assume-unchanged` bit set there hides a
      # modification from ITS status and diff the same way it does outside.
      if git -C "${root}/${sm}" ls-files -v -- . 2>/dev/null | grep -qE '^([a-z]|S)'; then
        printf '%s\n' "$sm"; continue
      fi
      __ignored_hit=$(ignored_matching_paths -C "${root}/${sm}" . |
        while IFS= read -r __ip; do
          [ "$__ip" = "$NEWLINE_IN_PATH_SENTINEL" ] && { echo hit; break; }
          is_artifact "$__ip" || { echo hit; break; }
        done)
      [ -n "$__ignored_hit" ] && printf '%s\n' "$sm"
    done)
    if [ -n "$dirty_sub" ]; then
      WORK_ERROR="a submodule or embedded repository has changes this gate cannot see: $(printf '%s' "$dirty_sub" | tr '\n' ' '). Commit them inside it so the gitlink moves."
      return 1
    fi
  fi

  # A CLEAN FILTER (`filter.<name>.clean` in git config, wired to a path via
  # a `filter=<name>` .gitattributes/.git/info/attributes rule) transforms
  # file content before git computes ANY diff against it, including inside
  # the throwaway index the diff below reads. A clean command that
  # reconstructs whatever was last reviewed -- regardless of the real
  # working-tree bytes -- makes `git diff` report no change at all while the
  # file on disk is completely different. `--no-ext-diff --no-textconv` on
  # the diff below guards external diff drivers and textconv; neither
  # touches filter.*.clean, and there is no `--no-filters` to ask git diff
  # for the untransformed comparison. Confirmed: a filter whose clean
  # command echoes fixed, already-reviewed content clears the gate on a
  # real, unreviewed rewrite with the diff showing nothing.
  #
  # Checked across every path in the reviewable scope, TRACKED OR NOT (via a
  # materialized index, same technique as the gitlink read above) -- an
  # UNTRACKED file with the attribute still reached this on the real index
  # alone, and work in flight is usually untracked at sign-off time, which
  # made that the commoner shape rather than the rarer one. This repo
  # configures no filters today (`git ls-files -z | git check-attr --stdin
  # -z filter` returns nothing but `unspecified`), so this refuses only if
  # one is ever added -- deliberately, matching the rest of this file: a
  # state it cannot verify is a block, not a silent allow, even though
  # nothing is at risk here yet.
  local attr_idx
  attr_idx=$(mktemp 2>/dev/null) || { WORK_ERROR="could not create a temporary index"; return 1; }
  rm -f "$attr_idx"
  GIT_INDEX_FILE="$attr_idx" git add -A -N -- . "${WORK_DENY[@]}" \
    ':(exclude)node_modules' ':(exclude).svelte-kit' ':(exclude)dist' ':(exclude)build' \
    ':(exclude)test-results' ':(exclude)playwright-report' ':(exclude).turbo' >/dev/null 2>&1
  add_ignored_tracked "$attr_idx" . "${WORK_DENY[@]}" \
    ':(exclude)node_modules' ':(exclude).svelte-kit' ':(exclude)dist' ':(exclude)build' \
    ':(exclude)test-results' ':(exclude)playwright-report' ':(exclude).turbo'
  if [ -n "$WORK_ERROR" ]; then rm -f "$attr_idx" 2>/dev/null; return 1; fi
  # -z on BOTH sides, read with `-d ''`, never `tr '\0' '\n'`: a path
  # containing a literal newline byte is legal and NUL-delimited output
  # keeps it intact as one field, but converting NULs to newlines turns that
  # embedded byte into a second record boundary and desynchronizes every
  # triple after it -- a one-file, no-guard-touching bypass of this whole
  # check. Read as raw NUL-terminated fields via process substitution
  # instead. The `case` below is NOT protected by being inside `<( )`
  # rather than `$( )` -- both break bash 3.2 identically when case/esac
  # text sits lexically inside the substitution's own command (confirmed:
  # `case` written directly inside a `<( )` producer is a syntax error
  # under 3.2 too). What actually makes this safe is that the `case` sits
  # in the LOOP BODY, consuming the substitution's output, not inside the
  # substitution itself -- the producer command below (`git ls-files -z |
  # git check-attr ...`) contains no case/esac text at all.
  local __fp="" __fv="" __i=0 __clean_paths=""
  while IFS= read -r -d '' __field; do
    case $((__i % 3)) in
      0) __fp="$__field" ;;
      2)
        __fv="$__field"
        if [ -n "$__fv" ] && [ "$__fv" != "unspecified" ] &&
           [ -n "$(git config --get "filter.${__fv}.clean" 2>/dev/null)" ]; then
          __clean_paths="${__clean_paths}${__fp}
"
        fi
        ;;
    esac
    __i=$((__i + 1))
  done < <(GIT_INDEX_FILE="$attr_idx" git ls-files -z 2>/dev/null | git check-attr --stdin -z filter 2>/dev/null)
  rm -f "$attr_idx" 2>/dev/null
  if [ -n "$__clean_paths" ]; then
    WORK_ERROR="a configured clean filter can rewrite this gate's own view of the diff for: $(printf '%s' "$__clean_paths" | tr '\n' ' '). This gate cannot verify what a filtered path really changed. Remove the filter, or its .gitattributes rule, so the diff is trustworthy again."
    return 1
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
      abs=$(resolve_symlink_target "$raw" "$linkdir")
      # Physical path of the target's parent, so `..` segments collapse.
      tdir=$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P)
      if [ -z "$tdir" ]; then printf '%s -> %s (unresolvable)\n' "$link" "$raw"; continue; fi
      target="${tdir}/$(basename "$abs")"
      report_symlink_escape "$link" "$target" "$root" "$denied"
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
  # Same prune clause walk_hidden_dir uses below, so these three probes bound
  # and read-check exactly what the walk will actually visit -- not what a
  # naive `find` sees. Without it, a `node_modules` nested past depth 13 (real
  # on this machine: ../cinder and ../agent-bureau's own node_modules both
  # exceed it today) or containing one unreadable file bricked the gate with
  # "flatten it", even though walk_hidden_dir prunes node_modules/.svelte-kit
  # entirely and would never have descended there.
  local __prune_clause=(-path '*/.git' -o \( \( -name node_modules -o -name .svelte-kit \) \
    ! -path 'src/*' ! -path 'static/*' ! -path '*/src/*' ! -path '*/static/*' \))
  while IFS= read -r __hidden_dir; do
    [ -z "$__hidden_dir" ] && continue
    if [ "$__hidden_dir" = "$NEWLINE_IN_PATH_SENTINEL" ]; then
      # NOT `[ -d ]`-skippable like an ordinary entry: the sentinel is not a
      # real path, and silently continuing here is exactly the fail-open
      # this sentinel exists to prevent -- a hidden path this gate could
      # not safely name would otherwise just vanish from the walk.
      WORK_ERROR="an ignored path contains a literal newline byte, which this gate cannot safely enumerate as a single path. Rename it, or move that content out of the work tree."
      return 1
    fi
    # `./` prefix if relative and not already so: passed bare to the `find`
    # calls below, a directory literally named `-lab` is parsed as an
    # unknown OPTION FLAG rather than a path, `find` errors with its usage
    # message to stderr (swallowed by every `2>/dev/null` below), and the
    # whole directory silently drops out of every one of these checks with
    # no refusal -- the depth bound, the readability probe, and the cap all
    # read as "nothing here" for a directory this gate never actually saw.
    [ "${__hidden_dir#/}" = "$__hidden_dir" ] && __hidden_dir="./$__hidden_dir"
    [ -d "$__hidden_dir" ] || continue
    # R5: `find`'s stderr is swallowed, so an UNREADABLE directory is
    # byte-identical on stdout to an empty one -- `chmod 000` was a one-command
    # fail-open. Probe readability explicitly before trusting an empty walk.
    #
    # NOT `-mindepth 13 ... -prune -o ...`: this machine's BSD find silently
    # drops -prune the moment -mindepth appears ANYWHERE in the expression --
    # confirmed with -maxdepth paired alongside it too, so it is not a
    # maxdepth/mindepth ordering fix, -mindepth itself is the trigger. With it
    # gone, node_modules got walked in full every single time (the exact
    # pathological tree this probe exists to catch before that walk), and a
    # completely ordinary `node_modules` -- real on this machine, in both
    # ../cinder and ../agent-bureau -- bricked the gate with an instruction
    # ("flatten it") nobody could act on. Comparing two -mindepth-free counts
    # avoids the primary entirely: a prune-aware maxdepth-12 walk and a
    # maxdepth-13 walk of the SAME tree see identical entries unless
    # something sits at exactly depth 13, so a higher count at 13 means the
    # tree reaches (at least) depth 13 -- an ancestor DIRECTORY of anything
    # deeper still is itself present there, so this needs no -type filter to
    # catch trees that go past depth 13.
    local __d12 __d13
    __d12=$(find -L "$__hidden_dir" \( "${__prune_clause[@]}" \) -prune -o \
        -maxdepth 12 -print 2>/dev/null | wc -l)
    __d13=$(find -L "$__hidden_dir" \( "${__prune_clause[@]}" \) -prune -o \
        -maxdepth 13 -print 2>/dev/null | wc -l)
    if [ "$__d13" -gt "$__d12" ]; then
      WORK_ERROR="${__hidden_dir} nests deeper than this gate walks, so it cannot tell whether work hides down there. Flatten it, or move that content out of the work tree."
      return 1
    fi
    if [ -n "$(find -L "$__hidden_dir" \( "${__prune_clause[@]}" \) -prune -o \
        -type d \( ! -perm -u+r -o ! -perm -u+x \) -print -quit 2>/dev/null)" ] ||
       [ -n "$(find -L "$__hidden_dir" \( "${__prune_clause[@]}" \) -prune -o \
        -type f ! -perm -u+r -print -quit 2>/dev/null)" ] ||
       ! ls -- "$__hidden_dir" >/dev/null 2>&1; then
      WORK_ERROR="${__hidden_dir} cannot be read, so this gate cannot tell whether it hides work. Fix its permissions, or move it out of the work tree."
      return 1
    fi
    __walk_out=$(walk_hidden_dir "$__hidden_dir")
    # NO admission predicate here, deliberately. Deciding whether to verify the
    # bound by inspecting contents you have truncated is circular, and the
    # narrower predicate was applied to the directory PATH while the enumeration
    # below applies its own to the FILES -- so `tmp/` was checked by neither.
    # `path_is_denied` filtering WORK_DENY paths out upstream of this loop is
    # not that predicate returning: it is a scope decision made on the path
    # alone, never on contents, and it only ever removes paths this file has
    # already declared unreviewable. The one thing it costs is that the state
    # directory no longer gets these depth, readability and cap bounds -- which
    # is correct, since nothing in it is work, and an unreadable one fails
    # loudly in review-board-signoff.sh's own `mkdir -p` rather than silently.
    case "$__walk_out" in *"$NEWLINE_IN_PATH_SENTINEL"*)
      WORK_ERROR="${__hidden_dir} contains a file whose name has a literal newline byte, which this gate cannot safely enumerate as a single path. Rename it, or move that content out of the work tree."
      return 1 ;;
    esac
    case "$__walk_out" in *"$WALK_TRUNCATED_SENTINEL"*) __trunc=1 ;; *) __trunc="" ;; esac
    if [ -n "$__trunc" ]; then
      WORK_ERROR="${__hidden_dir} hides more than ${WALK_HIDDEN_CAP} files from this gate, which is more than it will read on every stop. Narrow the ignore rule, or move that content out of the work tree."
      return 1
    fi
  done <<< "$(ignored_matching_paths . "${WORK_DENY[@]}")"

  local externally_hidden
  externally_hidden=$(
    ignored_matching_paths . "${WORK_DENY[@]}" \
      ':(exclude)node_modules' ':(exclude).svelte-kit' ':(exclude)dist' ':(exclude)build' \
      ':(exclude)test-results' ':(exclude)playwright-report' ':(exclude).turbo' |
      while IFS= read -r f; do
        # Matches nothing below (not a real path, not `src/`-prefixed, not
        # `.svelte`-suffixed) and would otherwise be silently dropped --
        # the sentinel line itself, not a WORK_ERROR, since WORK_ERROR set
        # inside this subshell is discarded; travels out the same way
        # WALK_TRUNCATED_SENTINEL does, checked once this subshell exits.
        if [ "$f" = "$NEWLINE_IN_PATH_SENTINEL" ]; then
          printf '%s\n' "$NEWLINE_IN_PATH_SENTINEL"
          continue
        fi
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
                 [ "$__i" = "$NEWLINE_IN_PATH_SENTINEL" ] && { echo hit; break; }
                 is_source "$__i" && { echo hit; break; }
               done)" ]; then __external=1; fi
          elif renders "$f"; then
            __external=1
          fi
        fi
        # Not `case "${__external:-}" in 1) ... esac`: this text is lexically
        # inside the externally_hidden=$( ... ) substitution above, and stock
        # macOS /bin/bash (3.2) cannot parse ANY case/esac there -- see
        # resolve_symlink_target's comment. Single-branch dispatch, so a plain
        # `if` is equivalent and avoids the construct entirely.
        if [ "${__external:-}" = "1" ]; then
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
              # Substring test via parameter expansion, not `case`, for the same
              # bash-3.2-inside-$(...) reason as above.
              if [ "${__names#*"$WALK_TRUNCATED_SENTINEL"}" != "$__names" ]; then
                printf 'externally-hidden-truncated:%s\n' "$f"
              fi
              # Propagated raw, not folded into a labelled marker like the
              # truncation case above: the OUTER check (after this whole
              # subshell exits, since WORK_ERROR set in here is discarded)
              # does an exact match on the bare sentinel value, shared with
              # every other site that can emit it.
              if [ "${__names#*"$NEWLINE_IN_PATH_SENTINEL"}" != "$__names" ]; then
                printf '%s\n' "$NEWLINE_IN_PATH_SENTINEL"
              fi
              printf '%s\n' "$__names" | while IFS= read -r inner; do
                [ -z "$inner" ] && continue
                [ "$inner" = "$WALK_TRUNCATED_SENTINEL" ] && continue
                [ "$inner" = "$NEWLINE_IN_PATH_SENTINEL" ] && continue
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
        fi
      done
  )
  if printf '%s' "$externally_hidden" | grep -qxF "$NEWLINE_IN_PATH_SENTINEL"; then
    WORK_ERROR="an ignored path contains a literal newline byte, which this gate cannot safely enumerate as a single path. Rename it, or move that content out of the work tree."
    return 1
  fi

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
  add_ignored_tracked "$tmpidx" . "${WORK_DENY[@]}"
  if [ -n "$WORK_ERROR" ]; then rm -f "$tmpidx" 2>/dev/null; return 1; fi
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
  local root baseline tmpidx names names_status p stashes hidden gitlinks
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$root" ]; then WORK_ERROR="not inside a git work tree"; return 1; fi

  # Not $(work_baseline): its WORK_ERROR assignment must survive.
  work_baseline || return 1
  baseline="$WORK_BASELINE"

  # Same refusal compute_work_hash makes, repeated here rather than inherited.
  # It IS reached anyway today -- review-board-signoff.sh runs compute_work_hash
  # after this clears -- but that is a property of the CALLER's ordering, and the
  # waiver half is the live half: WAIVER_FORBIDDEN going empty is what lets
  # `--grounds formatting-only` be recorded over a component. Depending on a
  # neighbouring script's call order for a fail-closed guarantee is exactly the
  # coincidence this file's own comments refuse elsewhere.
  local __state_src
  __state_src=$(state_dir_hides_source)
  if [ -n "$__state_src" ]; then
    WORK_ERROR="${STATE_DIR} holds source a waiver cannot cover: ${__state_src}. Nothing that renders, or that decides what renders, may live in the board's own state directory. Move it into the tree, where it is reviewable."
    return 1
  fi

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
  add_ignored_tracked "$tmpidx" . "${WORK_DENY[@]}"
  if [ -n "$WORK_ERROR" ]; then rm -f "$tmpidx" 2>/dev/null; return 1; fi
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
  # Gitlinks from the SAME materialized index, before it is removed. `git diff
  # --name-only` reports a changed gitlink as one opaque directory path --
  # `docs/vendor`, not `docs/vendor/Modal.svelte` -- exactly the collapse the
  # comment below already fixed for git-ignored directories, but that fix
  # never reached this case: an untracked embedded repo (`cd docs/vendor &&
  # git init`, no `.gitmodules`) waived cleanly with unreviewed components
  # inside it, because `docs/vendor` alone matches no WAIVER_NEVER pattern.
  # Expanded below, same as the ignored-directory case.
  gitlinks=$(GIT_INDEX_FILE="$tmpidx" git -c core.quotePath=false ls-files -s -- . 2>/dev/null | awk '$1=="160000" {print substr($0, index($0,$4))}')
  rm -f "$tmpidx" 2>/dev/null
  if [ $names_status -ne 0 ]; then WORK_ERROR="could not list changed paths against the baseline"; return 1; fi
  if [ -n "$gitlinks" ]; then
    local __gl __expanded
    while IFS= read -r __gl; do
      [ -z "$__gl" ] && continue
      # Drop the bare gitlink path -- it would match nothing in WAIVER_NEVER
      # and is not itself a file a reviewer could look at.
      names=$(printf '%s\n' "$names" | grep -vxF "$__gl")
      [ -d "${root}/${__gl}" ] || continue
      # --cached --others --exclude-standard, not plain `ls-files`: tracked
      # only missed everything not yet `git add`-ed inside the embedded
      # repo, and unlike `status`, `ls-files --others` is NOT affected by a
      # `status.showUntrackedFiles=no` set inside that repo's own config --
      # confirmed empirically, so this needs no override to stay correct
      # under that config lie.
      __expanded=$(git -C "${root}/${__gl}" ls-files --cached --others --exclude-standard 2>/dev/null | sed "s|^|${__gl}/|")
      [ -n "$__expanded" ] && names="${names}
${__expanded}"
      # Content the embedded repo's own .gitignore hides from the listing
      # above entirely -- a different mechanism, not covered by --others.
      # git COLLAPSES an entirely-ignored directory to one entry ("!!
      # ui/"), the same collapse already handled for this repo's own
      # ignored directories elsewhere in this file, so passing that bare
      # name through would match no WAIVER_NEVER pattern and waive cleanly
      # regardless of what is inside it. Not expanded to individual files
      # and matched normally, deliberately: is_artifact's src-first rule
      # needs a path relative to a SINGLE consistent root to mean anything,
      # and these paths are relative to the GITLINK's own root, which can
      # itself sit anywhere under this repo's src/ -- prefixing would make
      # an embedded node_modules read as "under src/, therefore source"
      # (wrong), and not prefixing would make an embedded build/ route read
      # as "starts with an artifact name" (also wrong), whenever the two
      # disagree about which is true. Simpler and safer instead: ANY
      # ignored-but-present content at all makes the whole gitlink
      # unwaivable outright. Waivers exist for trivial, `.claude`/`scripts`-
      # confined work; a gitlink carrying content this cannot individually
      # verify is not that, whatever the content turns out to be.
      # NOT scoped to just "!!" (ignored) lines: any status output at all --
      # untracked, modified, or ignored -- means content exists inside this
      # gitlink that the expansion above did not individually verify, and
      # this refuses on all three rather than trying to word a message
      # specific to each. Say so plainly instead of naming only one cause.
      if [ -n "$(git -C "${root}/${__gl}" -c status.showUntrackedFiles=all \
          status --porcelain --ignored=matching 2>/dev/null)" ]; then
        WORK_ERROR="${__gl} has content (untracked, modified, or hidden by its own ignore rules) that a waiver cannot individually verify. Convene the board, or commit and expose the content there."
        return 1
      fi
    done <<< "$gitlinks"
  fi

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
  # filter, because it decides what a waiver may cover. The empty-source arms are
  # byte-identical now, since ignore_source_is_external replaced both
  # hand-written classifications. Do not "sync" the FILTERS: this yields names for
  # WAIVER_NEVER, that one yields names plus contents for the hash.
  hidden=$(
    ignored_matching_paths . "${WORK_DENY[@]}" \
      ':(exclude)node_modules' ':(exclude).svelte-kit' ':(exclude)dist' ':(exclude)build' \
      ':(exclude)test-results' ':(exclude)playwright-report' ':(exclude).turbo' |
      while IFS= read -r f; do
        # Matches nothing below (not a real path, not `src/`-prefixed, not
        # `.svelte`-suffixed) and would otherwise be silently dropped --
        # the sentinel line itself, not a WORK_ERROR, since WORK_ERROR set
        # inside this subshell is discarded; travels out the same way
        # WALK_TRUNCATED_SENTINEL does, checked once this subshell exits.
        if [ "$f" = "$NEWLINE_IN_PATH_SENTINEL" ]; then
          printf '%s\n' "$NEWLINE_IN_PATH_SENTINEL"
          continue
        fi
        if ignore_source_is_external "$f"; then __external=1; else __external=""; fi
        # Same expansion-before-test fix as compute_work_hash, applied separately
        # because the two enumerations deliberately differ (see the note above).
        if [ -z "${__external:-}" ]; then
          if [ -d "$f" ]; then
            # is_hashable, not renders(): renders() answers "may a waiver cover
            # this", so its only non-src/static arms are .svelte/.html/.css and
            # four config names. A hidden directory of .ts/.js/.json was invisible.
            if [ -n "$(walk_hidden_dir "$f" | while IFS= read -r __i; do
                 [ "$__i" = "$NEWLINE_IN_PATH_SENTINEL" ] && { echo hit; break; }
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
            #
            # NOT `| grep -vxF "$WALK_TRUNCATED_SENTINEL"`: that quietly kept
            # whatever walk_hidden_dir enumerated up to WALK_HIDDEN_CAP and
            # discarded the one signal that it was incomplete, so a forbidden
            # component past the cap could sit outside the truncated slice and
            # a waiver would see nothing forbidden -- true today only because
            # compute_work_hash's OWN cap check happens to run right after and
            # catches the same directory a second time; this must not depend
            # on that coincidence. The sentinel travels through instead, same
            # as compute_work_hash's enumeration, and is checked once this
            # subshell exits (see below) -- WORK_ERROR set in here is discarded.
            walk_hidden_dir "$f"
          else printf '%s\n' "$f"
          fi
        fi
      done
  )
  if printf '%s' "$hidden" | grep -qxF "$WALK_TRUNCATED_SENTINEL"; then
    WORK_ERROR="an ignored directory hides more than ${WALK_HIDDEN_CAP} files from this gate, which is more than it will read on every stop. Narrow the ignore rule, or move that content out of the work tree."
    return 1
  fi
  if printf '%s' "$hidden" | grep -qxF "$NEWLINE_IN_PATH_SENTINEL"; then
    WORK_ERROR="an ignored path contains a literal newline byte, which this gate cannot safely enumerate as a single path. Rename it, or move that content out of the work tree."
    return 1
  fi
  hidden=$(printf '%s' "$hidden" | grep -vxF "$WALK_TRUNCATED_SENTINEL")
  [ -n "$hidden" ] && names="${names}
${hidden}"

  # renders(), not a hand-duplicated copy of its match loop: the two used to
  # be separate implementations of the same WAIVER_NEVER scan, and the case-
  # insensitivity fix there (see renders()'s comment) would have had to be
  # made twice, in two places that could silently drift apart again the way
  # they already had once.
  local out=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    renders "$p" && out="${out}${p}
"
  done <<< "$names"
  WAIVER_FORBIDDEN="$out"
}
