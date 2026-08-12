import { expect, test } from '@playwright/test';
import { gotoHydrated } from '../hydration';
import type { Page } from '@playwright/test';

// Where a ReviewEditor anchor actually lands, how it drifts under editing, and
// when it is silently lost or silently moved.
//
// Two things make this route different from the other `review-*` exercises.
//
// First, positions. `anchor.from`/`anchor.to` are PROSEMIRROR POSITIONS while
// `lastKnownOffset` is a `doc.textBetween()` offset — two coordinate systems in
// one object, neither labelled. Every number asserted below was read off the
// live document, not guessed from the markdown source.
//
// Second, timing. The plugin's re-anchoring pass is DEFERRED: it runs 300ms
// after the last document change. Half the behaviours here are only visible on
// one side of that debounce, so the page exposes buttons that drive precise
// ProseMirror transactions rather than typing — a keyboard-driven repro cannot
// land two edits inside 300ms on purpose, and cannot land them 450ms apart on
// purpose either.

const ROUTE = '/exercises/review-anchoring';

/** The page mounts five ReviewEditors. */
const INSTANCE_COUNT = 5;

// The plugin debounces deferred re-anchoring 300ms after the last document
// change. An assertion about something NOT happening has to outlast that; an
// assertion about something happening uses an auto-retrying matcher instead.
const SETTLE_MS = 900;

// `drift-move-slow` reinserts the deleted word 450ms after deleting it. Waiting
// past the paste AND the debounce it restarts is the only way to see that the
// restored text does not bring the thread back.
const LATE_PASTE_SETTLE_MS = 1400;

/** The drift instance's anchor exactly as the page seeds it. */
const SEEDED_DRIFT_ANCHOR = {
	from: 44,
	to: 53,
	quote: 'dashboard',
	prefix: 'The first release includes a ',
	suffix: ' and export actions.',
	status: 'anchored',
	originalQuote: 'dashboard',
	lastKnownOffset: 42
};

async function ready(page: Page) {
	await gotoHydrated(page, ROUTE);
	// `data-ready` goes up once a ReviewEditor's ProseMirror view exists and no
	// deferred state is pending. Waiting for all five keeps a test from
	// measuring decorations before the plugin has been handed its threads.
	await expect(page.locator(`[data-testid="review-editor"][data-ready="true"]`)).toHaveCount(
		INSTANCE_COUNT
	);
}

/** Read one of the page's rendered anchor JSON panels. */
async function anchorJson(page: Page, testId: string) {
	const text = await page.getByTestId(testId).textContent();
	return JSON.parse(text ?? 'null') as Record<string, unknown> | null;
}

// A fresh page per test. Several of these tests mutate their instance
// irreversibly — deleting the anchored word, moving it, replacing `value` — so
// sharing one page would make the suite order-dependent.
test.beforeEach(async ({ page }) => {
	await ready(page);
});

test.describe('review-anchoring: where a seeded anchor lands', () => {
	test('a correctly-seeded anchor decorates exactly its quoted range', async ({ page }) => {
		// One inline decoration per anchor, each covering only its quote. The
		// span COUNT is the load-bearing part: ProseMirror splits a single
		// decoration into one span per text block it crosses, so an anchor that
		// had been mapped across the whole document would show up here as five
		// spans — one per text block in this fixture — rather than two.
		await expect(page.locator('#anchor-mount h1, #anchor-mount h2, #anchor-mount p')).toHaveCount(
			5
		);
		await expect(page.locator('#anchor-mount .comment-anchor')).toHaveCount(2);

		// "Release Plan" is PM 1..13 because "# " is markup, not text; the
		// decoration proves the seed named the right range.
		await expect(page.locator('#anchor-mount h1 .comment-anchor')).toHaveText('Release Plan');
		// "dashboard" is PM 44..53 in the same document — 15 (the paragraph's
		// first text position) plus the 29 characters that precede the word.
		await expect(page.locator('#anchor-mount p .comment-anchor')).toHaveText('dashboard');
	});

	test('a document-level anchor decorates nothing and exists only in the sidebar', async ({
		page
	}) => {
		// Three threads, two decorations. The third has `quote: ''` and a
		// zero-width range, which the plugin's `from >= to` guard skips outright.
		await expect(page.getByTestId('mount-thread-count')).toHaveText('threads: 3');
		await expect(page.locator('#anchor-mount .comment-anchor')).toHaveCount(2);

		await page
			.getByTestId('instance-mount')
			.getByRole('button', { name: /comments sidebar/ })
			.click();

		const items = page.locator('#anchor-mount-sidebar .thread-item');
		await expect(items).toHaveCount(3);
		// Document-level threads sort ahead of the anchored ones and render a
		// label instead of a quote, which is the only place they are visible.
		await expect(items.first()).toContainText('Document comment');
		await expect(items.first()).toContainText('Overall: ship it.');
	});

	test('the same anchor assigned after mount lands exactly where the mount-seeded one did', async ({
		page
	}) => {
		// This pair used to disagree: a thread present in the INITIAL `threads`
		// prop was mapped through Milkdown's wholesale content-set step and came
		// out spanning the entire document, while the identical thread assigned a
		// tick later produced one span. The asymmetry is gone — both paths now
		// verify the seeded range against the document rather than trusting a
		// meaningless mapping.
		await expect(page.locator('#anchor-late .comment-anchor')).toHaveCount(0);

		await page.getByTestId('seed-late').click();

		await expect(page.locator('#anchor-late .comment-anchor')).toHaveCount(1);
		await expect(page.locator('#anchor-late h1 .comment-anchor')).toHaveText('Release Plan');
		expect(await anchorJson(page, 'late-json')).toEqual({
			from: 1,
			to: 13,
			quote: 'Release Plan',
			prefix: '# ',
			suffix: '\n\nThe first release',
			status: 'anchored',
			originalQuote: 'Release Plan',
			lastKnownOffset: 0
		});
	});
});

test.describe('review-anchoring: repairing a mis-seeded anchor', () => {
	test('an off-by-one anchor in a paragraph is repaired, and the repair is written back', async ({
		page
	}) => {
		// Seeded at {from: 45, to: 54} — one position right of "dashboard", so
		// the stored range actually covers "ashboard ". The plugin verifies a
		// seeded range against the document (`textBetween(from, to) === quote`),
		// finds the mismatch, and hands the anchor to the deferred pass, which
		// searches by QUOTE and lands on the real 44..53.
		await expect(page.locator('#anchor-offbyone p .comment-anchor')).toHaveText('dashboard');

		// The repair is not cosmetic: it is published back through the bindable
		// `threads` prop. Note what happens to the context while it is there —
		// the seeded `prefix` was a plausible-looking slice of the MARKDOWN, and
		// it is replaced by real `textBetween` output, where the blank line
		// between blocks is a single "\n" and the heading's "# " does not exist.
		// `suffix` gets the same treatment and stops at 45 characters because the
		// 50-position window it asks for includes node boundaries, which are not
		// text.
		await expect
			.poll(() => anchorJson(page, 'offbyone-dashboard-json'))
			.toEqual({
				from: 44,
				to: 53,
				quote: 'dashboard',
				prefix: 'Release Plan\nThe first release includes a ',
				suffix: ' and export actions.\nChecklist\nFinalize the co',
				status: 'anchored',
				originalQuote: 'dashboard',
				lastKnownOffset: 42
			});
	});

	test('an off-by-one anchor in a HEADING is repaired too, not corrupted', async ({ page }) => {
		// Same mistake as the paragraph above, one block up: {from: 2, to: 14}
		// instead of {from: 1, to: 13}. This case used to be permanent, and the
		// asymmetry with the paragraph is what gave the mechanism away.
		//
		// Marking an anchor for re-anchoring only schedules work 300ms out. Any
		// transaction overlapping the WRONG stored range that lands first used to
		// take the plugin's "the edit was inside this anchor" branch, which
		// rewrote its copy of `quote` to whatever text sat at that range. The
		// anchor then looked internally consistent, the deferred pass's
		// `textBetween(from, to) === quote` check passed, and re-anchoring never
		// ran. Headings get such a transaction for free — Milkdown assigns every
		// heading a slug `id` via `setNodeMarkup`, whose step spans the whole
		// node — and paragraphs get no equivalent. Hence one repaired and one not.
		//
		// cinder#1275 gates that branch on the anchor having verifiably described
		// its own text BEFORE the transaction, so an anchor that never checked out
		// keeps its quote and is relocated by search instead.
		const headingAnchor = page.locator('#anchor-offbyone h1 .comment-anchor');
		await expect(headingAnchor).toHaveText('Release Plan');
		// The heading still gets its Milkdown slug — the trigger is unchanged;
		// what changed is that it no longer cements the anchor.
		await expect(page.locator('#anchor-offbyone h1')).toHaveAttribute('id', 'release-plan');

		// Still correct after the debounce, and stable.
		await page.waitForTimeout(SETTLE_MS);
		await expect(headingAnchor).toHaveText('Release Plan');

		// Document and sidebar now agree. Previously the sidebar quoted the prop
		// ("Release Plan") while the document highlighted "elease Plan", and
		// nothing in the UI disagreed with itself loudly enough to be noticed.
		await page
			.getByTestId('instance-offbyone')
			.getByRole('button', { name: /comments sidebar/ })
			.click();
		await expect(page.locator('#anchor-offbyone-sidebar .thread-quote').first()).toHaveText(
			'Release Plan'
		);
	});
});

test.describe('review-anchoring: anchor states in the document', () => {
	test('hovering an anchor marks it, and leaving it clears the mark', async ({ page }) => {
		const anchor = page.locator('#anchor-mount p .comment-anchor');
		await expect(anchor).toHaveClass('comment-anchor');

		await anchor.hover();
		await expect(anchor).toHaveClass(/comment-anchor--hovered/);

		// Moving the pointer off the span is enough; the plugin listens for
		// mouseout and mouseleave on the editor DOM, not for a click elsewhere.
		await page.mouse.move(0, 0);
		await expect(anchor).not.toHaveClass(/comment-anchor--hovered/);
	});

	test('PINNED KNOWN BUG: the active thread is never visually distinguished in the document', async ({
		page
	}) => {
		// The decoration plugin has a `comment-anchor--active` class and a
		// `set-active` meta transaction for switching it on. Nothing in the
		// component ever dispatches that meta, so the class is unreachable: the
		// thread you are reading looks exactly like every other thread.
		await page
			.getByTestId('instance-mount')
			.getByRole('button', { name: /comments sidebar/ })
			.click();

		const anchor = page.locator('#anchor-mount p .comment-anchor');
		await anchor.click();

		// The component definitely knows which thread is active — the sidebar
		// marks it current — which is what makes the missing decoration state a
		// gap rather than an unimplemented feature.
		const activeItem = page.locator('#anchor-mount-sidebar .thread-item[aria-current="true"]');
		await expect(activeItem).toHaveCount(1);
		await expect(activeItem).toContainText('dashboard');

		// …and the document shows nothing. Note this is not an assertion about a
		// class that merely happens to be absent: the hover test above proves the
		// same `computeDecorations` call DOES emit its other state class, from
		// the same plugin state, through the same code path. Only the meta that
		// would set `activeThreadId` inside the plugin is never sent.
		await expect(page.locator('#anchor-mount .comment-anchor--active')).toHaveCount(0);
		// Asserted as a non-match rather than an exact class list, because the
		// click leaves the pointer on the span and therefore leaves
		// `comment-anchor--hovered` behind.
		await expect(anchor).not.toHaveClass(/comment-anchor--active/);
	});
});

test.describe('review-anchoring: drift under ordinary editing', () => {
	test("text inserted at the anchor's LEFT edge is absorbed, and the prop never hears about it", async ({
		page
	}) => {
		// The plugin maps `from` with bias -1, so a character inserted at exactly
		// `from` lands inside the range rather than before it.
		const anchor = page.locator('#anchor-drift .comment-anchor');
		await page.getByTestId('drift-insert-before').click();
		await expect(anchor).toHaveText('Xdashboard');

		// The plugin rewrote ITS copy of the quote to "Xdashboard". The bindable
		// `threads` prop is not on that path: only the deferred re-anchoring pass
		// publishes anchor updates, and it does not run here because the anchor
		// still matches the plugin's own (rewritten) idea of itself. Wait out the
		// debounce to prove the silence is permanent, not merely early.
		await page.waitForTimeout(SETTLE_MS);
		await expect(anchor).toHaveText('Xdashboard');
		expect(await anchorJson(page, 'drift-json')).toEqual(SEEDED_DRIFT_ANCHOR);
	});

	test("text inserted at the anchor's RIGHT edge is absorbed too", async ({ page }) => {
		// `to` maps with bias +1, so the anchor is greedy at both ends.
		const anchor = page.locator('#anchor-drift .comment-anchor');
		await page.getByTestId('drift-insert-after').click();
		await expect(anchor).toHaveText('dashboard!');

		await page.waitForTimeout(SETTLE_MS);
		await expect(anchor).toHaveText('dashboard!');
		expect(await anchorJson(page, 'drift-json')).toEqual(SEEDED_DRIFT_ANCHOR);
	});

	test('deleting the anchored text removes the thread, fires onthreaddelete, and announces it', async ({
		page
	}) => {
		// `comments/types.ts` documents this as the reason there is no "orphaned"
		// anchor status: "When anchor text is deleted, threads are automatically
		// removed." That removal genuinely happens now — the plugin detects the
		// collapsed range, the deferred pass fails to find the quote anywhere in
		// the document, and the component drops the thread from the bindable
		// array rather than leaving it pointing at text that is gone.
		await page.getByTestId('drift-delete').click();

		await expect(page.getByTestId('drift-thread-count')).toHaveText('threads: 0');
		await expect(page.locator('#anchor-drift .comment-anchor')).toHaveCount(0);
		await expect(page.getByTestId('drift-json')).toHaveText('null');
		await expect(page.getByTestId('event-log')).toContainText('drift:threaddelete:drift-dashboard');

		// The announcement goes to a correctly hidden `role="status"` region, so
		// it is never visible text — and it clears itself after 1000ms. The page
		// mirrors it into an append-only log precisely so this assertion is not
		// racing that timer.
		await expect(page.getByTestId('announcements')).toContainText(
			'Comment thread removed because its anchored text was deleted'
		);

		await page
			.getByTestId('instance-drift')
			.getByRole('button', { name: /comments sidebar/ })
			.click();
		await expect(page.locator('#anchor-drift-sidebar .thread-item')).toHaveCount(0);
		await expect(page.locator('#anchor-drift-sidebar')).toContainText('No comments yet');
	});

	test('delete-and-reinsert inside the debounce moves the anchor AND writes it back', async ({
		page
	}) => {
		// Both edits in one synchronous burst, so the 300ms timer only ever fires
		// once, against the finished document. This is the sole path that
		// publishes new coordinates through the bindable prop.
		await page.getByTestId('drift-move-burst').click();

		await expect(page.locator('#anchor-drift p')).toHaveText(/^dashboard The first release/);
		await expect(page.locator('#anchor-drift .comment-anchor')).toHaveText('dashboard');
		await expect(page.getByTestId('drift-thread-count')).toHaveText('threads: 1');
		await expect(page.getByTestId('event-log')).toBeEmpty();

		// Everything positional changes together: the ProseMirror range, the
		// textBetween offset, and freshly recomputed context on both sides.
		// `originalQuote` is the only field deliberately frozen.
		await expect
			.poll(() => anchorJson(page, 'drift-json'))
			.toEqual({
				from: 15,
				to: 24,
				quote: 'dashboard',
				prefix: 'Release Plan\n',
				suffix: ' The first release includes a  and export actions.',
				status: 'anchored',
				originalQuote: 'dashboard',
				lastKnownOffset: 13
			});
	});

	test('the same move with a 450ms pause loses the anchor permanently', async ({ page }) => {
		// Identical edits, identical end state, 450ms apart instead of 0ms — and
		// no human cuts and pastes in under 300ms. The debounce expires during
		// the gap, the deferred pass finds no "dashboard" in the document, and
		// the thread is deleted. Pasting the word back verbatim does not undo
		// that: there is no thread left to re-anchor.
		await page.getByTestId('drift-move-slow').click();
		await expect(page.getByTestId('drift-thread-count')).toHaveText('threads: 0');

		await page.waitForTimeout(LATE_PASTE_SETTLE_MS);

		// The text is back, exactly where the successful burst put it.
		await expect(page.locator('#anchor-drift p')).toHaveText(/^dashboard The first release/);
		// The thread is not.
		await expect(page.locator('#anchor-drift .comment-anchor')).toHaveCount(0);
		await expect(page.getByTestId('drift-thread-count')).toHaveText('threads: 0');
		await expect(page.getByTestId('drift-json')).toHaveText('null');
		await expect(page.getByTestId('event-log')).toContainText('drift:threaddelete:drift-dashboard');
	});

	test('replacing `value` wholesale re-anchors by quote instead of expanding to the document', async ({
		page
	}) => {
		// Assigning a new string to `value` produces one step spanning the whole
		// old document. Position mapping across such a step is meaningless — it
		// used to collapse `from` to 0 and push `to` to docSize, which rendered
		// the anchor as one span per text block (two here) and, worse, overwrote
		// the stored quote with the entire document text, destroying the only
		// information a recovery could have used.
		//
		// Now the plugin recognises the shape of that step, keeps quote/prefix/
		// suffix untouched, and defers to a search. Note there IS a visible
		// window of roughly one debounce during which the decoration still sits
		// at the stale positions and highlights the wrong characters; the
		// settled state is what is asserted here.
		await page.getByTestId('drift-replace-value').click();

		await expect(page.locator('#anchor-drift p')).toHaveText(
			'Export actions ship first; the dashboard follows in a later release.'
		);
		await expect(page.locator('#anchor-drift .comment-anchor')).toHaveCount(1);
		await expect(page.locator('#anchor-drift .comment-anchor')).toHaveText('dashboard');
		await expect(page.locator('#anchor-drift h1 .comment-anchor')).toHaveCount(0);

		await expect
			.poll(() => anchorJson(page, 'drift-json'))
			.toEqual({
				from: 46,
				to: 55,
				quote: 'dashboard',
				prefix: 'Release Plan\nExport actions ship first; the ',
				suffix: ' follows in a later release.',
				status: 'anchored',
				originalQuote: 'dashboard',
				lastKnownOffset: 44
			});
	});
});

test.describe('review-anchoring: ambiguity', () => {
	test('re-anchoring can move a thread onto a DIFFERENT occurrence of its quote', async ({
		page
	}) => {
		const paragraphs = page.locator('#anchor-ambiguous p');
		// The thread starts on the second paragraph's "widget".
		await expect(paragraphs.nth(1).locator('.comment-anchor')).toHaveText('widget');
		await expect(paragraphs.first().locator('.comment-anchor')).toHaveCount(0);

		// Cut that occurrence and paste it at the end of its own paragraph. Two
		// exact matches now exist, and scoring has to pick one: context
		// similarity at 0.7, proximity to `lastKnownOffset` at 0.3. The moved
		// copy sits at the end of the document, so its suffix context scores
		// zero, which is enough to lose to a word in a paragraph the user never
		// touched.
		await page.getByTestId('ambiguous-move').click();

		await expect(paragraphs.nth(1)).toHaveText(/widget$/);
		await expect(page.locator('#anchor-ambiguous .comment-anchor')).toHaveCount(1);
		// The comment has silently relocated to the FIRST paragraph.
		await expect(paragraphs.first().locator('.comment-anchor')).toHaveText('widget');
		await expect(paragraphs.nth(1).locator('.comment-anchor')).toHaveCount(0);

		// No deletion event: as far as the app is concerned the thread is fine.
		await expect(page.getByTestId('ambiguous-thread-count')).toHaveText('threads: 1');
		await expect(page.getByTestId('event-log')).toBeEmpty();

		await expect
			.poll(() => anchorJson(page, 'ambiguous-json'))
			.toEqual({
				from: 7,
				to: 13,
				quote: 'widget',
				prefix: 'Alpha ',
				suffix: ' beta.\nGamma  delta. widget',
				status: 'anchored',
				originalQuote: 'widget',
				lastKnownOffset: 6
			});
	});
});

test.describe('review-anchoring: the re-anchoring functions, driven directly', () => {
	// `reanchorQuote`, `findAllOccurrences`, `fuzzyReanchor` and
	// `scoreContextMatch` are plain exports from `@lostgradient/editor/comments`,
	// which is the only way to see the confidence score the component computes
	// and then discards.

	test('`found` is decided by exact-substring existence alone, with no threshold', async ({
		page
	}) => {
		// Perfect context: the quote is there and the surroundings match exactly.
		await expect(page.getByTestId('reanchor-perfect')).toHaveText(
			'found=true from=42 confidence=1.000'
		);

		// Same quote, same position, context drawn from an alphabet the document
		// does not contain. Confidence bottoms out at exactly zero and `found` is
		// still true — no threshold sits between the two. A consumer sees only
		// `found`, so this is indistinguishable from the case above.
		await expect(page.getByTestId('reanchor-garbage')).toHaveText(
			'found=true from=42 confidence=0.000'
		);
	});

	test('a `found: false` result can carry a HIGHER confidence than a `found: true` one', async ({
		page
	}) => {
		// When the quote is absent entirely, `reanchorQuote` falls through to
		// `fuzzyReanchor`, which hunts for the junction where the text used to be
		// and reports how sure it is about THAT. 0.636 here — against 0.000 for
		// the garbage-context match that returned `found: true`. The two fields
		// answer different questions and neither one alone means "this anchor is
		// good".
		await expect(page.getByTestId('reanchor-absent')).toHaveText(
			'found=false from=41 confidence=0.636'
		);
	});

	test('an empty quote finds nothing, which is what a document-level thread is', async ({
		page
	}) => {
		// `findAllOccurrences` short-circuits on an empty quote, and
		// `fuzzyReanchor` skips its junction search without a prefix, so every
		// document-level anchor round-tripped through this function reports
		// `found: false` — the shape that drops them on a state restore.
		await expect(page.getByTestId('reanchor-empty')).toHaveText(
			'found=false from=0 confidence=0.000'
		);
		await expect(page.getByTestId('occurrences-empty')).toHaveText('0');
	});

	test('overlapping occurrences all count', async ({ page }) => {
		// The scan restarts one character past each hit rather than past the
		// whole match, so "aa" occurs three times in "aaaa", not twice.
		await expect(page.getByTestId('occurrences-overlapping')).toHaveText(
			'3: [{"start":0,"end":2},{"start":1,"end":3},{"start":2,"end":4}]'
		);
	});

	test('the ambiguous case scores out to the earlier occurrence, matching the live editor', async ({
		page
	}) => {
		// The same inputs the live instance produces after its move, run as pure
		// arithmetic: offset 6 is the FIRST paragraph's "widget". The live
		// re-anchor and the pure function agree, which is what makes the live
		// outcome a scoring result rather than an accident of timing.
		await expect(page.getByTestId('reanchor-ambiguous')).toHaveText(
			'found=true from=6 confidence=0.606'
		);
	});
});
