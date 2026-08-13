#!/usr/bin/env bash
# Stop-hook gate: no body of work is complete until the adversarial review board
# has signed off on THIS exact body of work.
#
# The board is four agents, each with veto power. The `review-board` skill runs
# them; review-board-signoff.sh records the result this script validates.
#
# The sign-off is keyed to a hash of the work itself, so changing anything after
# a PASS invalidates it. That is deliberate: "completely satisfy" means the board
# approved what actually ships, not an earlier draft of it.
set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# shellcheck source=./work-hash.sh
. "$(dirname "${BASH_SOURCE[0]}")/work-hash.sh" 2>/dev/null || exit 0

work_hash=$(compute_work_hash)
# No substantive work in flight, or the hash could not be computed: no gate.
[ -z "$work_hash" ] && exit 0

signoff="${SIGNOFF_DIR}/${work_hash}.signoff"

if [ -f "$signoff" ]; then
  missing=()
  for r in "${REVIEW_BOARD[@]}"; do
    grep -qE "^${r}: PASS$" "$signoff" 2>/dev/null || missing+=("$r")
  done
  [ ${#missing[@]} -eq 0 ] && exit 0
  reason="An adversarial review board sign-off exists for this exact work, but it is incomplete. Still missing a PASS from: ${missing[*]}.

All four members have veto power and all four must PASS on the work as it now stands. Convene the missing reviewers via the review-board skill, resolve what they find, and record their verdicts. A FAIL is resolved by fixing the finding, or by refuting it with evidence you can show -- never by rewording it."
else
  reason="This body of work has not been through the adversarial review board, so it is not complete.

Run the \`review-board\` skill. It convenes four reviewers in parallel, each with veto power:
  - test-integrity-auditor: proves every new or changed test actually fails when the behavior it pins is broken
  - harness-skeptic: challenges whether each finding is real or a happy-dom / testing-library artifact
  - contract-auditor: checks docs, types, READMEs, changesets, and issue state still match the code
  - a11y-ssr-auditor: keyboard reachability, focus, announcements, and hydration

All four must return PASS on the work as it currently stands. Findings are resolved by fixing them, or by refuting them with evidence you can show; a finding is never resolved by restating it.

If a reviewer genuinely cannot be satisfied -- a harness limitation makes something unprovable, say -- that is reportable, not skippable: name the reviewer, the criterion, what you tried, and what would settle it, then ask the user how to proceed."
fi

# Escape for JSON without assuming jq is present.
if command -v jq >/dev/null 2>&1; then
  jq -n --arg r "$reason" '{decision: "block", reason: $r}'
else
  esc=${reason//\\/\\\\}
  esc=${esc//\"/\\\"}
  esc=${esc//$'\n'/\\n}
  printf '{"decision":"block","reason":"%s"}\n' "$esc"
fi
exit 0
