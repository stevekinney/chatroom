---
name: sync-cinder
description: "Bump the five upstream packages chatroom consumes — @lostgradient/cinder, @lostgradient/chat, @lostgradient/editor, @lostgradient/markdown, and armorer — to their latest published npm versions and re-verify chatroom. Trigger on 'sync cinder', 'update cinder', or after confirming a filed cinder issue/PR merged and published."
allowed-tools: Read, Bash
---

Run `bun run sync:cinder` (add `--full` — i.e. `bun run sync:cinder -- --full` — to also run the
Playwright e2e suite; the default run does `lint` + `check` + `check:upstream` + `check:peers`).
The script lives at `scripts/sync-cinder.ts`.

What it does, in order:

1. Bumps **five** packages to `--latest`: `@lostgradient/cinder`, `@lostgradient/chat`,
   `@lostgradient/editor`, `@lostgradient/markdown`, and `armorer`. chatroom consumes the
   published npm packages (not a `bun link` against `../cinder`), so "sync" means "pull the
   newest release from the registry". It prints the before → after version for each package.

   The list in the script's `packages` array is the authority, and it must stay in step with the
   **runtime** upstream packages chatroom consumes — the `@lostgradient/*` entries under
   `dependencies`, plus `armorer`. It deliberately does not cover `@lostgradient/cinder-mcp`,
   which is a devDependency and not a component this repo exercises. `@lostgradient/editor` was
   absent from the array for the whole of its first release cycle, and the failure mode is worse
   than "not synced": the sync still printed a clean bill of health while leaving editor a release
   behind. If you add a runtime upstream package to `package.json`, add it here.

2. Runs chatroom's `lint`.
3. Runs `check`.
4. Runs `check:upstream`, which scans tracked AND untracked-but-not-ignored files for
   `upstream: <owner>/<repo>#<issue>` workaround markers and fails if any referenced issue has
   closed.
5. Runs `check:peers`. Its `CHECKS` array currently holds a single entry — `conversationalist`
   against `@lostgradient/chat` — verifying chatroom's re-declared range still matches the range
   its owning package declares, so both resolve one instance. A release that moves chat's floor
   fails here until chatroom's range follows. It does **not** check peer-range satisfaction
   generally, so an unsatisfied peer elsewhere passes this silently.
6. Runs `test:e2e`, **only** with `--full`. It is appended last, after `check:peers` — not second.
   Note the loop at `scripts/sync-cinder.ts:87-96` has no `break`: every check runs even after an
   earlier one fails, so `test:e2e` executes regardless. Being last controls reporting order, not
   whether it runs.

**No silent deferral.** If any of `lint`, `check`, `check:upstream`, `check:peers`, or `test:e2e` fails after the sync, stop and report
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
