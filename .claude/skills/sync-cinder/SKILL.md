---
name: sync-cinder
description: "Pull ../cinder's main after an upstream PR merges, re-link @lostgradient/cinder, and re-verify chatroom. Trigger on 'sync cinder', 'update cinder', 'pull cinder main', or after confirming a filed cinder issue/PR merged."
allowed-tools: Read, Bash
---

Run `bun run sync:cinder` (add `--full` — i.e. `bun run sync:cinder -- --full` — to also run the
Playwright e2e suite; the default run only does `lint` + `check`). The script lives at
`scripts/sync-cinder.ts`.

What it does, in order:

1. Refuses to run if `../cinder` has uncommitted changes or isn't on `main`. Surface that to the
   user rather than stashing, committing, or switching branches on their behalf.
2. `git pull --ff-only origin main` in `../cinder`. If that fails, history has diverged — stop
   and tell the user; do not force-merge, rebase, or reset for them.
3. Re-runs `bun link` in `cinder/packages/components` and `bun link @lostgradient/cinder` here,
   so the link survives even if something upstream touched Cinder's own link state.
4. Runs chatroom's `lint` and `check` (plus `test:e2e` with `--full`).

**No silent deferral.** If any check fails after the sync, stop and report exactly which check
failed and why, with its output. Do not weaken the check, skip it, or report the sync as clean —
a red check right after a sync means a new cinder commit broke something in chatroom, which is
exactly the failure mode this skill exists to catch. That's a stop-and-ask situation, not
something to route around.

## When this fits in the larger loop

The full arc for an upstream cinder issue is: file it with `gh issue create` against
`stevekinney/cinder` (already our convention — see CLAUDE.md's Known Upstream Friction section)
→ drive it to a merged PR (the `ralph-pipeline` skill, run from inside `../cinder` against a task
file derived from the open issues, handles the worktree → PR → CI/review-stabilization → merge
loop) → once merged, run this skill from `chatroom` to pull it in and confirm nothing broke.
