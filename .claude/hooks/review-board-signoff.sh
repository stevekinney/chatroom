#!/usr/bin/env bash
# Record an adversarial review board sign-off for the current body of work.
#
# Usage:
#   review-board-signoff.sh --pass <reviewer> [--pass <reviewer> ...] [--note "text"]
#   review-board-signoff.sh --initialize
#
# Every board member must be passed explicitly. There is deliberately no
# "--all" flag: signing off is four separate assertions, each claiming a
# specific reviewer examined this exact work.
#
# --initialize establishes the baseline at HEAD without claiming any review. It
# exists so installing the gate does not retroactively demand review of existing
# history, and it is deliberately a separate, explicit act — the gate no longer
# adopts HEAD on its own, because doing so made deleting one file a bypass.
set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || { echo "not in a project" >&2; exit 1; }

# shellcheck source=./work-hash.sh
. "$(dirname "${BASH_SOURCE[0]}")/work-hash.sh"

passed=()
note=""
initialize=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pass) passed+=("${2:-}"); shift 2 ;;
    --note) note="${2:-}"; shift 2 ;;
    --initialize) initialize=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$initialize" ]; then
  if [ ${#passed[@]} -gt 0 ]; then
    echo "--initialize records no verdicts; do not combine it with --pass." >&2
    exit 1
  fi
  mark_cleared || { echo "could not write ${LAST_CLEARED_FILE}" >&2; exit 1; }
  echo "Baseline established at $(git rev-parse --short HEAD)."
  echo "Work from here forward requires a full board sign-off."
  exit 0
fi

compute_work_hash
work_hash="$WORK_HASH"
if [ -n "$WORK_ERROR" ]; then
  echo "Cannot sign off: ${WORK_ERROR}" >&2
  exit 1
fi
if [ -z "$work_hash" ]; then
  echo "No substantive work in flight. Nothing to sign off." >&2
  exit 1
fi

# Reject anything that is not a board member, so a typo cannot look like a PASS
# the gate will never find.
for p in "${passed[@]+"${passed[@]}"}"; do
  known=""
  for r in "${REVIEW_BOARD[@]}"; do [ "$p" = "$r" ] && known=1; done
  [ -n "$known" ] || { echo "not a board member: $p" >&2; echo "expected one of: ${REVIEW_BOARD[*]}" >&2; exit 1; }
done

missing=()
for r in "${REVIEW_BOARD[@]}"; do
  found=""
  for p in "${passed[@]+"${passed[@]}"}"; do [ "$p" = "$r" ] && found=1; done
  [ -n "$found" ] || missing+=("$r")
done

mkdir -p "$SIGNOFF_DIR" || { echo "could not create ${SIGNOFF_DIR}" >&2; exit 1; }
signoff="${SIGNOFF_DIR}/${work_hash}.signoff"

{
  echo "# Adversarial review board sign-off"
  echo "work-hash: ${work_hash}"
  echo "recorded: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo
  for r in "${REVIEW_BOARD[@]}"; do
    found=""
    for p in "${passed[@]+"${passed[@]}"}"; do [ "$p" = "$r" ] && found=1; done
    if [ -n "$found" ]; then echo "${r}: PASS"; else echo "${r}: NOT RECORDED"; fi
  done
  echo
  # Everything below is ignored by the gate, so free text cannot forge a verdict.
  echo "$NOTES_SENTINEL"
  [ -n "$note" ] && printf '%s\n' "$note" | sed 's/^/# /'
} > "$signoff"

echo "Recorded: $signoff"
if [ ${#missing[@]} -eq 0 ]; then
  mark_cleared
  echo "All four members passed. This work is cleared."
  exit 0
fi
echo
echo "Incomplete — still missing a PASS from: ${missing[*]}"
echo "The gate will keep blocking until every member has passed on this exact work."
exit 1
