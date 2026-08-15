# Coverage roadmap

What this repo still needs to exercise in `@lostgradient/chat` and `@lostgradient/editor`, why each item matters, and what "done" means for it.

This is a testbed, so coverage here is not a quality metric for its own sake. An exercise earns its place by being the kind of thing that finds upstream bugs. The gaps below are ranked by that: the imperative surfaces at the top have already produced shipped defects that cinder's own unit tests caught and this repo did not.

## How to read this

Each item has an ID (`RE-1`, `DV-2`, …), a status, and acceptance criteria. Status values:

- **todo**: not started
- **wip**: in progress
- **done**: merged, with the acceptance criteria met
- **blocked**: waiting on an upstream fix, with the issue linked

An item is only **done** when every one of its acceptance criteria holds, `bun run lint && bun run check && bun run test:e2e` is clean, any upstream defect it surfaced has been driven through the loop in `CLAUDE.md`, and the adversarial review board has returned PASS from all four members on the work as it finally stands. The board is convened with the `review-board` skill. It used to be backed by a Stop hook that blocked completion until a sign-off existed. On 2026-08-14 that hook was unwired, briefly replaced by a narrower `PreToolUse` hook gating only `ROADMAP.md` edits, and then unwired again — so the requirement now rests on discipline rather than on enforcement. `CLAUDE.md` carries the full sequence. "Done" is still not self-declared — it is just no longer machine-checked.

Two rules carry over from how this repo already works, and they apply to every item here. Assertions must be checked against real behavior rather than assumed: if an exercise's expectation would pass with the feature removed, it is not pinning anything. And no wait-threshold padding — poll for a condition, never sleep past a guess. Cinder's `AGENTS.md` treats a bumped timeout as a blocking review comment with no exception, and the same standard applies here.

## Where coverage stands today

| Surface                         | Covered        | Notes                                                                                                                                                                                                                            |
| ------------------------------- | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Chat props and callbacks        | yes            | 14 exercises, ~87 tests                                                                                                                                                                                                          |
| Chat imperative API             | yes, 12/12     | `announce`, `beginStreaming`, `pushToken`, `endStreaming`, `retryMessage`, `scrollToBottom`/`Top`, `clearInput`, `focusInput`, `getComposerValue`, `getEditorElement`, `insertAtRange`                                           |
| ReviewEditor props              | yes, 9/9       | all of `value`, `original`, `mode`, `snapshotMode`, `currentUserId`, `name`, `id`, `class`, `placeholder`                                                                                                                        |
| ReviewEditor callbacks          | yes, 6/6       | `onchange`, `onthreadcreate`, `onthreaddelete`, `oncommentcreate`, `oncommentupdate`, `oncommentdelete`                                                                                                                          |
| **ReviewEditor imperative API** | **yes, 22/22** | `RE-1` landed the eight mutation methods; `RE-2`–`RE-4` landed the remaining six (export, content replacement, scroll/focus) — two `scrollToThread` drives reveal pinned upstream bugs rather than working correctly, see `RE-4` |
| **DiffViewer standalone**       | **yes**        | new `/exercises/diff-viewer`; see `DV-1`                                                                                                                                                                                         |
| **MarkdownEditor standalone**   | **yes**        | new `/exercises/markdown-editor`, all 7 imperative methods driven; see `ME-1`                                                                                                                                                    |

## ReviewEditor imperative API

`CLAUDE.md` tells consumers to `bind:this` and use this surface for anything past the props: mutation with `createThread`/`createComment`, output with `exportUnifiedDiff`/`exportMarkdownSummary`, persistence with the `getState`/`setState` round trip. We exercise the persistence half and almost none of the rest.

That this is where defects live is not a guess. `generateUnifiedDiff` corrupting YAML front matter, orphaned threads exporting stale positions, and `deleteComment` silently no-opping on the event the component itself emits were all shipped bugs found by cinder's unit tests rather than here.

Currently driven: `focus`, `getFormData`, `getSelection`, `getState`, `getView`, `setState`, plus `getEditor` and `getMarkdown` indirectly; since `RE-1`, all eight of `createThread`, `createDocumentThread`, `createBlockThread`, `createComment`, `updateComment`, `deleteComment`, `deleteThread`, and `clearAllThreads`; and, since `RE-2` through `RE-4`, the remaining six — `exportUnifiedDiff`, `exportMarkdownSummary`, `setMarkdown`, `reset`, `getAst`, and `scrollToThread` — are driven too. All 22 methods on the imperative surface now have exercised coverage.

### RE-1: thread and comment mutation — done

Covers `createThread`, `createDocumentThread`, `createBlockThread`, `createComment`, `updateComment`, `deleteComment`, `deleteThread`, `clearAllThreads`.

New exercise at `/exercises/review-imperative`, registered in `src/routes/exercises/+page.svelte`.

Acceptance criteria:

- Every one of the eight methods is called from the page against a bound component, with the result asserted in the DOM and in the bindable `threads` array, not just in a return value.
- `createThread` is asserted against **both** coordinate spaces: the rendered `.comment-anchor` span covers exactly the quoted text, and the resulting `anchor.lastKnownOffset` matches the `doc.textBetween()` offset. These are different numbers for the same selection and getting them confused is the trap `CLAUDE.md` documents.
- `createDocumentThread` produces `type: 'document'` with an empty quote, sorts ahead of anchored threads in the sidebar, and is never marked orphaned by a later re-anchoring pass.
- `createBlockThread` anchors to a block with no text selection, and survives an edit elsewhere in the document.
- `updateComment` and `deleteComment` are driven, and the omitted-`deletedAt` case is pinned to stamp a timestamp rather than no-op. **Amended once built, because the original wording was unsatisfiable.** It asked for both methods to be driven "with and without an explicit `deletedAt`" through the imperative surface — but neither imperative method has that parameter: they are `updateComment(threadId, commentId, body)` and `deleteComment(threadId, commentId, soft = true)`. `deletedAt` belongs to the pure reducer, whose own docblock calls omitting it a deliberate exception. So the `deletedAt` half is driven against the reducer directly, the way `review-comment-lifecycle` already does, and the component methods are driven through the UI.
- `deleteThread` and `clearAllThreads` fire `onthreaddelete` for consumer-initiated removal, distinguishing it from the orphaning path, which fires nothing.
- Each method is exercised in `readonly` mode too, asserting the guard holds where one exists and documenting where it does not.

### RE-2: export surface — done

Covers `exportUnifiedDiff` and `exportMarkdownSummary`.

Acceptance criteria:

- `exportUnifiedDiff` output is verified to be **git-appliable**, not merely diff-shaped: pipe it through `git apply --check` against the original document in a temp repo, cleaned up in a `finally`. Hunk headers whose counts disagree with the lines they introduce still look like a diff, which is exactly how the front matter corruption survived review.
- The same check runs for a document **with** YAML front matter and one without.
- `exportMarkdownSummary` includes orphaned threads, labelled as no longer in the document, and never prints a coordinate it does not have.
- An anchored thread's export output is asserted byte-for-byte stable, so a future orphan-related change cannot silently alter it.
- Both are exercised through the UI path as well as the imperative one (Copy Diff menu item, `<name>-diff` hidden input) and asserted to agree.

### RE-3: content replacement and reset — done

Covers `setMarkdown`, `reset`, `getMarkdown`, `getAst`.

Acceptance criteria:

- `setMarkdown` with existing threads asserts what happens to their anchors: re-anchored where the quote survives, orphaned where it does not, never silently dropped.
- `reset` returns the component to its initial `value` and states what it does to threads, dirty state, and the undo stack.
- Both are driven in `readonly` mode, pinning the answer to whether a readonly editor is programmatically mutable. **No longer undecided:** `RE-1` measured it and `/exercises/review-imperative` pins it — all eight mutation methods guard on `mode === 'readonly'`; `setMarkdown` and `reset` do not, so a readonly editor _is_ programmatically mutable (235 chars to 36). `RE-3` inherits that as established behavior and extends it to `reset`, rather than re-deciding it.
- `getAst` returns a structure matching the rendered document after each mutation above.

### RE-4: scroll and focus affordances — wip

Covers `scrollToThread` and `getEditor`. **Stays `wip`, not `done`, on purpose**: the exercise coverage itself is complete and board-reviewed, but the first acceptance criterion below is genuinely unmet — `scrollToThread` does not actually work, which is a real upstream defect (not yet filed — see `A11Y-4`, which tracks it alongside six other pinned bugs that share this item's "assert, then route the failure upstream" shape). `getEditor` and the other two `scrollToThread` behaviors are fully driven and correct.

Acceptance criteria:

- `scrollToThread` brings an off-screen thread into view and moves focus somewhere sensible and assertable. **Not met** — pinned as `(pinned known bug)` instead: the component computes an offset and calls `scrollTo` on `view.dom`, which carries no `overflow` in any shipped stylesheet, so the call is clamped to 0 and nothing moves, even though the identical anchor is reachable via the component's own `scrollAnchorIntoView` path elsewhere. Unfiled — see `A11Y-4`.
- Called with an **orphaned** thread it does not throw and does not scroll to a stale position. `0/0` is a valid ProseMirror position, so a missing guard here fails silently by scrolling to the top of the document rather than erroring. **Met** — this one actually works; the guard is present.
- Called with an unknown thread id it fails visibly rather than silently. **Not met** — pinned as `(pinned known bug)`: it fails invisibly (no throw, no observable effect) rather than visibly. Unfiled — see `A11Y-4`.

## DiffViewer

Exported at `@lostgradient/editor/diff-viewer` and usable standalone, but only ever reached here through ReviewEditor's diff view. Its one imperative method, `getHunks`, is never called.

### DV-1: standalone exercise — done

New exercise at `/exercises/diff-viewer`, registered in the index.

Acceptance criteria:

- Mounted directly, not through ReviewEditor, with its own `original`/`current` props.
- `getHunks` is asserted against a document with a known hunk structure, including a no-change case and an all-changed case.
- Both view modes are exercised, with the `viewMode` binding asserted in each direction.
- Front matter is covered, since that is where the diff pipeline has already shipped one corruption bug.
- Renders and hydrates without a mismatch, added to `HYDRATING_ROUTES` in `src/routes/hydration.e2e.ts`.

### DV-2: slot semantics divergence — done

Deferred from cinder#1285. **Resolved as intentional, not reconciled.** Chat passes `renderDefault` to its snippet props, so a consumer can wrap the default. DiffViewer's `toolbar` is total replacement, which is why passing an empty snippet deletes the Compute Diff button. The judgement — that this divergence is deliberate rather than a bug — is now recorded in both packages' published READMEs (`@lostgradient/editor@0.10.0`'s "DiffViewer toolbar override" section and `@lostgradient/chat@0.9.4`'s "Overriding built-in rendering" section, the latter requiring its own small changeset/release follow-up after the first landed without one), each cross-linking to the other.

Acceptance criteria:

- The current behavior of each is pinned by a test, so the divergence is visible rather than folklore. **Met** — `diff-viewer.e2e.ts` and the Chat exercises pin both sides.
- A judgement is recorded: either the two are reconciled upstream, or the difference is documented as intentional in both components' READMEs. **Met**, documented-as-intentional.
- If reconciled, an issue is filed against `stevekinney/cinder` first per `CLAUDE.md`, rather than worked around here. **N/A** — not reconciled, so this branch does not apply.

### DV-3: window-level key bindings — done

Deferred from cinder#1285. **They did fire globally, and it was filed and fixed.** [stevekinney/cinder#1310](https://github.com/stevekinney/cinder/issues/1310), closed, released in `@lostgradient/editor@0.10.0`: `DiffViewer` moved its keydown handler from `<svelte:window>` onto its own root element, so shortcuts now only fire when focus is inside that instance's own subtree — deliberately including the single-instance case, where focus on `<body>` alongside one `DiffViewer` on the page now also fires nothing. The same board round also found and fixed a companion defect in the same component area, an `aria-labelledby` id collision across multiple instances ([#1309](https://github.com/stevekinney/cinder/issues/1309)).

Acceptance criteria:

- Assert whether its shortcuts fire when focus is outside the component entirely. Two DiffViewers on one page, or a DiffViewer alongside a focused composer, is the case that matters. **Met** — `diff-viewer.e2e.ts` and `review-views.e2e.ts` (ReviewEditor's embedded `DiffViewer`) both pin the fixed contract.
- If they do fire globally, that is an upstream issue: file it rather than working around it. **Met.**

## MarkdownEditor

Exported at `@lostgradient/editor/markdown-editor` with seven imperative methods (`focus`, `getAst`, `getEditor`, `getMarkdown`, `getSelection`, `getView`, `setMarkdown`), none driven directly.

### ME-1: standalone exercise — done

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

### X-2: dual normalizer — wip

**Half-answered already, from two independent directions.** `RE-2`'s own test suite documents one instance directly: `generateUnifiedDiff` normalizes front matter and the body before diffing, while `generateMarkdownSummary` runs `computeLineDiff` on the raw strings with no normalization step at all — pinned in `review-front-matter.e2e.ts` with a literal that states plainly they happen to agree on that fixture and would stop loudly if that changed. Separately, [stevekinney/cinder#1307](https://github.com/stevekinney/cinder/issues/1307) — filed (found by a `contract-auditor` board-round-5 re-review, not by this item's own investigation; provenance otherwise unattributed) — reports the same normalizer-divergence class from a different angle: ReviewEditor's toolbar `diffStats` normalizes front matter as Markdown and reports a one-line edit as two modified lines, where the body diff panel correctly reports zero, which #1307 identifies as the same defect class `#1285` already fixed in `generateUnifiedDiff` but not extended to the toolbar's own stat computation.

Acceptance criteria: document why two normalization paths exist and whether they can diverge — **done**, above, for both instances found so far. If they can, construct the input that makes them disagree and file it — **done** for the toolbar-`diffStats` instance (#1307, open); the `generateUnifiedDiff`/`generateMarkdownSummary` instance from `RE-2` is pinned as a tripwire rather than filed, since the two functions agree on every fixture tried so far and no disagreeing input has been constructed yet — that construction is the remaining work.

### X-3: sidebar quiet-failure paths — todo

Acceptance criteria: enumerate the sidebar paths that fail without surfacing anything, and for each, assert either that it now reports or that silence is correct. The orphaned-thread popover fallback found this session is one instance; the exercise is finding the rest.

## Infrastructure

### I-1: real-browser coverage for row insertion and removal — done

Under happy-dom a keyed `{#each}` whose body starts with a conditional does not reconcile, so Chat's static row list looks frozen there. This is documented in `packages/chat/src/lib/test/happy-dom.ts` upstream. It cost a filed issue, a shipped workaround, and a revert before being pinned down, and the reason it got that far is that no real-browser test covered row insertion and removal.

New exercise at `/exercises/row-reconciliation` plus `row-reconciliation.e2e.ts`, added to `HYDRATING_ROUTES`. `harness-skeptic`'s board-round-5 review live-confirmed the focus-backstop assertion specifically: focus parked on a row via real `ArrowDown` keystrokes, `Delete` fired outside any form field, the row unmounts, and focus lands back on the timeline rather than `<body>` — with the compiled file that actually ships (`@lostgradient/chat`'s `"."` export resolves to `dist/`, not a dead-source copy) confirmed as the one under test.

Acceptance criteria, all met:

- A Playwright exercise asserts that messages added to `conversation` appear, messages removed leave, and `hidden: true` hides — in a real browser.
- The focus backstop's rendered-set path is asserted here, since it cannot be tested under happy-dom.
- The test is verified load-bearing by confirming it fails when the behavior is broken.

### I-2: keep `sync:cinder` honest — done

`scripts/sync-cinder.ts` was bumping `@lostgradient/cinder` and `@lostgradient/chat` but not `@lostgradient/editor`, so it reported success while leaving editor a release behind. Fixed and verified against the 0.9.0 release, and exercised again since against 0.9.1.

Acceptance criteria, all met: the script bumps every package it claims to; a sync that leaves any of them stale fails rather than reporting success; `check:peers` still enforces range alignment.

The original wording said "all three packages", which was true of the gap this item closed and is no longer true of the script: `scripts/sync-cinder.ts` now bumps **five** — `@lostgradient/cinder`, `@lostgradient/chat`, `@lostgradient/editor`, `@lostgradient/markdown`, and `armorer`. `CA-3` corrected the skill doc that described the same script; this is the same correction on this side.

## Review board audit — 2026-08-12

The adversarial review board (`test-integrity-auditor`, `harness-skeptic`, `contract-auditor`, `a11y-ssr-auditor`) was convened outside its usual per-change role to sweep the whole repo for gaps, rather than review one diff. Findings below, one section per reviewer. None of these have gone through the upstream loop or a normal review-board sign-off yet — they're newly catalogued `todo` items, not completed work.

### Contract drift

`contract-auditor` cross-checked `CLAUDE.md`, `README.md`, `.claude/skills/sync-cinder/SKILL.md`, and this file against the code, installed packages, and upstream issue state.

#### CA-1: `CLAUDE.md`'s peer-dependency claim for `@lostgradient/chat` was stale — done

**Resolved; described below as it stood when found.** `CLAUDE.md` (the "As of Cinder 0.16" paragraph) said Chat peer-depends on `@lostgradient/cinder`, `conversationalist`, `zod`, and `svelte`. The installed `@lostgradient/chat@0.9.2` `package.json` lists `peerDependencies` of only `@lostgradient/cinder`, `@lostgradient/markdown`, and `svelte` — `conversationalist` and `zod` are chat's own regular dependencies, exactly as the cinder#753 fix (documented lower in the same file) says they should be. The paragraph also never mentions `@lostgradient/markdown` as a peer at all.

Acceptance criteria:

- The peer-dependency description is corrected to match `@lostgradient/chat@0.9.2`'s actual `peerDependencies`.
- `@lostgradient/markdown` is named as a peer.

#### CA-2: `README.md` documented a `bun link` workflow the project deliberately removed — done

**Resolved; described below as it stood when found.** `README.md` described `@lostgradient/cinder`/`conversationalist`/`armorer` as linked from local `../cinder` and `../agent-bureau` checkouts, `bun run dev` picking up live edits with no build step, and `bun run sync:cinder` "re-linking" — all contradicting `CLAUDE.md`'s explicit, deliberate rule that chatroom consumes published npm packages, not a `bun link` (a rule that exists specifically because linking hid the cinder#756 hydration mismatch). The README also never mentions `@lostgradient/chat` or `@lostgradient/editor`/ReviewEditor by name, and its scripts table omits `check:peers`.

Acceptance criteria:

- `README.md` describes the actual published-package consumption model, matching `CLAUDE.md`.
- Chat and ReviewEditor are both named as things this repo exercises.
- The scripts table includes `check:peers`.

#### CA-3: `sync-cinder` skill undersold what the sync script actually does — done

**Resolved; described below as it stood when found.** `.claude/skills/sync-cinder/SKILL.md` described bumping only `@lostgradient/cinder` and `@lostgradient/chat`. `scripts/sync-cinder.ts`'s `packages` array actually bumps five: `@lostgradient/cinder`, `@lostgradient/chat`, `@lostgradient/editor`, `@lostgradient/markdown`, and `armorer` — this is the same gap `I-2` above fixed in the script itself, but the skill doc describing that script was never updated to match.

Acceptance criteria:

- `SKILL.md`'s description and steps name all five packages the script bumps.

#### CA-4: `CLAUDE.md` cites a closed, shipped-fixed issue as a live trap — done

**Resolved; described below as it stood when found, at `@lostgradient/editor@0.9.0`/`0.9.1`.** `CLAUDE.md`'s ReviewEditor section said the shipped `with-comments` example seeds raw-Markdown indices and is wrong, citing `stevekinney/cinder#1267`. That issue is closed (`stateReason: COMPLETED`), and the installed `@lostgradient/editor`'s `with-comments` example now seeds correct ProseMirror positions with an inline comment explaining the two coordinate spaces — exactly the requested fix, already in the version this repo depended on at the time. **Reverified at the currently-installed `0.10.0`**: still true — the example still seeds correct ProseMirror positions with the same explanatory comment. `CLAUDE.md` itself says elsewhere that a closed issue citing unresolved behavior should be verified, not left standing; this is the same failure in reverse, an already-fixed bug still cited as current.

Acceptance criteria:

- Confirm against the installed `@lostgradient/editor` version whether the `with-comments` example is actually fixed.
- If fixed, remove the warning (or convert it to a changelog note) rather than leaving it as live guidance to route around a bug that no longer exists.

#### CA-5: two pointers in this file were doubted, and both hold — done

Both pointers were verified and **both hold as written**. The original finding's two negative results were artifacts of a stale local checkout: `../cinder`'s local `main` was two commits behind `origin/main`, missing the merge of [stevekinney/cinder#1285](https://github.com/stevekinney/cinder/pull/1285) (merged 2026-08-13), which is where both pieces of the answer landed.

- The happy-dom keyed-`{#each}` trap **is** documented in `packages/chat/src/lib/test/happy-dom.ts`, under the heading `## Known limitation: keyed {#each} with a conditional body does not reconcile`. It is on `origin/main` (authored as `0b63773d7` on the `steve/polish-chat-and-review` branch, which squash-merged as `bfcd9ed49` via #1285 — cite the merge commit, since the branch commit does not resolve in a fresh clone) and cites cinder#1286 — which is closed as `NOT_PLANNED`, correctly, since the behavior turned out to be a happy-dom artifact rather than a component defect. The file is a test-only helper and is **not** part of the published tarball, so `node_modules` is the wrong place to look for it; the pointer is to cinder's source, and it resolves there.
- The **focus backstop** exists and is named as such: `packages/chat/src/lib/components/chat/container/chat.svelte`, in the docblock beginning `Backstop for focus orphaned by a row leaving the DOM.` Its two triggers are a scroll-state recompute and _the rendered-set effect_, both described in that same block. Unlike the happy-dom helper, this one **does** ship — it was present in the installed `@lostgradient/chat@0.9.2` at the time this was found, and remains present at the currently-installed `@lostgradient/chat@0.9.4`, at `node_modules/@lostgradient/chat/dist/components/chat/container/chat.svelte`. So `I-1`'s acceptance criterion is coherent and is testable against the package this repo actually consumes.

Acceptance criteria, both met: the `happy-dom.ts` pointer is confirmed rather than corrected, and the "focus backstop" mechanism is located by name in cinder's source and in the published package.

Worth carrying forward: a grep-based negative result over `../cinder` is only as current as that checkout. Confirm against `origin/main` or the installed package before concluding something upstream does not exist.

### Harness risk

`harness-skeptic` swept the whole test setup rather than one finding. Headline context: this repo runs zero happy-dom/jsdom tests — everything is Playwright against a real server — so `I-1`'s specific failure mode doesn't recur here. The risk in this repo is a level up: what the _mocks_ fail to reproduce about the real network/streaming/approval path, and what the _browser matrix_ fails to cover.

#### HS-1: the one test path that mirrors production streaming never delivers an actually-incremental stream — done

`src/routes/page.svelte.e2e.ts` is the only suite exercising `+page.svelte`'s real `fetch('/api/chat')` → `response.body.getReader()` → per-line `pushToken` path (as opposed to the `/exercises/*` pages, which drive `pushToken` with real `setTimeout` delays and are fine). It used to mock the network with a single static `page.route(...).fulfill({ body })`, arriving as one chunk, never a real multi-chunk stream over time.

`src/routes/streaming-fixture.ts` — a small local HTTP server gated by `POST /__fixture/release` rather than a timer, so "partial text is on screen while the response is still open" is a causal claim, not a timing guess — stands in for the Anthropic API, verified by `harness-skeptic` to change zero application code (the SDK resolves `baseURL` from `ANTHROPIC_BASE_URL` at construction). Building this exercise found a real, previously-unknown production bug: pressing "stop generating" against a request with real partial content already buffered crashed the Node server, because `src/routes/api/chat/+server.ts` never registered an `abort` listener on the Anthropic SDK's `MessageStream`, and the SDK's own `_emit('abort')` synthesizes an unhandled rejection when nothing is listening. Fixed with a one-line, deliberately-no-op listener; `harness-skeptic` reverted it and watched the server actually die, then restored and re-verified.

Acceptance criteria, both met:

- A fixture stands in for the Anthropic response with genuine multi-chunk timing.
- A test exercises stop-generation with real partial content already buffered, asserting the retain-partial-content branch specifically.

#### HS-2: the real tool-approval server round trip is completely untested — done

`src/routes/api/chat/resume/+server.ts` — the route verifying armorer's signed `approvalToken` via `toolbox.resumeApproval` — used to be referenced from exactly one place in the repo (`+page.svelte`) and from zero e2e tests. `/exercises/tool-approval` fakes the entire approve/deny flow with an in-page adapter that never calls the real server route, so it validates Chat's UI affordances, not the signature-verification path.

`page.svelte.e2e.ts` now drives the real route twice: a forged 64-character-hex `approvalToken` is rejected with a real 500 from `toolbox.resumeApproval`, and a real signed token — minted the way armorer actually mints one for `remember_note` — round-trips and re-executes the tool.

Acceptance criteria, met:

- A Playwright test drives the real `/` page (or a new exercise) through `/api/chat/resume`, asserting the client sends the real `approvalToken` shape and handles the real response shape — either against the real route with a stubbed `toolbox`, or a route mock narrow enough to prove the shape rather than fake the whole flow.

#### HS-3: Playwright runs Chromium only, despite "confirmed in a real browser" being this project's standard of proof — wip

`playwright.config.ts` has no `projects` array, so every "real browser" finding this repo produces is only confirmed in one engine. That specifically matters for the two categories this project already knows diverge across engines: focus behavior (WebKit's focus-on-click/blur-on-removal semantics differ from Chromium's — squarely `a11y-ssr-auditor`'s domain) and streaming/fetch (`ReadableStream` backpressure and chunk-delivery timing have known WebKit quirks, directly relevant to `HS-1`).

Acceptance criteria:

- Add `webkit` (and ideally `firefox`) to a `projects` array in `playwright.config.ts`, at minimum gated to the focus/a11y and streaming specs.
- Update any doc language that says a finding was "confirmed in a real browser" to name which engine(s), going forward.

#### HS-4: no CI trace/screenshot/video capture is configured — wip

`playwright.config.ts` sets no `use.trace`, `use.screenshot`, `use.video`, or `retries`. A flaky-looking failure has no artifact trail to diagnose from, which is exactly the pressure that produces "just bump the timeout" — the move `CLAUDE.md` and this project's own history (see the `no-timeout-bumps-for-ci-failures` lesson) already rule out.

Acceptance criteria:

- `use.trace: 'retain-on-failure'` (or equivalent) is configured so a failing run leaves a trace to inspect, without resorting to a timeout bump to make flakiness go away.

### Test integrity

`test-integrity-auditor` verified three existing "pinned bug" tests are genuinely load-bearing by reverting their upstream fix in `node_modules` and watching them fail (in `review-anchoring.e2e.ts`, `review-state-and-session.e2e.ts`, and `review-comment-lifecycle.e2e.ts` — all confirmed solid, restored after). The findings below are from the rest of the sweep.

#### TI-1: fixed `waitForTimeout` padding across four e2e files — wip

Genuine fixed sleeps (not polls) are used to outlast a debounce before asserting an absence, in `review-modes.e2e.ts` (`SELECTION_SETTLE_MS = 400`), `review-comment-creation.e2e.ts` (`KEY_SETTLE_MS = 60`, `SELECTION_SETTLE_MS = 300`), `review-anchoring.e2e.ts` (`SETTLE_MS = 900`, `LATE_PASTE_SETTLE_MS = 1400`), and `hydration.e2e.ts` (a bare `waitForTimeout(1000)` after the hydration beacon, to catch a trailing console warning — this one has no cited mechanism for why 1000ms is enough, unlike the others, which at least cite a documented plugin debounce). `CLAUDE.md`'s own rule treats any `waitForTimeout` as a blocking finding with no exception. Concrete failure scenario: if a debounce interval regresses upward, these waits "pass" by luck up to some threshold rather than proving the contract in general.

Acceptance criteria:

- Each of these sleeps is converted to a poll against an observable condition (e.g. `expect.poll` against `anchorJson()`, or a readiness data attribute) rather than a fixed guessed duration.
- For `hydration.e2e.ts` specifically: either find the actual mechanism that schedules a trailing hydration-mismatch warning relative to the beacon and poll for it, or document why a fixed wait is the only option here.

#### TI-2: no UI-driven coverage for a stale thread/comment id reaching the reducer — done

`review-comment-lifecycle.e2e.ts`'s reducer-direct block covers unknown ids for `deleteComment` by calling the pure function directly, but no test drove this through the actual UI/component event — the case where a stale `threadId`/`commentId` (already removed by another tab, or a delayed callback) reaches `deleteComment`/`updateComment` through a real user action rather than a bare function call.

**The original premise did not survive contact with the package.** `review-comment-lifecycle.e2e.ts:835-867` documents why: every mutation method on the installed `@lostgradient/editor` re-looks-up the id in the current `threads` array and no-ops before invoking any consumer callback at all. So there is no real UI path that can deliver a stale id past that guard — the component itself closes the race this item was written to test. Two tests now pin that closed door directly (`review-comment-lifecycle.e2e.ts`, "a deferred `commentdelete` flushed after its thread is gone no-ops and keeps the array" and "a deferred `commentupdate` flushed after its thread is gone no-ops the same way"), driving a delete/update through the real UI against an id that has already been removed via another path, and asserting the no-op — which is the strongest form of "UI-path coverage" available once the premise of a reachable stale-id bug is gone.

Acceptance criteria, revised to match what was actually decided:

- A UI-path test triggers a delete/update on a thread or comment that has already been removed via another path, asserting the same well-defined no-op behavior the reducer-direct test pins, reached the way a real user would trigger it. **Met.**

### Accessibility and SSR

`a11y-ssr-auditor` swept the whole `/exercises` surface rather than one change, and reproduced one finding live in Chromium rather than reasoning about it statically.

#### A11Y-1: most SSR'd exercise routes are missing from `HYDRATING_ROUTES` — wip

**Both acceptance criteria are now met; found by a `contract-auditor` board-round-5 general sweep, which this section had not caught up to.** `src/routes/hydration.e2e.ts`'s `HYDRATING_ROUTES` now lists all **30** routes — `/`, `/exercises`, and all **28** exercise directories, `review-ssr-and-a11y` included — diffed directly against the filesystem, not assumed. The gap this item originally described (seven listed, five of them exercises, against 25 exercise directories at the time) closed somewhere in the batches since, without this section being updated to say so.

Acceptance criteria, both met:

- Every exercise route that unconditionally renders Chat or ReviewEditor server-side is added to `HYDRATING_ROUTES`, `review-ssr-and-a11y` included.
- New exercises get added to this list as a matter of course going forward — every route added by this session's own batches (`review-imperative`, `diff-viewer`, `markdown-editor`, `row-reconciliation`) is present.

Left at `wip` rather than `done`: the code and coverage are there, but this item has not itself gone through a dedicated board round the way batches A–F just did — a future round should confirm and move the status word rather than have it self-declared here.

#### A11Y-2: closing the artifact panel drops focus to `<body>` — done

`/exercises/artifacts`' `closePanel` unmounted `ArtifactPanel` entirely (`{#if open && panel}`), and nothing restored focus to the button that opened the panel — reproduced live in Chromium: open the panel, close it, `document.activeElement` was `<body>`. Filed as [cinder#1299](https://github.com/stevekinney/cinder/issues/1299) (closed), fixed upstream in `ArtifactPanel`'s own `focusOnMount`: it now captures `document.activeElement` on mount and restores it on cleanup if the element is still connected. Released in `@lostgradient/chat@0.9.3` (`0.9.2` predates the fix by a day — published 2026-08-13, a day before #1299 was even filed), further released since to `0.9.4`, synced. `artifacts.e2e.ts` now asserts the post-close focus target — `board round 5`'s `a11y-ssr-auditor` live-confirmed it survives three cycles of open/close across three different openers, not just once.

Acceptance criteria, all met:

- Closing the artifact panel returns focus to the control that opened it (or another assertable, sensible target).
- `artifacts.e2e.ts` asserts the post-close focus target.
- If the fix belongs in `@lostgradient/chat`'s `ArtifactPanel` rather than the exercise page, this is filed and driven through the upstream loop rather than patched locally.

#### A11Y-3: error live regions are mounted only after the error occurs, in seven files — done

`message-lifecycle/adapter-panel.svelte`, `message-lifecycle/plain-panel.svelte`, `adapter-push/subscribe-in-effect-hazard-fixture.svelte`, `adapter-push/+page.svelte`, `tool-approval/+page.svelte`, `interleaving/+page.svelte`, and the main demo route `src/routes/+page.svelte` used to mount a `role="alert"` banner only once an error existed, so the live-region node didn't exist in the DOM until the error had already happened. Six of the seven gated it behind `{#if error}` directly; `adapter-push/subscribe-in-effect-hazard-fixture.svelte` reached the same outcome through a different mechanism — its banner lived inside a `{#snippet failed(caughtError, reset)}` boundary, mounted only once that boundary activated. Chat's own `chat-status-announcer.svelte` explicitly documents the opposite pattern — keep the live region permanently mounted, since "mounting with pre-existing text is not reliably announced" — and these seven now follow it.

All seven are permanently mounted with empty content (`{error ?? ''}` or equivalent), toggling only the text. The boundary-based one needed a different fix from the other six: its error is mirrored out through `svelte:boundary`'s `onerror` into a permanently-mounted region, and the in-snippet paragraph deliberately lost its own `role="alert"` — two live regions for one error would announce it twice. Pinned by `error-live-regions.e2e.ts`, collecting all seven in one place; `board round 5`'s `a11y-ssr-auditor` re-confirmed each region exists before the error-triggering action and break-tested one (re-gating `interleaving`'s banner behind `{#if error}`) to confirm the assertions are load-bearing.

Acceptance criteria, both met:

- Each of the seven banners is permanently mounted with empty content, toggling only the text, matching Chat's own documented pattern.
- A test asserts the live-region element exists in the DOM before the error-triggering action, not just after.

#### A11Y-4: eight pinned "known bug" tests were never routed through the upstream loop — wip

**Now eight, not six — the count grew as `RE-4` was built, and this section was not updated to match at the time.** Eight tests are explicitly labelled "(pinned known bug)" and pin defects in `@lostgradient/editor`. Five in `review-ssr-and-a11y.e2e.ts`: `data-ready` is meant as a first-paint signal but is derived from a latch that is set once and never cleared, so it survives an unmount and reports stale readiness ([stevekinney/cinder#1301](https://github.com/stevekinney/cinder/issues/1301)); Tab is swallowed inside a list and silently indents it with no escape, a WCAG 2.1.2 keyboard trap ([#1302](https://github.com/stevekinney/cinder/issues/1302)); unselected view tabs point `aria-controls` at panels that don't exist, since inactive views are removed via `{#if}` rather than hidden ([#1303](https://github.com/stevekinney/cinder/issues/1303)); anchored-comment decorations (`.comment-anchor`) carry no role/tabindex/aria-* and are mouse-only, invisible to keyboard and assistive tech ([#1304](https://github.com/stevekinney/cinder/issues/1304)); the thread popover declares `aria-modal` without matching focus-trap semantics, though its actual Tab-cycling behavior is fine — the mismatch is specifically the unbacked attribute ([#1305](https://github.com/stevekinney/cinder/issues/1305)). A sixth, the same class of unrouted upstream pin, lives in `review-modes.e2e.ts`: `placeholder` becomes an inline `--editor-placeholder` custom property unconditionally, with no emptiness check, and is never actually painted ([#1306](https://github.com/stevekinney/cinder/issues/1306)). Two more were added by `RE-4`'s `scrollToThread` coverage in `review-imperative.e2e.ts`, and these two remain genuinely unfiled: `scrollToThread` computes an offset and calls `scrollTo` on `view.dom` (the `.ProseMirror` contenteditable), which carries no `overflow` in any shipped stylesheet — only its `.markdown-editor` ancestor does — so the call is clamped to 0 and nothing moves, even though the identical anchor is reachable via plain `scrollIntoView`, which the component's own `scrollAnchorIntoView` path already uses; and `scrollToThread` given an unknown thread id fails invisibly (no throw, no observable effect) rather than the visible failure `RE-4`'s own acceptance criteria ask for.

**Filing status, corrected: six of eight are already filed and open, not zero.** All six were filed by `stevekinney` on 2026-08-14 between 19:38 and 19:42 UTC — found by a `contract-auditor` board-round-5 re-review that checked `gh issue view` directly rather than trusting this section's prior "no matching issue exists... for any of the eight" claim, which was false. The filing did not happen through this session's own tool calls; it is unattributed here beyond the account and timestamp, consistent with this repo's documented pattern of concurrent sessions working the same tree. Only `scrollToThread`'s two defects remain unfiled. Per `CLAUDE.md`, six of these issues are now in the "filed, not yet fixed" state the doctrine treats as an active obligation, not something to leave standing — driving them (plus the two still unfiled, plus `X-2`'s own already-filed issue below) through the rest of the loop is the next major body of work after this board round closes, not a future maybe.

Acceptance criteria:

- Each of the eight is filed against `stevekinney/cinder` (six done, two remaining) and driven through the upstream loop in `CLAUDE.md` (file, fix in a worktree, PR to green, merge, release, sync back) — not left as a permanently-pinned local workaround.
- The "(pinned known bug)" test labels are updated to reference the filed issue, and removed once each fix ships and is synced.
