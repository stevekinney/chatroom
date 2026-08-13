#!/usr/bin/env bash
# Probes for the review board gate, run against a throwaway repo.
#
# The gate is the only thing standing between unreviewed work and "done", and it
# has shipped four separate fail-open defects (worktree `.git`-as-file, a
# sign-off that invalidated the hash it had just approved, an unborn HEAD
# writing the literal string "HEAD", and a waiver that cleared a component with
# no reviewer). Each of those was found by hand. These are the same probes,
# written down so the next one is found by running this.
#
#   bash .claude/hooks/review-board-gate.test.sh
set -uo pipefail

HOOKS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0

ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "${2:-}"; fail=$((fail + 1)); }

# A fresh repo with the hooks copied in and a baseline established.
new_repo() {
  local d
  d=$(mktemp -d) || return 1
  (
    cd "$d" || exit 1
    git init -q .
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

# The gate is a Stop hook: it exits 0 either way and signals through the JSON it
# prints, so exit status is not the answer. CLAUDE_PROJECT_DIR must be pinned to
# the sandbox — the gate reads it and would otherwise evaluate the real repo and
# report on work that has nothing to do with the probe.
gate() {
  local out
  out=$(cd "$1" && CLAUDE_PROJECT_DIR="$1" bash .claude/hooks/review-board-gate.sh </dev/null 2>&1)
  printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && return 1
  return 0
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
  gate "$d" && ok "work with no rendered surface stays waivable" ||
    no "work with no rendered surface stays waivable" "waiver recorded but the gate still blocked"
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
  sed -i '' 's/^WAIVED: comments-only$/WAIVED: because-i-said-so/' "$sig" 2>/dev/null ||
    sed -i 's/^WAIVED: comments-only$/WAIVED: because-i-said-so/' "$sig"
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
gate "$d" && no "unreviewed src change blocks" "gate allowed" || ok "unreviewed src change blocks"
rm -rf "$d"

d=$(new_repo) || exit 1
echo "x" >> "$d/CLAUDE.md"
gate "$d" && ok "a denylisted file alone does not convene a board" ||
  no "a denylisted file alone does not convene a board" "gate blocked"
rm -rf "$d"

d=$(new_repo) || exit 1
mkdir -p "$d/.claude/agents"
echo "x" > "$d/.claude/agents/some-agent.md"
gate "$d" && no ".claude/agents is reviewable work" "gate allowed" || ok ".claude/agents is reviewable work"
rm -rf "$d"

d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
rm -f "$d/.claude/.review-board-state/last-cleared"
gate "$d" && no "a missing baseline blocks rather than allows" "gate allowed" ||
  ok "a missing baseline blocks rather than allows"
rm -rf "$d"

d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
signoff "$d" --pass test-integrity-auditor --pass harness-skeptic \
  --pass contract-auditor --pass a11y-ssr-auditor >/dev/null 2>&1
gate "$d" && ok "a full four-PASS sign-off clears the gate" ||
  no "a full four-PASS sign-off clears the gate" "gate blocked after a complete sign-off"
if [ -d "$d" ]; then
  (cd "$d" && git add -A && git commit -qm work >/dev/null 2>&1)
  gate "$d" && ok "committing after a PASS does not invalidate it" ||
    no "committing after a PASS does not invalidate it" "gate blocked after committing cleared work"
fi
rm -rf "$d"

d=$(new_repo) || exit 1
echo "x" > "$d/src/routes/+page.svelte"
signoff "$d" --pass test-integrity-auditor --pass harness-skeptic >/dev/null 2>&1
gate "$d" && no "a partial sign-off blocks" "gate allowed with 2 of 4" || ok "a partial sign-off blocks"
rm -rf "$d"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
