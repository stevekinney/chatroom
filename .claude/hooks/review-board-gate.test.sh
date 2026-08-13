#!/usr/bin/env bash
# Probes for the review board gate, run against a throwaway repo.
#
# The gate is the only thing standing between unreviewed work and "done", and it
# has shipped defects in both directions: fail-OPEN (an unborn HEAD baselining to
# the literal string "HEAD"; a waiver clearing a component with no reviewer; an
# absolute `core.excludesFile` misread as in-tree) and fail-CLOSED (a linked
# worktree's `.git`-as-file blocking permanently with no way to clear it; a
# sign-off invalidating the hash it had just approved). Each was found by hand.
#
# Coverage is real but not total. There is no unborn-HEAD fixture, and no probe
# for the self-invalidating sign-off (both sign-off fixtures leave the work
# uncommitted, so mark_cleared writes the same HEAD and the re-record is a
# no-op). Nothing runs this file automatically — it is not wired into any script.
#
#   bash .claude/hooks/review-board-gate.test.sh
set -uo pipefail

HOOKS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fixtures below run `git add -A`, `git commit`, `git stash`, `git update-index`
# and `rm -rf` against $d. A generated runner once executed new_repo()'s body
# WITHOUT its `cd "$d"`, and `git add -A; git commit -qm base` ran against this
# repository, committing a stray seed.txt. new_repo's own path is asserted to be
# outside this repo before anything destructive runs. NOT asserted: the `ext=`
# and `wt=` mktemp roots individual probes create and rm -rf themselves.
__self_root=$(cd "$HOOKS_SRC/../.." && pwd)
assert_sandbox() {
  local d="$1" real
  real=$(cd "$d" 2>/dev/null && pwd -P) || {
    printf 'FATAL: fixture path does not exist: %s\n' "$d" >&2; exit 2; }
  case "$real" in
    "$__self_root"|"$__self_root"/*)
      printf 'FATAL: fixture resolved inside the real repo (%s); refusing to run destructive git commands there.\n' "$real" >&2
      exit 2 ;;
  esac
  printf '%s\n' "$real"
}
pass=0
fail=0

ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "${2:-}"; fail=$((fail + 1)); }

# A fresh repo with the hooks copied in and a baseline established.
new_repo() {
  local d
  d=$(mktemp -d) || return 1
  # BEFORE anything destructive. The previous version asserted after the subshell
  # below had already run `git init`, `git add -A` and `git commit`.
  assert_sandbox "$d" >/dev/null
  (
    cd "$d" || exit 1
    git init -q .
    git config core.excludesFile /dev/null
    git config user.email t@example.com
    git config user.name t
    mkdir -p .claude/hooks src/routes static scripts
    cp "$HOOKS_SRC"/work-hash.sh "$HOOKS_SRC"/review-board-gate.sh "$HOOKS_SRC"/review-board-signoff.sh .claude/hooks/
    echo seed > seed.txt
    git add -A
    git commit -qm base
    CLAUDE_PROJECT_DIR="$PWD" bash .claude/hooks/review-board-signoff.sh --initialize >/dev/null 2>&1
  ) || return 1
  printf '%s\n' "$d"
}

# Returns 0 for allow, 1 for block, 2 for "the gate did not run".
#
# The gate is a Stop hook: it exits 0 either way and signals through the JSON it
# prints, so exit status alone is not the answer. CLAUDE_PROJECT_DIR is pinned to
# the sandbox because the gate reads it and would otherwise evaluate the real
# repo. And absence of a refusal is not evidence of approval -- a gate replaced
# by `exit 0` once scored green on every probe asserting something clears -- so
# an allow has to be proven rather than inferred.
#
# This check lives entirely on the test side. An earlier version proved "the
# gate really ran" with an EXIT trap inside review-board-gate.sh, which put an
# env-controlled truncation of an arbitrary path into the one script everything
# else depends on -- production code carrying a hazard so the tests could watch
# it. Comparing the sandbox copy against the source gets the same
# discrimination for nothing: a stubbed or corrupted gate no longer matches.
gate() {
  local out rc
  cmp -s "$1/.claude/hooks/review-board-gate.sh" "$HOOKS_SRC/review-board-gate.sh" || return 2
  bash -n "$1/.claude/hooks/review-board-gate.sh" 2>/dev/null || return 2
  out=$(cd "$1" && CLAUDE_PROJECT_DIR="$1" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
  rc=$?
  printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && return 1
  [ "$rc" -eq 0 ] || return 2
  return 0
}

# A block probe must not accept "the gate crashed" as "the gate blocked". Adding
# an unbound variable to the gate made it die under `set -u` before deciding
# anything, and ten `gate "$d" && no ... || ok ...` call sites still reported ok.
expect_block() {
  local d="$1" name="$2"
  gate "$d"
  case $? in
    1) ok "$name" ;;
    0) no "$name" "gate allowed" ;;
    2) no "$name" "gate did not run to completion — block is unproven" ;;
  esac
}

# Distinguishes the three outcomes at a call site that expects an allow.
expect_allow() {
  local d="$1" name="$2"
  gate "$d"
  case $? in
    0) ok "$name" ;;
    1) no "$name" "gate blocked" ;;
    2) no "$name" "gate did not run to completion — allow is unproven" ;;
  esac
}

# Same for the sign-off script, which also cds to CLAUDE_PROJECT_DIR.
signoff() {
  local d="$1"; shift
  (cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh "$@")
}

echo "waiver guard"

# The defect: every ground is self-asserted and nothing checked it against the
# diff, so a dialog with no focus trap cleared the board under all five.
for ground in formatting-only comments-only revert-of-cleared generated-artifact advisor-approved; do
  d=$(new_repo) || { no "setup" "could not build a test repo"; break; }
  printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/+page.svelte"
  out=$(signoff "$d" --waive --grounds "$ground" --reason "r" 2>&1)
  if [ $? -eq 0 ]; then
    no "--grounds $ground is refused on a .svelte change" "waiver was accepted"
  elif ! printf '%s' "$out" | grep -q "not waivable"; then
    no "--grounds $ground is refused on a .svelte change" "refused for the wrong reason: $out"
  else
    ok "--grounds $ground is refused on a .svelte change"
  fi
  rm -rf "$d"
done

for path in static/robots.txt src/app.html src/lib/a.css; do
  d=$(new_repo) || break
  mkdir -p "$(dirname "$d/$path")"
  echo x > "$d/$path"
  if signoff "$d" --waive --grounds formatting-only --reason r >/dev/null 2>&1; then
    no "$path is not waivable" "waiver was accepted"
  else
    ok "$path is not waivable"
  fi
  rm -rf "$d"
done

# Proportionality is the point of the waiver: work with no rendered surface must
# still be waivable, or the guard has just deleted the feature.
d=$(new_repo) || exit 1
echo "# note" >> "$d/scripts/build.sh"
if signoff "$d" --waive --grounds comments-only --reason r >/dev/null 2>&1; then
  expect_allow "$d" "work with no rendered surface stays waivable"
else
  no "work with no rendered surface stays waivable" "waiver was refused"
fi
rm -rf "$d"

echo "waiver grounds are enforced by the gate, not only by the writer"

# The gate matched any `[a-z-]+` token, so it accepted grounds the signoff
# script would have rejected.
d=$(new_repo) || exit 1
echo "# note" >> "$d/scripts/build.sh"
signoff "$d" --waive --grounds comments-only --reason r >/dev/null 2>&1
sig=$(find "$d/.claude/.review-board-state/signoffs" -name '*.signoff' | head -1)
if [ -n "$sig" ]; then
  find "$d/.claude/.review-board-state/signoffs" -name '*.signoff' | while IFS= read -r f; do
    sed -i '' 's/^WAIVED: comments-only$/WAIVED: because-i-said-so/' "$f" 2>/dev/null ||
      sed -i 's/^WAIVED: comments-only$/WAIVED: because-i-said-so/' "$f"
  done
  if gate "$d"; then
    no "an off-list ground in the signoff file is rejected" "gate allowed 'because-i-said-so'"
  else
    ok "an off-list ground in the signoff file is rejected"
  fi
else
  no "an off-list ground in the signoff file is rejected" "no signoff file was written"
fi
rm -rf "$d"

echo "baseline and scope"

d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
expect_block "$d" "unreviewed src change blocks"
rm -rf "$d"

d=$(new_repo) || exit 1
echo "x" >> "$d/CLAUDE.md"
expect_allow "$d" "a denylisted file alone does not convene a board"
rm -rf "$d"

d=$(new_repo) || exit 1
mkdir -p "$d/.claude/agents"
echo "x" > "$d/.claude/agents/some-agent.md"
expect_block "$d" ".claude/agents is reviewable work"
rm -rf "$d"

# COMMIT the work first. With it uncommitted the gate blocks on the work itself
# whether or not the baseline is adopted, so the probe passed with work_baseline
# reverted to adopting HEAD -- which is the exact bypass it names.
d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
(cd "$d" && git add -A && git commit -qm work) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
expect_block "$d" "a missing baseline blocks rather than allows"
rm -rf "$d"

d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
signoff "$d" --pass test-integrity-auditor --pass harness-skeptic \
  --pass contract-auditor --pass a11y-ssr-auditor >/dev/null 2>&1
expect_allow "$d" "a full four-PASS sign-off clears the gate"
if [ -d "$d" ]; then
  (cd "$d" && git add -A && git commit -qm work >/dev/null 2>&1)
  expect_allow "$d" "committing after a PASS does not invalidate it"
fi
rm -rf "$d"

d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
signoff "$d" --pass test-integrity-auditor --pass harness-skeptic >/dev/null 2>&1
expect_block "$d" "a partial sign-off blocks"
rm -rf "$d"


echo "bypasses the guard must not have"

# A non-ASCII route segment: core.quotePath C-quotes the path, so the guard saw
# `"src/routes/caf\303\251/..."` -- starting with a quote, matching nothing.
d=$(new_repo) || exit 1
mkdir -p "$d/src/routes/café"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/café/+page.svelte"
if signoff "$d" --waive --grounds formatting-only --reason r >/dev/null 2>&1; then
  no "a non-ASCII path is not waivable" "waiver was accepted"
else
  ok "a non-ASCII path is not waivable"
fi
rm -rf "$d"

# Rename detection printed only the destination, so moving a component out of
# src/ showed no forbidden path at all.
d=$(new_repo) || exit 1
mkdir -p "$d/src/routes/demo" "$d/.claude/notes"
printf '<div role="dialog"></div>\n' > "$d/src/routes/demo/+page.svelte"
(cd "$d" && git add -A && git commit -qm add-route >/dev/null 2>&1)
# --initialize refuses when a baseline already exists, so re-baselining onto the
# commit that carries the route requires clearing it first. Without this the
# route never existed in the baseline and the probe proves nothing.
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize >/dev/null 2>&1)
(cd "$d" && git mv src/routes/demo/+page.svelte .claude/notes/old.txt >/dev/null 2>&1)
if signoff "$d" --waive --grounds generated-artifact --reason r >/dev/null 2>&1; then
  no "moving a component out of src/ is not waivable" "waiver was accepted"
else
  ok "moving a component out of src/ is not waivable"
fi
rm -rf "$d"

# Hidden by an ignore source outside the work tree: invisible to `git add -A`,
# so the guard could not see it while the gate could.
d=$(new_repo) || exit 1
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/secret.svelte"
printf 'src/routes/secret.svelte\n' >> "$d/.git/info/exclude"
echo "# c" >> "$d/scripts/build.sh"
if signoff "$d" --waive --grounds comments-only --reason r >/dev/null 2>&1; then
  no "an externally-hidden component is not waivable" "waiver was accepted"
else
  ok "an externally-hidden component is not waivable"
fi
rm -rf "$d"

# A stash can carry a whole component and the guard cannot enumerate one.
d=$(new_repo) || exit 1
printf '<div role="dialog"></div>\n' > "$d/src/routes/+page.svelte"
# Stash ONLY the component. `git add -A && git stash` also swept the untracked
# baseline file away, so the refusal came from work_baseline long before the
# stash guard ran and the probe passed with the guard deleted.
(cd "$d" && git add -A -- src/routes/+page.svelte >/dev/null 2>&1 && git stash -q -- src/routes/+page.svelte >/dev/null 2>&1)
echo "# c" >> "$d/scripts/build.sh"
if signoff "$d" --waive --grounds comments-only --reason r >/dev/null 2>&1; then
  no "work hidden in a stash is not waivable" "waiver was accepted"
else
  ok "work hidden in a stash is not waivable"
fi
rm -rf "$d"

# The guard must refuse, not permit, when it cannot evaluate the tree. The
# caller read the list through a command substitution, which discarded
# WORK_ERROR and turned every error path into "nothing forbidden".
d=$(new_repo) || exit 1
echo "# c" >> "$d/scripts/build.sh"
# The stash is the one condition ONLY waiver_forbidden_paths rejects -- every
# other unevaluable state (missing baseline, index bits) is caught earlier by
# compute_work_hash, so a probe built on those passes even with the guard gone.
# Asserting the "Cannot waive" prefix is what pins WORK_ERROR actually reaching
# the caller, which the original command substitution silently discarded.
printf 'x\n' > "$d/src/routes/parked.svelte"
(cd "$d" && git add -A -- src/routes/parked.svelte >/dev/null 2>&1 &&
  git stash -q -- src/routes/parked.svelte >/dev/null 2>&1)
out=$(signoff "$d" --waive --grounds comments-only --reason r 2>&1)
if [ $? -eq 0 ]; then
  no "an unevaluable tree refuses the waiver" "waiver was accepted"
elif ! printf '%s' "$out" | grep -q "Cannot waive"; then
  no "an unevaluable tree refuses the waiver" "refused, but not by the guard: $out"
else
  ok "an unevaluable tree refuses the waiver"
fi
rm -rf "$d"

# The suite must be able to tell "allowed" from "never ran".
d=$(new_repo) || exit 1
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.claude/hooks/review-board-gate.sh"
gate "$d"; rc=$?
[ "$rc" -eq 2 ] && ok "a stubbed-out gate reads as unproven, not as allow" ||
  no "a stubbed-out gate reads as unproven, not as allow" "gate() returned $rc"
rm -rf "$d"


# A directory-form rule in .git/info/exclude collapses to one `!! dir/` entry in
# `git status --ignored`, so an existence test written as `-f` was false and an
# entire route went unhashed -- the gate allowing it outright, no waiver needed.
d=$(new_repo) || exit 1
mkdir -p "$d/src/routes/secret"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/secret/+page.svelte"
printf 'src/routes/secret/\n' >> "$d/.git/info/exclude"
expect_block "$d" "a directory hidden by .git/info/exclude still blocks"
rm -rf "$d"

# work_baseline tells the user to run --initialize when the baseline no longer
# resolves; --initialize used to refuse because a baseline file existed, and
# --waive failed on the same broken baseline. Nothing could clear the repo.
d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
echo "0000000000000000000000000000000000000000" > "$d/.claude/.review-board-state/last-cleared"
if signoff "$d" --initialize >/dev/null 2>&1; then
  ok "an unresolvable baseline can be re-initialized"
else
  no "an unresolvable baseline can be re-initialized" "--initialize refused, leaving no way to clear the gate"
fi
rm -rf "$d"

# ...but a baseline that still resolves must keep refusing, or --initialize is
# just a bypass button that clears work with no reviewer and no record.
# Clean tree, so the separate "work in flight" guard cannot be what refuses --
# the fixture used to leave a component uncommitted, and that guard caught it
# even with this refusal deleted.
d=$(new_repo) || exit 1
out=$(signoff "$d" --initialize 2>&1)
if [ $? -eq 0 ]; then
  no "a resolvable baseline still refuses re-initialization" "--initialize re-baselined silently"
elif ! printf '%s' "$out" | grep -q "A baseline already exists"; then
  no "a resolvable baseline still refuses re-initialization" "refused for another reason: $out"
else
  ok "a resolvable baseline still refuses re-initialization"
fi
rm -rf "$d"


# The sandbox used to set core.excludesFile /dev/null and test only
# .git/info/exclude -- a RELATIVE source. The whole finding was that an ABSOLUTE
# core.excludesFile was misclassified as in-tree, so the suite deleted the one
# variable it needed to observe. These two set it deliberately.
d=$(new_repo) || exit 1
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/hidden.svelte"
# Named `.gitignore` deliberately: an absolute path ending that way is the
# shape that matches the in-tree `*/.gitignore` arm, and ordering the cases
# wrong silently swallows it. A probe using any other filename cannot catch it.
# OUTSIDE the repo: an excludes file placed inside it is itself untracked work,
# so the gate would block on that and the probe would pass for the wrong reason.
ext=$(mktemp -d) || exit 1
printf 'src/routes/hidden.svelte\n' > "$ext/.gitignore"
(cd "$d" && git config core.excludesFile "$ext/.gitignore")
# UNPROVEN, and labelled so rather than left looking like coverage. The guard it
# targets -- the absolute-path arm preceding `*/.gitignore` -- is real and was
# verified by hand against this machine's `core.excludesFile`. But reversing that
# ordering leaves this probe green, so it does not pin the guard, and two earlier
# attempts (a `.svelte` fixture masked by renders(), then a non-rendering one)
# both failed to discriminate. Do not read a pass here as the ordering being
# safe; check it by hand until someone finds a fixture that fails without it.
expect_block "$d" "[unproven] an absolute core.excludesFile does not hide a component"
rm -rf "$d" "$ext"

# Presence was hashed once; content inside was never hashed, so a sign-off
# covered a directory whose files could then be rewritten freely.
d=$(new_repo) || exit 1
mkdir -p "$d/hidden"
printf 'v1\n' > "$d/hidden/a.svelte"
printf 'hidden/\n' >> "$d/.git/info/exclude"
h1=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash -c 'source .claude/hooks/work-hash.sh; compute_work_hash; echo "$WORK_HASH"')
printf 'v2-rewritten\n' > "$d/hidden/a.svelte"
printf 'brand new\n' > "$d/hidden/b.svelte"
h2=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash -c 'source .claude/hooks/work-hash.sh; compute_work_hash; echo "$WORK_HASH"')
if [ -n "$h1" ] && [ "$h1" != "$h2" ]; then
  ok "content inside an ignored directory moves the work hash"
else
  no "content inside an ignored directory moves the work hash" "hash unchanged ($h1 -> $h2)"
fi
rm -rf "$d"

# ...and the waiver guard must see the component inside it, not just `hidden/`.
d=$(new_repo) || exit 1
mkdir -p "$d/hidden"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/hidden/modal.svelte"
printf 'hidden/\n' >> "$d/.git/info/exclude"
echo "# c" >> "$d/scripts/build.sh"
if signoff "$d" --waive --grounds comments-only --reason r >/dev/null 2>&1; then
  no "a component in an ignored directory is not waivable" "waiver was accepted"
else
  ok "a component in an ignored directory is not waivable"
fi
rm -rf "$d"


echo "work the gate cannot enumerate must block, not pass"

# Reachable only from a tag: the sweep read refs/heads, so deleting the branch
# after tagging hid a route while the commit stayed alive. Capture the starting
# branch by name -- guessing main/master left HEAD on the throwaway branch, so
# the commit was still on a branch and the probe passed under either sweep.
d=$(new_repo) || exit 1
base_branch=$(cd "$d" && git rev-parse --abbrev-ref HEAD)
(cd "$d" && git checkout -q -b tmpwork &&
  mkdir -p src/routes/parked &&
  printf '<div role="dialog"></div>\n' > src/routes/parked/+page.svelte &&
  git add -A -- src/routes/parked && git commit -qm parked && git tag parked &&
  git checkout -q "$base_branch" && git branch -qD tmpwork) >/dev/null 2>&1
# The baseline file is untracked; `git add -A` would sweep it onto the throwaway
# branch and the checkout would delete it, so the gate would block on a MISSING
# BASELINE and never reach the ref sweep. Pathspec above keeps it, but re-assert.
[ -f "$d/.claude/.review-board-state/last-cleared" ] ||
  (cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
expect_block "$d" "work reachable only from a tag still blocks"
rm -rf "$d"

# Uncommitted changes in a linked worktree are invisible from the main checkout.
d=$(new_repo) || exit 1
wt=$(mktemp -d)/wt
(cd "$d" && git worktree add -q -b feature "$wt") >/dev/null 2>&1
if [ -d "$wt" ]; then
  mkdir -p "$wt/src/routes"
  printf '<div role="dialog"></div>\n' > "$wt/src/routes/+page.svelte"
  expect_block "$d" "a dirty linked worktree blocks"
  (cd "$d" && git worktree remove --force "$wt") >/dev/null 2>&1
else
  no "a dirty linked worktree blocks" "could not create a worktree"
fi
rm -rf "$d"

# A route hidden by a pre-existing, unanchored IN-TREE .gitignore rule. No new
# rule is added, so "the rule change is itself reviewable" does not apply.
d=$(new_repo) || exit 1
(cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ignore) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
mkdir -p "$d/src/routes/tmp"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/tmp/+page.svelte"
expect_block "$d" "a route hidden by an in-tree .gitignore rule still blocks"
rm -rf "$d"

# ...while a non-rendering ignored path keeps its carve-out, or this would start
# hashing .env and every build artifact.
d=$(new_repo) || exit 1
(cd "$d" && printf 'secrets.txt\n' > .gitignore && git add -A && git commit -qm ignore) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
printf 'API_KEY=hunter2\n' > "$d/secrets.txt"
expect_allow "$d" "a non-rendering ignored file keeps its carve-out"
rm -rf "$d"

# A symlink under src/ pointing into a WORK_DENY path: the blob is 40 bytes, the
# surface behind it is unbounded and permanently unreviewable.
# Two steps, because one proves nothing: an untracked symlink is new work and
# the gate blocks on that alone, guard or no guard. What matters is whether the
# link can be CLEARED and its target then rewritten unreviewed.
for shape in dir file; do
  d=$(new_repo) || break
  mkdir -p "$d/docs/demo"
  printf '<h1>real</h1>\n' > "$d/docs/demo/+page.svelte"
  if [ "$shape" = dir ]; then (cd "$d/src/routes" && ln -s ../../docs/demo symdemo)
  else (cd "$d/src/routes" && ln -s ../../docs/demo/+page.svelte linked.svelte)
  fi
  out=$(signoff "$d" --pass test-integrity-auditor --pass harness-skeptic \
    --pass contract-auditor --pass a11y-ssr-auditor 2>&1)
  if printf '%s' "$out" | grep -q "symlink under a rendered root"; then
    ok "a $shape symlink from src/ into docs/ cannot be signed off"
  else
    # It signed off. Now rewrite the target and see whether the gate notices.
    printf '<div role="dialog" aria-modal="true">rewritten</div>\n' > "$d/docs/demo/+page.svelte"
    expect_block "$d" "a $shape symlink from src/ into docs/ cannot be signed off"
  fi
  rm -rf "$d"
done


# The artifact bound must be POSITIONAL. Pruning `build`/`dist`/`coverage` by
# name at any depth hid `src/routes/build/+page.svelte` -- a route SvelteKit
# compiles -- whenever an external ignore rule carried that name, which this
# machine's global gitignore does.
d=$(new_repo) || exit 1
mkdir -p "$d/src/routes/build"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/build/+page.svelte"
printf 'build/\n' >> "$d/.git/info/exclude"
expect_block "$d" "a route in a directory named build/ still blocks"
rm -rf "$d"

# ...while a real artifact tree at the root stays out, or the runtime regression
# comes straight back.
d=$(new_repo) || exit 1
mkdir -p "$d/coverage/lcov-report"
printf '<html>report</html>\n' > "$d/coverage/lcov-report/index.html"
printf 'coverage/\n' >> "$d/.git/info/exclude"
expect_allow "$d" "a root-level artifact directory stays out of the hash"
rm -rf "$d"

# Hidden non-.svelte source must be hashed too: a load function is the commonest
# hydration-mismatch source, and reusing renders() here dropped every .ts/.js.
d=$(new_repo) || exit 1
mkdir -p "$d/hidden/src/routes"
printf 'export const load = () => ({ v: 1 });\n' > "$d/hidden/src/routes/+page.ts"
printf 'hidden/\n' >> "$d/.git/info/exclude"
h1=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash -c '. .claude/hooks/work-hash.sh; compute_work_hash; echo "$WORK_HASH"')
printf 'export const load = () => ({ v: 2, injected: true });\n' > "$d/hidden/src/routes/+page.ts"
h2=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash -c '. .claude/hooks/work-hash.sh; compute_work_hash; echo "$WORK_HASH"')
if [ -n "$h1" ] && [ "$h1" != "$h2" ]; then
  ok "a load function hidden by an ignore rule moves the hash"
else
  no "a load function hidden by an ignore rule moves the hash" "hash unchanged ($h1 -> $h2)"
fi
rm -rf "$d"


# The bypass four documents claimed was shut: commit unreviewed work, delete the
# gitignored baseline, then run the --initialize the gate itself prints.
d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
signoff "$d" --pass test-integrity-auditor --pass harness-skeptic \
  --pass contract-auditor --pass a11y-ssr-auditor >/dev/null 2>&1
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/evil.svelte"
(cd "$d" && git add -A && git commit -qm sneak) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
if signoff "$d" --initialize >/dev/null 2>&1; then
  no "deleting the baseline plus --initialize is not a bypass" "--initialize cleared committed unreviewed work"
else
  ok "deleting the baseline plus --initialize is not a bypass"
fi
rm -rf "$d"

# An embedded git repo with no .gitmodules: `git submodule foreach` reads that
# file, so keying the guard on it meant `rm .gitmodules` disabled the check.
d=$(new_repo) || exit 1
mkdir -p "$d/src/lib/vendor"
(cd "$d/src/lib/vendor" && git init -q . && git config user.email t@e && git config user.name t &&
  printf '<h1>v</h1>\n' > V.svelte && git add -A && git commit -qm v) >/dev/null 2>&1
(cd "$d" && git add -A && git commit -qm embed) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
# Two steps: the gitlink diff shows `-dirty` on the FIRST change, so a one-step
# probe blocks via the diff and never reaches the guard. That marker saturates,
# so sign off while dirty and then rewrite the content -- which is when the
# guard is the only thing left that can see it.
printf '<h1>v2</h1>\n' > "$d/src/lib/vendor/V.svelte"
signoff "$d" --pass test-integrity-auditor --pass harness-skeptic \
  --pass contract-auditor --pass a11y-ssr-auditor >/dev/null 2>&1
printf '<div role="dialog" aria-modal="true">unreviewed</div>\n' > "$d/src/lib/vendor/V.svelte"
printf 'export const load = () => ({});\n' > "$d/src/lib/vendor/extra.ts"
expect_block "$d" "a dirty embedded repo with no .gitmodules blocks"
rm -rf "$d"

# A DETACHED linked worktree: its HEAD is per-worktree and outside refs/, so
# committing there does not make the work visible to the ref sweep either.
d=$(new_repo) || exit 1
wt=$(mktemp -d)/wt
(cd "$d" && git worktree add -q --detach "$wt") >/dev/null 2>&1
if [ -d "$wt" ]; then
  expect_block "$d" "a detached linked worktree blocks"
  (cd "$d" && git worktree remove --force "$wt") >/dev/null 2>&1
else
  no "a detached linked worktree blocks" "could not create a detached worktree"
fi
rm -rf "$d"


# core.quotePath C-quotes non-ASCII paths, so the IGNORE enumeration received
# `"src/routes/caf\303\251/"`, check-ignore exited 1 on it, and the entry fell
# out of the hash entirely. The fix had reached the diff enumeration only.
d=$(new_repo) || exit 1
mkdir -p "$d/src/routes/café"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/café/+page.svelte"
printf 'src/routes/café/\n' >> "$d/.git/info/exclude"
expect_block "$d" "a non-ASCII path hidden by an ignore rule still blocks"
rm -rf "$d"

# The find prune matched artifact names at ANY depth and ran BEFORE is_artifact,
# so it discarded `src/routes/node_modules/+page.svelte` before the positional
# bound could keep it -- and this repo's own .gitignore line 1 is unanchored.
d=$(new_repo) || exit 1
(cd "$d" && printf 'node_modules\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
mkdir -p "$d/src/routes/node_modules"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/node_modules/+page.svelte"
expect_block "$d" "a route under a node_modules path segment still blocks"
rm -rf "$d"

# Build config decides what SSRs and how it hydrates; a waiver must not cover it.
d=$(new_repo) || exit 1
printf 'export default { ssr: { noExternal: true } };\n' > "$d/vite.config.ts"
if signoff "$d" --waive --grounds formatting-only --reason r >/dev/null 2>&1; then
  no "build config is not waivable" "waiver was accepted for vite.config.ts"
else
  ok "build config is not waivable"
fi
rm -rf "$d"

# A root-level config symlink in a shape the scan missed: .cjs is the required
# form for a PostCSS config in an ESM package and rewrites every byte of CSS.
d=$(new_repo) || exit 1
mkdir -p "$d/docs"
printf 'module.exports = {};\n' > "$d/docs/p.cjs"
(cd "$d" && ln -s docs/p.cjs postcss.config.cjs)
out=$(signoff "$d" --pass test-integrity-auditor --pass harness-skeptic \
  --pass contract-auditor --pass a11y-ssr-auditor 2>&1)
if printf '%s' "$out" | grep -q "symlink under a rendered root"; then
  ok "a root-level .cjs config symlink cannot be signed off"
else
  printf 'module.exports = { plugins: { evil: {} } };\n' > "$d/docs/p.cjs"
  expect_block "$d" "a root-level .cjs config symlink cannot be signed off"
fi
rm -rf "$d"


# is_artifact anchored at the path start, so a NESTED artifact tree -- the exact
# `.claude/worktrees/**/build/` case the bound exists for -- was never pruned.
# 3000 chunks took 6.30s against 0.26s name-based; this must stay fast AND stay
# out of the hash, without pruning anything under a rendered root.
d=$(new_repo) || exit 1
mkdir -p "$d/nested/build/_app"
for i in 1 2 3 4 5; do echo "chunk$i" > "$d/nested/build/_app/c$i.js"; done
printf 'nested/\n' >> "$d/.git/info/exclude"
expect_allow "$d" "a nested artifact tree stays out of the hash"
rm -rf "$d"

# HASHABLE_EXT was an allowlist in a file whose scope rule is a denylist, so
# .scss/.mts/.jsx/.tsx/.vue under a hidden src/ hashed to nothing.
d=$(new_repo) || exit 1
mkdir -p "$d/hidden/src"
printf 'a{color:red}\n' > "$d/hidden/src/a.scss"
printf 'hidden/\n' >> "$d/.git/info/exclude"
h1=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash -c '. .claude/hooks/work-hash.sh; compute_work_hash; echo "$WORK_HASH"')
printf 'a{color:blue}\n' > "$d/hidden/src/a.scss"
h2=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash -c '. .claude/hooks/work-hash.sh; compute_work_hash; echo "$WORK_HASH"')
if [ -n "$h1" ] && [ "$h1" != "$h2" ]; then
  ok "an unlisted source extension in a hidden directory moves the hash"
else
  no "an unlisted source extension in a hidden directory moves the hash" "hash unchanged ($h1 -> $h2)"
fi
rm -rf "$d"

# Machine noise must not convene a board: .DS_Store changes when Finder opens a
# folder, and Claude Code rewrites settings.local.json on a permission grant --
# so the gate could invalidate its own sign-off through an action it provoked.
d=$(new_repo) || exit 1
printf 'x\n' > "$d/.DS_Store"
mkdir -p "$d/.claude" && printf '{}\n' > "$d/.claude/settings.local.json"
printf '.DS_Store\nsettings.local.json\n' >> "$d/.git/info/exclude"
expect_allow "$d" "machine noise does not convene a board"
rm -rf "$d"


# docs/ and .vscode/ were in WORK_DENY but the bundler resolves relative imports
# into them, so they were a permanent hiding place: one board round on the import
# line, then every component added afterwards was free. import.meta.glob made
# even the first free. This is the shape the symlink guard defended against,
# reachable without any symlink at all.
d=$(new_repo) || exit 1
mkdir -p "$d/docs"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/docs/Widget.svelte"
expect_block "$d" "a component under docs/ is reviewable work"
rm -rf "$d"

# The state dir must never be inside the hashed set. When an external rule put it
# there, four PASSes printed "cleared" and the gate blocked anyway, each retry
# writing two more signoffs and moving the hash further away -- unrecoverable.
d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
printf '.claude/.review-board-state/\n' >> "$d/.git/info/exclude"
out=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
if printf '%s' "$out" | grep -q "would make every sign-off invalidate itself"; then
  ok "an externally-ignored state dir is diagnosed, not livelocked"
else
  no "an externally-ignored state dir is diagnosed, not livelocked" "no diagnostic: $(printf '%s' "$out" | head -c 80)"
fi
rm -rf "$d"

# Istanbul's own layout puts `src` BELOW the artifact root. Escaping on any `src`
# segment regardless of position hashed 3000 coverage files at 7.05s and blocked.
# The scan is left-to-right now: first matching segment decides.
d=$(new_repo) || exit 1
mkdir -p "$d/coverage/lcov-report/src"
for i in 1 2 3; do printf '<html>%s</html>\n' "$i" > "$d/coverage/lcov-report/src/f$i.html"; done
printf 'coverage/\n' >> "$d/.git/info/exclude"
expect_allow "$d" "an artifact root wins over a src segment below it"
rm -rf "$d"


# `git status --ignored=matching` emits the collapsed `tmp/`, never its files, so
# renders() could only ever hit its src/static prefix arms and the extension arms
# were structurally unreachable. A dialog under a gitignored dir was invisible
# while SvelteKit compiled and SSR'd it -- the docs/ hole, via .gitignore.
d=$(new_repo) || exit 1
(cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
mkdir -p "$d/tmp"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/tmp/HiddenDialog.svelte"
expect_block "$d" "a component in a gitignored directory outside src/ still blocks"
rm -rf "$d"

# package.json pins the @lostgradient/* versions, so a formatting-only waiver on
# a chat bump changed every ARIA attribute and line of SSR output with no board.
d=$(new_repo) || exit 1
printf '{"dependencies":{"@lostgradient/chat":"9.9.9"}}\n' > "$d/package.json"
if signoff "$d" --waive --grounds formatting-only --reason r >/dev/null 2>&1; then
  no "a package.json version bump is not waivable" "waiver was accepted"
else
  ok "a package.json version bump is not waivable"
fi
rm -rf "$d"

# The ignore-source rule was written three times and ordered correctly twice.
# The state-dir check matched an absolute ~/.gitignore against the in-tree arm,
# so the diagnostic never fired and the livelock it exists to stop was live.
d=$(new_repo) || exit 1
ext=$(mktemp -d) || exit 1
printf '.claude/.review-board-state/\n' > "$ext/.gitignore"
(cd "$d" && git config core.excludesFile "$ext/.gitignore")
echo "x" > "$d/src/routes/+page.svelte"
out=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
if printf '%s' "$out" | grep -q "would make every sign-off invalidate itself"; then
  ok "an absolute excludes file hiding the state dir is diagnosed"
else
  no "an absolute excludes file hiding the state dir is diagnosed" "no diagnostic"
fi
rm -rf "$d" "$ext"


echo "the cap: fails closed, at the boundary, in both locations"

# No probe covered the cap at all, which is what let a fail-open ship: the
# truncation pre-check applied its predicates to the collapsed DIRECTORY path
# while the enumeration applied its own to the FILES inside, so a root-level
# `tmp/` was checked by neither and a component past the cap vanished.
for loc in "tmp" "src/routes/tmp"; do
  d=$(new_repo) || break
  (cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
  rm -f "$d/.claude/.review-board-state/last-cleared"
  (cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
  mkdir -p "$d/$loc"
  i=1; while [ "$i" -le 800 ]; do printf 'n\n' > "$d/$loc/a$(printf '%04d' $i).md"; i=$((i+1)); done
  printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/$loc/zzz-late.svelte"
  out=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
  if printf '%s' "$out" | grep -q "hides more than"; then
    ok "a directory past the cap blocks by name ($loc)"
  else
    no "a directory past the cap blocks by name ($loc)" "gate did not name it: $(printf '%s' "$out" | head -c 60)"
  fi
  rm -rf "$d"
done

# Under the cap must still evaluate normally, or the bound has eaten the feature.
d=$(new_repo) || exit 1
(cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
mkdir -p "$d/tmp"
i=1; while [ "$i" -le 20 ]; do printf 'n\n' > "$d/tmp/a$i.md"; i=$((i+1)); done
printf '<div role="dialog"></div>\n' > "$d/tmp/zzz.svelte"
out=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
if ! printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
  no "a directory under the cap still blocks on its contents" "gate allowed"
elif printf '%s' "$out" | grep -q "hides more than"; then
  no "a directory under the cap still blocks on its contents" "blocked by truncation, not contents — the bound ate the feature"
else
  ok "a directory under the cap still blocks on its contents"
fi
rm -rf "$d"

# find's stderr is swallowed, so an unreadable directory was byte-identical on
# stdout to an empty one -- `chmod 000` was a one-command fail-open.
d=$(new_repo) || exit 1
(cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
mkdir -p "$d/tmp/inner" && printf '<div role="dialog"></div>\n' > "$d/tmp/inner/C.svelte"
chmod 000 "$d/tmp"
out=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
chmod 755 "$d/tmp"
printf '%s' "$out" | grep -q "cannot be read" &&
  ok "an unreadable ignored directory blocks rather than reading as empty" ||
  no "an unreadable ignored directory blocks rather than reading as empty" "gate was silent"
rm -rf "$d"

# SKILL.md decides whether the board convenes at all; the agent files decide what
# each member looks for. They are one indirection out from .claude/hooks, which
# the code already calls a total bypass worth guarding.
d=$(new_repo) || exit 1
ext=$(mktemp -d) || exit 1
mkdir -p "$d/.claude/agents"
printf 'charter\n' > "$ext/agent.md"
(cd "$d/.claude/agents" && ln -s "$ext/agent.md" a11y-ssr-auditor.md)
out=$(signoff "$d" --pass test-integrity-auditor --pass harness-skeptic \
  --pass contract-auditor --pass a11y-ssr-auditor 2>&1)
printf '%s' "$out" | grep -q "symlink under a rendered root" &&
  ok "a symlink on the board's own charter cannot be signed off" ||
  no "a symlink on the board's own charter cannot be signed off" "signed off cleanly"
rm -rf "$d" "$ext"


# `src/` is the WAIVER_NEVER arm carrying .ts/.js -- every other probe survives
# its removal on .svelte/.html/.css, so a `+page.server.ts` waived cleanly. The
# file's own comment calls load functions the commonest hydration-mismatch source.
d=$(new_repo) || exit 1
printf 'export const load = () => ({});\n' > "$d/src/routes/+page.server.ts"
if signoff "$d" --waive --grounds formatting-only --reason r >/dev/null 2>&1; then
  no "a load function under src/ is not waivable" "waiver was accepted"
else
  ok "a load function under src/ is not waivable"
fi
rm -rf "$d"

# The waiver-side in-tree expansion: the hash side of this was fixed and probed,
# the waiver side was neither. Fixture must use an IN-TREE .gitignore, or
# ignore_source_is_external short-circuits and the branch never runs.
d=$(new_repo) || exit 1
(cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
mkdir -p "$d/tmp"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/tmp/Modal.svelte"
echo "# c" >> "$d/scripts/build.sh"
if signoff "$d" --waive --grounds comments-only --reason r >/dev/null 2>&1; then
  no "a component in an in-tree ignored directory is not waivable" "waiver was accepted"
else
  ok "a component in an in-tree ignored directory is not waivable"
fi
rm -rf "$d"

# -L is credited by three comments with fixing a shipped bug and watched by none.
d=$(new_repo) || exit 1
ext=$(mktemp -d) || exit 1
(cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
mkdir -p "$d/tmp"; printf '<div role="dialog"></div>\n' > "$ext/Widget.svelte"
(cd "$d/tmp" && ln -s "$ext" parts)
expect_block "$d" "a component behind a symlink inside an ignored directory blocks"
rm -rf "$d" "$ext"


echo "diff drivers cannot empty the hash"

# A textconv driver makes git omit changed paths ENTIRELY -- no `Binary files
# differ`, no `index <old>..<new>` -- so even blob OIDs disappear. Installed via
# core.attributesFile it needs no tracked-file change, so there is no first board
# round to catch the setup.
d=$(new_repo) || exit 1
ext=$(mktemp -d) || exit 1
printf '* diff=tc\n' > "$ext/attrs"
printf '#!/bin/sh\necho constant\n' > "$ext/tc.sh"; chmod +x "$ext/tc.sh"
(cd "$d" && git config core.attributesFile "$ext/attrs" && git config diff.tc.textconv "$ext/tc.sh")
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/+page.svelte"
(cd "$d" && git add -A && git commit -qm add) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
printf '<div role="dialog" aria-modal="true"><input placeholder="unreviewed"/></div>\n' > "$d/src/routes/+page.svelte"
expect_block "$d" "a textconv diff driver cannot empty the hash"
rm -rf "$d" "$ext"

# GIT_EXTERNAL_DIFF is the same class through the environment: no file anywhere.
d=$(new_repo) || exit 1
printf '<div role="dialog"></div>\n' > "$d/src/routes/+page.svelte"
out=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" GIT_EXTERNAL_DIFF=/usr/bin/true \
  bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' &&
  ok "GIT_EXTERNAL_DIFF cannot empty the hash" ||
  no "GIT_EXTERNAL_DIFF cannot empty the hash" "gate was silent"
rm -rf "$d"


# Deleting the baseline was refused when sign-offs existed; CORRUPTING it took
# the other branch and re-established anyway. The gate's own error text used to
# instruct the operator to run exactly that.
d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
signoff "$d" --pass test-integrity-auditor --pass harness-skeptic \
  --pass contract-auditor --pass a11y-ssr-auditor >/dev/null 2>&1
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/src/routes/evil.svelte"
(cd "$d" && git add -A && git commit -qm sneak) >/dev/null 2>&1
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$d/.claude/.review-board-state/last-cleared"
if signoff "$d" --initialize >/dev/null 2>&1; then
  no "corrupting the baseline plus --initialize is not a bypass" "--initialize re-established over committed unreviewed work"
else
  ok "corrupting the baseline plus --initialize is not a bypass"
fi
rm -rf "$d"

# ...but a repo that has never been gated must still be able to recover.
d=$(new_repo) || exit 1
rm -rf "$d/.claude/.review-board-state/signoffs"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$d/.claude/.review-board-state/last-cleared"
if signoff "$d" --initialize >/dev/null 2>&1; then
  ok "an unresolvable baseline with no sign-offs can still be re-established"
else
  no "an unresolvable baseline with no sign-offs can still be re-established" "--initialize refused, leaving no recovery"
fi
rm -rf "$d"


# The .html/.css arms of WAIVER_NEVER exist to catch a rendered file OUTSIDE
# src/ and static/. Every existing fixture sat under src/, so the `src/` prefix
# arm carried them and both extensions were deletable with the suite green.
for path in "assets/theme.css" "emails/welcome.html"; do
  d=$(new_repo) || break
  mkdir -p "$d/$(dirname "$path")"
  printf 'x\n' > "$d/$path"
  if signoff "$d" --waive --grounds formatting-only --reason r >/dev/null 2>&1; then
    no "$path outside src/ is not waivable" "waiver was accepted"
  else
    ok "$path outside src/ is not waivable"
  fi
  rm -rf "$d"
done

# The stash probe asserted a bare exit status, so it could not tell the stash
# guard's refusal from the ref sweep catching the same component via `src/`.
d=$(new_repo) || exit 1
printf 'notes\n' > "$d/scripts/notes.txt"
(cd "$d" && git add -A -- scripts/notes.txt >/dev/null 2>&1 && git stash -q -- scripts/notes.txt) >/dev/null 2>&1
mkdir -p "$d/scripts"   # git stash removed the now-empty dir, so this append failed
echo "# c" >> "$d/scripts/build.sh"
out=$(signoff "$d" --waive --grounds comments-only --reason r 2>&1)
if [ $? -eq 0 ]; then
  no "the stash guard itself refuses, not the ref sweep" "waiver was accepted"
elif ! printf '%s' "$out" | grep -q "stash entry"; then
  no "the stash guard itself refuses, not the ref sweep" "refused by something else: $(printf '%s' "$out" | head -c 60)"
else
  ok "the stash guard itself refuses, not the ref sweep"
fi
rm -rf "$d"


# Descending a directory needs the SEARCH bit. `chmod 000` clears read AND
# search, which is why a probe written for it passed while `chmod 400` -- a
# genuinely readable, un-descendable directory -- produced a hash identical to
# the directory being absent. Sign off, then materialize a component behind it.
for mode in 400 000; do
  d=$(new_repo) || break
  (cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
  rm -f "$d/.claude/.review-board-state/last-cleared"
  (cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
  mkdir -p "$d/tmp/inner"
  printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/tmp/inner/C.svelte"
  chmod "$mode" "$d/tmp/inner"
  out=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
  chmod 755 "$d/tmp/inner"
  printf '%s' "$out" | grep -q "cannot be read" &&
    ok "a chmod $mode directory inside an ignored tree blocks" ||
    no "a chmod $mode directory inside an ignored tree blocks" "gate was silent"
  rm -rf "$d"
done

# An unreadable FILE: cat/shasum swallow EPERM, so the name reached the hash and
# the content did not -- arbitrary content changes invisible with no error.
d=$(new_repo) || exit 1
(cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
mkdir -p "$d/tmp"; printf '<div role="dialog"></div>\n' > "$d/tmp/C.svelte"; chmod 000 "$d/tmp/C.svelte"
out=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
chmod 644 "$d/tmp/C.svelte"
printf '%s' "$out" | grep -q "cannot be read" &&
  ok "an unreadable file inside an ignored tree blocks" ||
  no "an unreadable file inside an ignored tree blocks" "gate was silent"
rm -rf "$d"


# The notes sentinel is a forgery defence and nothing watched it: replacing the
# awk truncation with `cat` left the whole suite green. One `>>` on a gitignored
# file forges three of four vetoes.
d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
signoff "$d" --pass test-integrity-auditor >/dev/null 2>&1
sig=$(find "$d/.claude/.review-board-state/signoffs" -name '*.signoff' | head -1)
if [ -n "$sig" ]; then
  printf 'harness-skeptic: PASS\ncontract-auditor: PASS\na11y-ssr-auditor: PASS\n' >> "$sig"
  expect_block "$d" "PASS lines pasted after the notes sentinel do not count"
else
  no "PASS lines pasted after the notes sentinel do not count" "no signoff file written"
fi
rm -rf "$d"

# The depth refusal was the other unprobed live fail-open: walk_hidden_dir's
# -maxdepth 12 walks past a deeper component silently, so without the refusal an
# SSR'd unreviewed route clears the gate.
d=$(new_repo) || exit 1
(cd "$d" && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm ign) >/dev/null 2>&1
rm -f "$d/.claude/.review-board-state/last-cleared"
(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-signoff.sh --initialize) >/dev/null 2>&1
mkdir -p "$d/tmp/a/b/c/e/f/g/h/i/j/k/l/m"
printf '<div role="dialog" aria-modal="true"></div>\n' > "$d/tmp/a/b/c/e/f/g/h/i/j/k/l/m/+page.svelte"
out=$(cd "$d" && CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
printf '%s' "$out" | grep -q "nests deeper" &&
  ok "a component below the walk's depth bound blocks" ||
  no "a component below the walk's depth bound blocks" "gate did not refuse on depth"
rm -rf "$d"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
