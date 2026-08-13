#!/usr/bin/env bash
# Record an adversarial review board sign-off for the current body of work.
#
# Usage:
#   review-board-signoff.sh --pass <reviewer> [--pass <reviewer> ...] [--note "text"]
#
# Every board member must be passed explicitly. There is deliberately no
# "--all" flag: signing off is four separate assertions, each of which you are
# claiming a reviewer actually made after examining this exact work.
#
# The sign-off is keyed to a hash of the work. Change anything afterwards and it
# stops applying, which is the point.
set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || { echo "not in a project" >&2; exit 1; }

# shellcheck source=./work-hash.sh
. "$(dirname "${BASH_SOURCE[0]}")/work-hash.sh"

passed=()
note=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pass) passed+=("${2:-}"); shift 2 ;;
    --note) note="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

work_hash=$(compute_work_hash)
if [ -z "$work_hash" ]; then
  echo "No substantive work in flight (nothing under: ${WORK_SCOPE[*]})." >&2
  echo "Nothing to sign off, and the gate will not ask for one." >&2
  exit 1
fi

# Reject anything that is not a known board member, so a typo cannot look like
# a PASS the gate will never find.
for p in "${passed[@]}"; do
  known=""
  for r in "${REVIEW_BOARD[@]}"; do [ "$p" = "$r" ] && known=1; done
  [ -n "$known" ] || { echo "not a board member: $p" >&2; echo "expected one of: ${REVIEW_BOARD[*]}" >&2; exit 1; }
done

missing=()
for r in "${REVIEW_BOARD[@]}"; do
  found=""
  for p in "${passed[@]}"; do [ "$p" = "$r" ] && found=1; done
  [ -n "$found" ] || missing+=("$r")
done

mkdir -p "$SIGNOFF_DIR"
signoff="${SIGNOFF_DIR}/${work_hash}.signoff"

{
  echo "# Adversarial review board sign-off"
  echo "work-hash: ${work_hash}"
  echo "recorded: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo
  for r in "${REVIEW_BOARD[@]}"; do
    found=""
    for p in "${passed[@]}"; do [ "$p" = "$r" ] && found=1; done
    if [ -n "$found" ]; then echo "${r}: PASS"; else echo "${r}: NOT RECORDED"; fi
  done
  [ -n "$note" ] && { echo; echo "notes:"; echo "$note"; }
} > "$signoff"

echo "Recorded: $signoff"
if [ ${#missing[@]} -eq 0 ]; then
  # Advance the baseline so future work is measured from here forward.
  mark_cleared
fi
if [ ${#missing[@]} -gt 0 ]; then
  echo
  echo "Incomplete — still missing a PASS from: ${missing[*]}"
  echo "The gate will keep blocking until every member has passed on this exact work."
  exit 1
fi
echo "All four members passed. This work is cleared."
