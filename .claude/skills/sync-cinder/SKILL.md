---
name: sync-cinder
description: "Bump @lostgradient/cinder + @lostgradient/chat to their latest published npm versions and re-verify chatroom. Trigger on 'sync cinder', 'update cinder', or after confirming a filed cinder issue/PR merged and published."
allowed-tools: Read, Bash
---

Run `bun run sync:cinder` (add `--full` — i.e. `bun run sync:cinder -- --full` — to also run the
Playwright e2e suite; the default run only does `lint` + `check` + `check:upstream`). The script
lives at `scripts/sync-cinder.ts`.

What it does, in order:

1. `bun update @lostgradient/cinder @lostgradient/chat --latest` — chatroom consumes the
   published npm packages (not a `bun link` against `../cinder`), so "sync" means "pull the
   newest release from the registry". It prints the before → after version for each package.
2. Runs chatroom's `lint` and `check` (plus `test:e2e` with `--full`).
3. Runs `check:upstream`, which scans tracked files for `upstream: <owner>/<repo>#<issue>`
   workaround markers and fails if any referenced issue has closed.

**No silent deferral.** If `lint`/`check`/`test:e2e` fails after the sync, stop and report
exactly which check failed and why, with its output. Do not weaken the check, skip it, or report
the sync as clean — a red check right after a sync means a new release broke something in
chatroom, which is exactly the failure mode this skill exists to catch.

**A red `check:upstream` is a cleanup work order, not an error to route around.** For each
flagged marker, in the same session:

1. Verify the fix actually shipped in the installed package (inspect `node_modules` — the issue
   thread is a claim, `dist` is ground truth).
2. If it shipped: remove the workaround (the marker comment and whatever it guarded — extra
   import, cast, event-mirroring, DOM reach-in), re-run `lint` + `check`, and commit the
   cleanup.
3. If the problem still reproduces despite the closed issue: reopen it
   (`gh issue reopen <n> --repo <owner/repo> --comment '...'`), verify the state with
   `gh issue view <n> --json state`, and leave the marker in place.

## When this fits in the larger loop

The full arc for an upstream cinder issue is: file it with `gh issue create` against
`stevekinney/cinder` (see CLAUDE.md's "Filing and resolving upstream issues") → drive it to a
merged PR (the `ralph-pipeline` skill, run from inside `../cinder`) → **publish to npm** (a
merged-but-unpublished fix never reaches chatroom) → run this skill from `chatroom` to pull it
in, confirm nothing broke, and clean up any workarounds the release just made obsolete.
