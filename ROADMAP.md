# Coverage roadmap

What this repo still needs to exercise in `@lostgradient/chat` and `@lostgradient/editor`, why each item matters, and what "done" means for it.

This is a testbed, so coverage here is not a quality metric for its own sake. An exercise earns its place by being the kind of thing that finds upstream bugs. The gaps below are ranked by that: the imperative surfaces at the top have already produced shipped defects that cinder's own unit tests caught and this repo did not.

## How to read this

Each item has an ID (`RE-1`, `DV-2`, …), a status, and acceptance criteria. Status values:

- **todo**: not started
- **wip**: in progress
- **done**: merged, with the acceptance criteria met
- **blocked**: waiting on an upstream fix, with the issue linked

An item is only **done** when every one of its acceptance criteria holds, `bun run lint && bun run check && bun run test:e2e` is clean, any upstream defect it surfaced has been driven through the loop in `CLAUDE.md`, and the adversarial review board has returned PASS from all four members on the work as it finally stands. The board is convened with the `review-board` skill and enforced by a Stop hook, so "done" is not self-declared.

Two rules carry over from how this repo already works, and they apply to every item here. Assertions must be checked against real behavior rather than assumed: if an exercise's expectation would pass with the feature removed, it is not pinning anything. And no wait-threshold padding — poll for a condition, never sleep past a guess. Cinder's `AGENTS.md` treats a bumped timeout as a blocking review comment with no exception, and the same standard applies here.

## Where coverage stands today

| Surface                         | Covered      | Notes                                                                                                                                                                                  |
| ------------------------------- | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Chat props and callbacks        | yes          | 14 exercises, ~87 tests                                                                                                                                                                |
| Chat imperative API             | yes, 12/12   | `announce`, `beginStreaming`, `pushToken`, `endStreaming`, `retryMessage`, `scrollToBottom`/`Top`, `clearInput`, `focusInput`, `getComposerValue`, `getEditorElement`, `insertAtRange` |
| ReviewEditor props              | yes, 9/9     | all of `value`, `original`, `mode`, `snapshotMode`, `currentUserId`, `name`, `id`, `class`, `placeholder`                                                                              |
| ReviewEditor callbacks          | yes, 6/6     | `onchange`, `onthreadcreate`, `onthreaddelete`, `oncommentcreate`, `oncommentupdate`, `oncommentdelete`                                                                                |
| **ReviewEditor imperative API** | **no, 8/22** | the largest gap; see `RE-1` through `RE-4`                                                                                                                                             |
| **DiffViewer standalone**       | **no**       | exported at `@lostgradient/editor/diff-viewer`, only reached through ReviewEditor's diff view                                                                                          |
| **MarkdownEditor standalone**   | **no**       | exported at `@lostgradient/editor/markdown-editor`, 7 imperative methods, none driven                                                                                                  |

## ReviewEditor imperative API

`CLAUDE.md` tells consumers to `bind:this` and use this surface for anything past the props: mutation with `createThread`/`createComment`, output with `exportUnifiedDiff`/`exportMarkdownSummary`, persistence with the `getState`/`setState` round trip. We exercise the persistence half and almost none of the rest.

That this is where defects live is not a guess. `generateUnifiedDiff` corrupting YAML front matter, orphaned threads exporting stale positions, and `deleteComment` silently no-opping on the event the component itself emits were all shipped bugs found by cinder's unit tests rather than here.

Currently driven: `focus`, `getFormData`, `getSelection`, `getState`, `getView`, `setState`, plus `getEditor` and `getMarkdown` indirectly. Not driven at all: the 14 below.

### RE-1: thread and comment mutation — todo

Covers `createThread`, `createDocumentThread`, `createBlockThread`, `createComment`, `updateComment`, `deleteComment`, `deleteThread`, `clearAllThreads`.

New exercise at `/exercises/review-imperative`, registered in `src/routes/exercises/+page.svelte`.

Acceptance criteria:

- Every one of the eight methods is called from the page against a bound component, with the result asserted in the DOM and in the bindable `threads` array, not just in a return value.
- `createThread` is asserted against **both** coordinate spaces: the rendered `.comment-anchor` span covers exactly the quoted text, and the resulting `anchor.lastKnownOffset` matches the `doc.textBetween()` offset. These are different numbers for the same selection and getting them confused is the trap `CLAUDE.md` documents.
- `createDocumentThread` produces `type: 'document'` with an empty quote, sorts ahead of anchored threads in the sidebar, and is never marked orphaned by a later re-anchoring pass.
- `createBlockThread` anchors to a block with no text selection, and survives an edit elsewhere in the document.
- `updateComment` and `deleteComment` are driven with **and** without an explicit `deletedAt`, pinning that the omitted case stamps a timestamp rather than no-opping.
- `deleteThread` and `clearAllThreads` fire `onthreaddelete` for consumer-initiated removal, distinguishing it from the orphaning path, which fires nothing.
- Each method is exercised in `readonly` mode too, asserting the guard holds where one exists and documenting where it does not.

### RE-2: export surface — todo

Covers `exportUnifiedDiff` and `exportMarkdownSummary`.

Acceptance criteria:

- `exportUnifiedDiff` output is verified to be **git-appliable**, not merely diff-shaped: pipe it through `git apply --check` against the original document in a temp repo, cleaned up in a `finally`. Hunk headers whose counts disagree with the lines they introduce still look like a diff, which is exactly how the front matter corruption survived review.
- The same check runs for a document **with** YAML front matter and one without.
- `exportMarkdownSummary` includes orphaned threads, labelled as no longer in the document, and never prints a coordinate it does not have.
- An anchored thread's export output is asserted byte-for-byte stable, so a future orphan-related change cannot silently alter it.
- Both are exercised through the UI path as well as the imperative one (Copy Diff menu item, `<name>-diff` hidden input) and asserted to agree.

### RE-3: content replacement and reset — todo

Covers `setMarkdown`, `reset`, `getMarkdown`, `getAst`.

Acceptance criteria:

- `setMarkdown` with existing threads asserts what happens to their anchors: re-anchored where the quote survives, orphaned where it does not, never silently dropped.
- `reset` returns the component to its initial `value` and states what it does to threads, dirty state, and the undo stack.
- Both are driven in `readonly` mode, pinning the answer to whether a readonly editor is programmatically mutable. This is currently undecided: the comment methods guard on `mode === 'readonly'` and these do not. Whichever way it resolves, the exercise should encode the decision rather than leave it ambiguous.
- `getAst` returns a structure matching the rendered document after each mutation above.

### RE-4: scroll and focus affordances — todo

Covers `scrollToThread` and `getEditor`.

Acceptance criteria:

- `scrollToThread` brings an off-screen thread into view and moves focus somewhere sensible and assertable.
- Called with an **orphaned** thread it does not throw and does not scroll to a stale position. `0/0` is a valid ProseMirror position, so a missing guard here fails silently by scrolling to the top of the document rather than erroring.
- Called with an unknown thread id it fails visibly rather than silently.

## DiffViewer

Exported at `@lostgradient/editor/diff-viewer` and usable standalone, but only ever reached here through ReviewEditor's diff view. Its one imperative method, `getHunks`, is never called.

### DV-1: standalone exercise — todo

New exercise at `/exercises/diff-viewer`, registered in the index.

Acceptance criteria:

- Mounted directly, not through ReviewEditor, with its own `original`/`current` props.
- `getHunks` is asserted against a document with a known hunk structure, including a no-change case and an all-changed case.
- Both view modes are exercised, with the `viewMode` binding asserted in each direction.
- Front matter is covered, since that is where the diff pipeline has already shipped one corruption bug.
- Renders and hydrates without a mismatch, added to `HYDRATING_ROUTES` in `src/routes/hydration.e2e.ts`.

### DV-2: slot semantics divergence — todo

Deferred from cinder#1285 and still unresolved. Chat passes `renderDefault` to its snippet props, so a consumer can wrap the default. DiffViewer's `toolbar` is total replacement, which is why passing an empty snippet deletes the Compute Diff button.

Acceptance criteria:

- The current behavior of each is pinned by a test, so the divergence is visible rather than folklore.
- A judgement is recorded: either the two are reconciled upstream, or the difference is documented as intentional in both components' READMEs.
- If reconciled, an issue is filed against `stevekinney/cinder` first per `CLAUDE.md`, rather than worked around here.

### DV-3: window-level key bindings — todo

Deferred from cinder#1285. DiffViewer binds keys at the window level.

Acceptance criteria:

- Assert whether its shortcuts fire when focus is outside the component entirely. Two DiffViewers on one page, or a DiffViewer alongside a focused composer, is the case that matters.
- If they do fire globally, that is an upstream issue: file it rather than working around it.

## MarkdownEditor

Exported at `@lostgradient/editor/markdown-editor` with seven imperative methods (`focus`, `getAst`, `getEditor`, `getMarkdown`, `getSelection`, `getView`, `setMarkdown`), none driven directly.

### ME-1: standalone exercise — todo

New exercise at `/exercises/markdown-editor`, registered in the index.

Acceptance criteria:

- All seven methods driven against a bound component.
- `getSelection` asserted in ProseMirror position space, with the `doc.textBetween()` offset asserted alongside it so the two coordinate spaces stay distinguishable.
- Covers the plugin seam, since this is the component ReviewEditor builds on.
- Renders and hydrates without a mismatch, added to `HYDRATING_ROUTES`.

## Carried over from cinder#1285

Listed on that PR as "not included" and never returned to. Each needs a decision, not necessarily an exercise.

### X-1: per-keystroke diff cost — todo

Acceptance criteria: measure the cost of the diff recompute on each keystroke in a document large enough to matter, following the frame-by-frame methodology rather than wall-clock guesses. Either show it is acceptable and record the number, or file an upstream issue with the measurement attached.

### X-2: dual normalizer — todo

Acceptance criteria: document why two normalization paths exist and whether they can diverge. If they can, construct the input that makes them disagree and file it.

### X-3: sidebar quiet-failure paths — todo

Acceptance criteria: enumerate the sidebar paths that fail without surfacing anything, and for each, assert either that it now reports or that silence is correct. The orphaned-thread popover fallback found this session is one instance; the exercise is finding the rest.

## Infrastructure

### I-1: real-browser coverage for row insertion and removal — todo

Under happy-dom a keyed `{#each}` whose body starts with a conditional does not reconcile, so Chat's static row list looks frozen there. This is documented in `packages/chat/src/lib/test/happy-dom.ts` upstream. It cost a filed issue, a shipped workaround, and a revert before being pinned down, and the reason it got that far is that no real-browser test covered row insertion and removal.

Acceptance criteria:

- A Playwright exercise asserts that messages added to `conversation` appear, messages removed leave, and `hidden: true` hides — in a real browser.
- The focus backstop's rendered-set path is asserted here, since it cannot be tested under happy-dom.
- The test is verified load-bearing by confirming it fails when the behavior is broken.

### I-2: keep `sync:cinder` honest — done

`scripts/sync-cinder.ts` was bumping `@lostgradient/cinder` and `@lostgradient/chat` but not `@lostgradient/editor`, so it reported success while leaving editor a release behind. Fixed this session and verified against the 0.9.0 release.

Acceptance criteria, all met: the script bumps all three packages; a sync that leaves any of them stale fails rather than reporting success; `check:peers` still enforces range alignment.

## Review board audit — 2026-08-12

The adversarial review board (`test-integrity-auditor`, `harness-skeptic`, `contract-auditor`, `a11y-ssr-auditor`) was convened outside its usual per-change role to sweep the whole repo for gaps, rather than review one diff. Findings below, one section per reviewer. None of these have gone through the upstream loop or a normal review-board sign-off yet — they're newly catalogued `todo` items, not completed work.

### Contract drift

`contract-auditor` cross-checked `CLAUDE.md`, `README.md`, `.claude/skills/sync-cinder/SKILL.md`, and this file against the code, installed packages, and upstream issue state.

#### CA-1: `CLAUDE.md`'s peer-dependency claim for `@lostgradient/chat` is stale — todo

`CLAUDE.md` (the "As of Cinder 0.16" paragraph) says Chat peer-depends on `@lostgradient/cinder`, `conversationalist`, `zod`, and `svelte`. The installed `@lostgradient/chat@0.9.2` `package.json` lists `peerDependencies` of only `@lostgradient/cinder`, `@lostgradient/markdown`, and `svelte` — `conversationalist` and `zod` are chat's own regular dependencies, exactly as the cinder#753 fix (documented lower in the same file) says they should be. The paragraph also never mentions `@lostgradient/markdown` as a peer at all.

Acceptance criteria:

- The peer-dependency description is corrected to match `@lostgradient/chat@0.9.2`'s actual `peerDependencies`.
- `@lostgradient/markdown` is named as a peer.

#### CA-2: `README.md` documents a `bun link` workflow the project deliberately removed — todo

`README.md` still describes `@lostgradient/cinder`/`conversationalist`/`armorer` as linked from local `../cinder` and `../agent-bureau` checkouts, `bun run dev` picking up live edits with no build step, and `bun run sync:cinder` "re-linking" — all contradicting `CLAUDE.md`'s explicit, deliberate rule that chatroom consumes published npm packages, not a `bun link` (a rule that exists specifically because linking hid the cinder#756 hydration mismatch). The README also never mentions `@lostgradient/chat` or `@lostgradient/editor`/ReviewEditor by name, and its scripts table omits `check:peers`.

Acceptance criteria:

- `README.md` describes the actual published-package consumption model, matching `CLAUDE.md`.
- Chat and ReviewEditor are both named as things this repo exercises.
- The scripts table includes `check:peers`.

#### CA-3: `sync-cinder` skill undersells what the sync script actually does — todo

`.claude/skills/sync-cinder/SKILL.md` describes bumping only `@lostgradient/cinder` and `@lostgradient/chat`. `scripts/sync-cinder.ts`'s `packages` array actually bumps five: `@lostgradient/cinder`, `@lostgradient/chat`, `@lostgradient/editor`, `@lostgradient/markdown`, and `armorer` — this is the same gap `I-2` above fixed in the script itself, but the skill doc describing that script was never updated to match.

Acceptance criteria:

- `SKILL.md`'s description and steps name all five packages the script bumps.

#### CA-4: `CLAUDE.md` cites a closed, shipped-fixed issue as a live trap — done

`CLAUDE.md`'s ReviewEditor section says the shipped `with-comments` example seeds raw-Markdown indices and is wrong, citing `stevekinney/cinder#1267`. That issue is closed (`stateReason: COMPLETED`), and the installed `@lostgradient/editor@0.9.0`'s `with-comments` example now seeds correct ProseMirror positions with an inline comment explaining the two coordinate spaces — exactly the requested fix, already in the version this repo depends on. `CLAUDE.md` itself says elsewhere that a closed issue citing unresolved behavior should be verified, not left standing; this is the same failure in reverse, an already-fixed bug still cited as current.

Acceptance criteria:

- Confirm against the installed `@lostgradient/editor` version whether the `with-comments` example is actually fixed.
- If fixed, remove the warning (or convert it to a changelog note) rather than leaving it as live guidance to route around a bug that no longer exists.

#### CA-5: two pointers in this file may reference documentation that doesn't exist where claimed — todo, needs verification

Two claims elsewhere in this roadmap couldn't be fully confirmed and are worth checking before relying on them:

- `I-1` says the happy-dom keyed-`{#each}` reconciliation trap "is documented in `packages/chat/src/lib/test/happy-dom.ts` upstream." Reading that file on `../cinder`'s `main` (matching the published `@lostgradient/chat@0.9.2`) shows it documents an `Element.prototype.remove()` patch and a Web Animations API stub — nothing about keyed-`{#each}` reconciliation. That documentation exists only in an unmerged commit on a feature branch, not on `main` and not in what's published.
- `I-1` also says "the focus backstop's rendered-set path is asserted here" — no code under the terms "focus backstop" or "rendered-set" could be found anywhere in `../cinder`'s current `packages/chat/src`, including the components and hooks most likely to hold it. This is a grep-based negative result across a large component, so it isn't conclusive, but it's worth confirming the acceptance criterion is coherent before `I-1` work starts.

Acceptance criteria:

- Confirm or correct the `happy-dom.ts` documentation pointer, updating it to point at wherever (if anywhere) the trap is actually documented upstream.
- Locate the "focus backstop" mechanism by name in cinder's source, or correct/remove the acceptance criterion if it doesn't exist under that name.

### Harness risk

`harness-skeptic` swept the whole test setup rather than one finding. Headline context: this repo runs zero happy-dom/jsdom tests — everything is Playwright against a real server — so `I-1`'s specific failure mode doesn't recur here. The risk in this repo is a level up: what the _mocks_ fail to reproduce about the real network/streaming/approval path, and what the _browser matrix_ fails to cover.

#### HS-1: the one test path that mirrors production streaming never delivers an actually-incremental stream — todo

`src/routes/page.svelte.e2e.ts` is the only suite exercising `+page.svelte`'s real `fetch('/api/chat')` → `response.body.getReader()` → per-line `pushToken` path (as opposed to the `/exercises/*` pages, which drive `pushToken` with real `setTimeout` delays and are fine). Every one of these tests mocks the network with a single static `page.route(...).fulfill({ body })`, which arrives as one chunk, never a real multi-chunk stream over time. As a result: progressive rendering as tokens genuinely trickle in is unverified for the one route that matches production, and "stop generating" is only tested against a request that never resolves at all — never against a request with partial content already in `buffer` when the abort lands, which is the `+page.svelte` branch that retains partial content on user-initiated stop.

Acceptance criteria:

- A fixture (e.g. a small local HTTP server that writes the ndjson body across multiple real `write()` calls, since Playwright route interception can't trickle a body on its own) stands in for the Anthropic response with genuine multi-chunk timing.
- A test exercises stop-generation with real partial content already buffered, asserting the retain-partial-content branch specifically.

#### HS-2: the real tool-approval server round trip is completely untested — todo

`src/routes/api/chat/resume/+server.ts` — the route verifying armorer's signed `approvalToken` via `toolbox.resumeApproval` — is referenced from exactly one place in the repo (`+page.svelte`) and from zero e2e tests. `/exercises/tool-approval` fakes the entire approve/deny flow with an in-page adapter that never calls the real server route and never round-trips a real `SignedPendingToolApproval`. Anyone citing that exercise as evidence "tool approval works" would be citing a harness artifact — it validates Chat's UI affordances, not the signature-verification path.

Acceptance criteria:

- A Playwright test drives the real `/` page (or a new exercise) through `/api/chat/resume`, asserting the client sends the real `approvalToken` shape and handles the real response shape — either against the real route with a stubbed `toolbox`, or a route mock narrow enough to prove the shape rather than fake the whole flow.

#### HS-3: Playwright runs Chromium only, despite "confirmed in a real browser" being this project's standard of proof — todo

`playwright.config.ts` has no `projects` array, so every "real browser" finding this repo produces is only confirmed in one engine. That specifically matters for the two categories this project already knows diverge across engines: focus behavior (WebKit's focus-on-click/blur-on-removal semantics differ from Chromium's — squarely `a11y-ssr-auditor`'s domain) and streaming/fetch (`ReadableStream` backpressure and chunk-delivery timing have known WebKit quirks, directly relevant to `HS-1`).

Acceptance criteria:

- Add `webkit` (and ideally `firefox`) to a `projects` array in `playwright.config.ts`, at minimum gated to the focus/a11y and streaming specs.
- Update any doc language that says a finding was "confirmed in a real browser" to name which engine(s), going forward.

#### HS-4: no CI trace/screenshot/video capture is configured — todo

`playwright.config.ts` sets no `use.trace`, `use.screenshot`, `use.video`, or `retries`. A flaky-looking failure has no artifact trail to diagnose from, which is exactly the pressure that produces "just bump the timeout" — the move `CLAUDE.md` and this project's own history (see the `no-timeout-bumps-for-ci-failures` lesson) already rule out.

Acceptance criteria:

- `use.trace: 'retain-on-failure'` (or equivalent) is configured so a failing run leaves a trace to inspect, without resorting to a timeout bump to make flakiness go away.

### Test integrity

`test-integrity-auditor` verified three existing "pinned bug" tests are genuinely load-bearing by reverting their upstream fix in `node_modules` and watching them fail (in `review-anchoring.e2e.ts`, `review-state-and-session.e2e.ts`, and `review-comment-lifecycle.e2e.ts` — all confirmed solid, restored after). The findings below are from the rest of the sweep.

#### TI-1: fixed `waitForTimeout` padding across four e2e files — todo

Genuine fixed sleeps (not polls) are used to outlast a debounce before asserting an absence, in `review-modes.e2e.ts` (`SELECTION_SETTLE_MS = 400`), `review-comment-creation.e2e.ts` (`KEY_SETTLE_MS = 60`, `SELECTION_SETTLE_MS = 300`), `review-anchoring.e2e.ts` (`SETTLE_MS = 900`, `LATE_PASTE_SETTLE_MS = 1400`), and `hydration.e2e.ts` (a bare `waitForTimeout(1000)` after the hydration beacon, to catch a trailing console warning — this one has no cited mechanism for why 1000ms is enough, unlike the others, which at least cite a documented plugin debounce). `CLAUDE.md`'s own rule treats any `waitForTimeout` as a blocking finding with no exception. Concrete failure scenario: if a debounce interval regresses upward, these waits "pass" by luck up to some threshold rather than proving the contract in general.

Acceptance criteria:

- Each of these sleeps is converted to a poll against an observable condition (e.g. `expect.poll` against `anchorJson()`, or a readiness data attribute) rather than a fixed guessed duration.
- For `hydration.e2e.ts` specifically: either find the actual mechanism that schedules a trailing hydration-mismatch warning relative to the beacon and poll for it, or document why a fixed wait is the only option here.

#### TI-2: no UI-driven coverage for a stale thread/comment id reaching the reducer — todo

`review-comment-lifecycle.e2e.ts`'s reducer-direct block covers unknown ids for `deleteComment` by calling the pure function directly, but no test drives this through the actual UI/component event — the case where a stale `threadId`/`commentId` (already removed by another tab, or a delayed callback) reaches `deleteComment`/`updateComment` through a real user action rather than a bare function call.

Acceptance criteria:

- A UI-path test triggers a delete/update on a thread or comment that has already been removed via another path, asserting the same well-defined behavior the reducer-direct test pins, reached the way a real user would trigger it.

### Accessibility and SSR

`a11y-ssr-auditor` swept the whole `/exercises` surface rather than one change, and reproduced one finding live in Chromium rather than reasoning about it statically.

#### A11Y-1: 20 of 24 SSR'd exercise routes are missing from `HYDRATING_ROUTES` — todo

`src/routes/hydration.e2e.ts`'s `HYDRATING_ROUTES` lists six routes. Every other route under `src/routes/exercises/**` also renders `<Chat>` or `<ReviewEditor>` unconditionally in markup (no `{#if browser}` guard anywhere), so it is SSR'd and hydrated exactly like the six that are checked, but nothing catches a mismatch there. `review-front-matter` alone seeds nine ReviewEditor instances with edge-case YAML front matter — exactly the kind of varied markup that produced past mismatches (cinder#756, cinder#1277). Most notably, `review-ssr-and-a11y` — the route built specifically to audit SSR/hydration/live-region/keyboard behavior — is itself absent from the one automated check that catches SSR/hydration disagreement.

Acceptance criteria:

- Every exercise route that unconditionally renders Chat or ReviewEditor server-side is added to `HYDRATING_ROUTES`, `review-ssr-and-a11y` included.
- New exercises get added to this list as a matter of course going forward (already the stated intent for `DV-1`/`ME-1`; this closes the gap for what already exists).

#### A11Y-2: closing the artifact panel drops focus to `<body>` — todo

`/exercises/artifacts`' `closePanel` unmounts `ArtifactPanel` entirely (`{#if open && panel}`), and nothing — neither the component nor the exercise page — restores focus to the button that opened the panel. Reproduced live in Chromium: open the panel, close it, `document.activeElement` is `<body>`. For a keyboard-only user the next Tab starts from the top of the document instead of resuming near the message row; a screen reader is silent when focus lands on `<body>`. `artifacts.e2e.ts` clicks the close button but never asserts where focus lands afterward, so this shipped uncaught.

Acceptance criteria:

- Closing the artifact panel returns focus to the control that opened it (or another assertable, sensible target).
- `artifacts.e2e.ts` asserts the post-close focus target.
- If the fix belongs in `@lostgradient/chat`'s `ArtifactPanel` rather than the exercise page, this is filed and driven through the upstream loop rather than patched locally.

#### A11Y-3: error live regions are mounted only after the error occurs, in six files — todo

`message-lifecycle/adapter-panel.svelte`, `message-lifecycle/plain-panel.svelte`, `adapter-push/subscribe-in-effect-hazard-fixture.svelte`, `adapter-push/+page.svelte`, `tool-approval/+page.svelte`, and `interleaving/+page.svelte` all gate their `role="alert"` banner behind `{#if error}`, so the live-region node doesn't exist in the DOM until the error has already happened. Chat's own `chat-status-announcer.svelte` explicitly documents the opposite pattern — keep the live region permanently mounted, since "mounting with pre-existing text is not reliably announced" — and these six exercises do the thing that comment warns against.

Acceptance criteria:

- Each of the six banners is permanently mounted with empty content, toggling only the text, matching Chat's own documented pattern.
- A test asserts the live-region element exists in the DOM before the error-triggering action, not just after.

#### A11Y-4: four pinned "known bug" tests in `review-ssr-and-a11y.e2e.ts` were never routed through the upstream loop — todo

Four tests are explicitly labelled "(pinned known bug)" and pin defects in `@lostgradient/editor` without a corresponding filed issue: Tab is swallowed inside a list and silently indents it with no escape (a WCAG 2.1.2 keyboard trap); unselected view tabs point `aria-controls` at panels that don't exist, since inactive views are removed via `{#if}` rather than hidden; anchored-comment decorations (`.comment-anchor`) carry no role/tabindex/aria-* and are mouse-only, invisible to keyboard and assistive tech; the thread popover declares `aria-modal` without matching focus-trap semantics (though its actual Tab-cycling behavior is fine — the mismatch is specifically the unbacked attribute). No matching issue exists in `stevekinney/cinder`, open or closed. Per `CLAUDE.md`, an upstream bug found by this repo's own tests is the next task, not a permanent regression test to route around.

Acceptance criteria:

- Each of the four is filed against `stevekinney/cinder` and driven through the upstream loop in `CLAUDE.md` (file, fix in a worktree, PR to green, merge, release, sync back) — not left as a permanently-pinned local workaround.
- The "(pinned known bug)" test labels are updated to reference the filed issue, and removed once each fix ships and is synced.
