#!/usr/bin/env bash
# Stop-hook gate: no body of work is complete until the adversarial review board
# has signed off on THIS exact body of work.
#
# Everything here fails closed. An earlier version exited 0 on every error path,
# so a corrupt index, a missing helper, or an absent `shasum` all read as
# "approved". A gate that cannot evaluate the work must block it.
set -uo pipefail

emit_block() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$1" '{decision: "block", reason: $r}'
  else
    local esc=${1//\\/\\\\}
    esc=${esc//\"/\\\"}
    esc=${esc//$'\n'/\\n}
    printf '{"decision":"block","reason":"%s"}\n' "$esc"
  fi
  exit 0
}

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null ||
  emit_block "The review-board gate could not enter the project directory, so it cannot verify this work has been reviewed."

command -v git >/dev/null 2>&1 ||
  emit_block "The review-board gate needs git to determine what changed, and git is not available."

git rev-parse --git-dir >/dev/null 2>&1 || exit 0 # genuinely not a repo: nothing to gate

helper="$(dirname "${BASH_SOURCE[0]}")/work-hash.sh"
[ -r "$helper" ] ||
  emit_block "The review-board gate is missing its helper (${helper}). It cannot evaluate this work, and a gate that cannot see the work must not clear it."
# shellcheck source=./work-hash.sh
. "$helper" ||
  emit_block "The review-board gate could not load ${helper}."

compute_work_hash
work_hash="$WORK_HASH"
if [ -n "$WORK_ERROR" ]; then
  emit_block "The review-board gate could not evaluate this work: ${WORK_ERROR}

Until that is resolved the work cannot be marked complete."
fi
[ -z "$work_hash" ] && exit 0 # no substantive work in flight

signoff="${SIGNOFF_DIR}/${work_hash}.signoff"

if [ -f "$signoff" ]; then
  # Parse only the verdict block. Notes are written after a sentinel and are
  # never scanned: an earlier version grepped the whole file, so PASS lines
  # pasted into a note satisfied members who had never reviewed anything.
  verdicts=$(awk -v s="$NOTES_SENTINEL" 'index($0, s) {exit} {print}' "$signoff" 2>/dev/null)
  # A waiver clears the gate without a board, on one of the recorded grounds.
  # Parsed from the verdict block for the same reason the PASS lines are: free
  # text after the sentinel must never be able to forge one.
  # The ground must be one of the recorded set. Matching any `[a-z-]+` token let
  # the deciding component accept grounds the writing component would reject,
  # so the fixed list was enforced on only one of the two paths.
  waived_ground=$(printf '%s\n' "$verdicts" | sed -n 's/^WAIVED: \([a-z-]*\)$/\1/p' | head -1)
  if [ -n "$waived_ground" ]; then
    for g in "${WAIVER_GROUNDS[@]}"; do
      [ "$waived_ground" = "$g" ] && exit 0
    done
  fi
  missing=()
  for r in "${REVIEW_BOARD[@]}"; do
    [ "$(printf '%s\n' "$verdicts" | grep -cE "^${r}: PASS$")" = "1" ] || missing+=("$r")
  done
  if [ ${#missing[@]} -eq 0 ]; then exit 0; fi
  emit_block "An adversarial review board sign-off exists for this exact work, but it is incomplete. Still missing a PASS from: ${missing[*]}.

All four members have veto power and all four must PASS on the work as it now stands. Convene the missing reviewers via the review-board skill, resolve what they find, and record their verdicts. A FAIL is resolved by fixing the finding, or by refuting it with evidence you can show -- never by rewording it."
fi

emit_block "This body of work has not been through the adversarial review board, so it is not complete.

Run the \`review-board\` skill. It convenes four reviewers in parallel, each with veto power:
  - test-integrity-auditor: proves every new or changed test actually fails when the behavior it pins is broken
  - harness-skeptic: challenges whether each finding is real or a happy-dom / testing-library artifact
  - contract-auditor: checks docs, types, READMEs, changesets, and issue state still match the code
  - a11y-ssr-auditor: keyboard reachability, focus, announcements, and hydration

All four must return PASS on the work as it currently stands. Findings are resolved by fixing them, or by refuting them with evidence you can show; a finding is never resolved by restating it.

If a reviewer genuinely cannot be satisfied -- a harness limitation makes something unprovable, say -- that is reportable, not skippable: name the reviewer, the criterion, what you tried, and what would settle it, then ask the user how to proceed."
