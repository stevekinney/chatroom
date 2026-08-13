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
| Chat props and callbacks        | yes          | 16 exercises, ~87 tests                                                                                                                                                                |
| Chat imperative API             | yes, 12/12   | `announce`, `beginStreaming`, `pushToken`, `endStreaming`, `retryMessage`, `scrollToBottom`/`Top`, `clearInput`, `focusInput`, `getComposerValue`, `getEditorElement`, `insertAtRange` |
| ReviewEditor props              | yes, 9/9     | all of `value`, `original`, `mode`, `snapshotMode`, `currentUserId`, `name`, `id`, `class`, `placeholder`                                                                              |
| ReviewEditor callbacks          | yes, 6/6     | `onchange`, `onthreadcreate`, `onthreaddelete`, `oncommentcreate`, `oncommentupdate`, `oncommentdelete`                                                                                |
| **ReviewEditor imperative API** | **no, 8/23** | the largest gap; see `RE-1` through `RE-4`                                                                                                                                             |
| **DiffViewer standalone**       | **no**       | exported at `@lostgradient/editor/diff-viewer`, only reached through ReviewEditor's diff view                                                                                          |
| **MarkdownEditor standalone**   | **no**       | exported at `@lostgradient/editor/markdown-editor`, 7 imperative methods, none driven                                                                                                  |

## ReviewEditor imperative API

`CLAUDE.md` tells consumers to `bind:this` and use this surface for anything past the props: mutation with `createThread`/`createComment`, output with `exportUnifiedDiff`/`exportMarkdownSummary`, persistence with the `getState`/`setState` round trip. We exercise the persistence half and almost none of the rest.

That this is where defects live is not a guess. `generateUnifiedDiff` corrupting YAML front matter, orphaned threads exporting stale positions, and `deleteComment` silently no-opping on the event the component itself emits were all shipped bugs found by cinder's unit tests rather than here.

Currently driven: `focus`, `getFormData`, `getSelection`, `getState`, `getView`, `setState`, plus `getEditor` and `getMarkdown` indirectly. Not driven at all: the 15 below.

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
