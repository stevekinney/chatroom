import { expect, test } from '@playwright/test';
import type { Locator, Page } from '@playwright/test';
import { gotoHydrated } from '../hydration';

// Pins the READ and MUTATE halves of ReviewEditor's comment surface: the
// sidebar, the thread popover, and the four notification-only callbacks
// (`oncommentcreate` / `oncommentupdate` / `oncommentdelete` / `onthreaddelete`)
// against the page-owned reducer that actually moves `threads`.
//
// Thread creation lives in `review-comment-creation`, and the anchor-decoration
// story in `review-anchoring`; both need fixtures this route cannot have.
//
// Every test starts from a fresh page: the fixture is mutated by most of these
// flows, and a shared page would make each test depend on the ones before it.

const ROUTE = '/exercises/review-comment-lifecycle';

// Literals, not recomputations. The component's truncation budgets are 60 for
// the sidebar quote, 80 for the sidebar preview, and 30 for the popover title —
// re-deriving them here with a slice would assert the spec against itself
// instead of against the component. Note the two different ellipses: `truncate`
// uses the single character '…', the popover title hand-rolls three dots.
const FULL_QUOTE = 'Reviewers should verify that the export dialog copy matches the product brief';
const SIDEBAR_QUOTE_60 = 'Reviewers should verify that the export dialog copy matches…';
const SIDEBAR_PREVIEW_80 =
	'This paragraph is the sentence legal asked us to re-read line by line before th…';
const POPOVER_TITLE_30 = '"Reviewers should verify that t..."';

const sidebar = (page: Page) => page.locator('#lifecycle-editor-sidebar');
const popover = (page: Page) => page.locator('#lifecycle-editor-thread-popover');
const commentsToggle = (page: Page) => page.getByRole('button', { name: /comments sidebar/ });
const threadRows = (page: Page) => sidebar(page).locator('button.thread-item');
const badge = (page: Page) => page.locator('.comments-toggle-wrapper .cinder-badge');
const announcer = (page: Page) => page.locator('.comments-count-announcer');

// Row lookups go by content, never by index: rows disappear from under you as
// threads turn into ghosts, and the surviving rows shift up.
const rowQuoted = (page: Page, quote: string) =>
	threadRows(page).filter({ has: page.locator('blockquote.thread-quote', { hasText: quote }) });

const docRow = (page: Page) => threadRows(page).filter({ hasText: 'Document comment' });

async function openSidebar(page: Page): Promise<void> {
	await commentsToggle(page).click();
	await expect(sidebar(page)).toBeVisible();
}

/**
 * Select a thread from the sidebar and wait for its popover.
 *
 * Selection opens the popover on a ~350ms timer (POSITION_DELAY_MS) and then
 * floating-ui positions it on a later frame, so the popover exists before it is
 * usable. `data-position-ready` is the settled signal — until it flips, the
 * dialog carries `inert` and swallows every click.
 *
 * The click is deliberately offset to the row's top-left instead of using
 * Playwright's default centre point. The sidebar renders BELOW the editor (it
 * is the last child of `.review-editor-container`, not a column beside the
 * document), so the container is ~576px tall inside this route's fixed 30rem
 * wrapper and the last row overflows into the `Observed state` section that
 * follows. That section's `<h2>` paints over the row's lower half, and a
 * centre-point click on the bottom row really is intercepted by the heading —
 * in any browser, not just headless. `x: 12, y: 12` is a real mouse click on
 * the row, landing on the strip no other element covers.
 */
async function selectThread(page: Page, row: Locator): Promise<Locator> {
	await row.click({ position: { x: 12, y: 12 } });
	const dialog = popover(page);
	await expect(dialog).toHaveAttribute('data-position-ready', 'true');
	await expect(dialog).toHaveJSProperty('inert', false);
	return dialog;
}

/** Every logged payload for one callback name, parsed. */
async function payloadsFor(page: Page, name: string): Promise<Record<string, unknown>[]> {
	const rows = await page.getByTestId('event-log').locator('li').allTextContents();
	return rows
		.filter((row) => row.startsWith(`${name} `))
		.map((row) => JSON.parse(row.slice(name.length + 1)) as Record<string, unknown>);
}

test.describe('review comment lifecycle: the sidebar', () => {
	test.beforeEach(async ({ page }) => {
		await gotoHydrated(page, ROUTE);
	});

	test('the sidebar has no `open` prop — it exists only once the toolbar toggle is clicked', async ({
		page
	}) => {
		// Not "hidden": absent. There is no way to render the ReviewEditor with
		// its comment sidebar already open, which means `aria-controls` on the
		// toggle points at an element that does not exist yet.
		await expect(sidebar(page)).toHaveCount(0);
		await expect(commentsToggle(page)).toHaveAttribute('aria-expanded', 'false');
		await expect(commentsToggle(page)).toHaveAttribute('aria-controls', 'lifecycle-editor-sidebar');

		await openSidebar(page);

		// `aria-controls` resolving is the fix from cinder PR #1266: the controls
		// bar is instantiated as `{editorId}-controls`, so deriving the sidebar id
		// from its own id used to produce `lifecycle-editor-controls-sidebar`.
		await expect(sidebar(page)).toHaveAttribute('aria-label', 'Comment threads');
		await expect(commentsToggle(page)).toHaveAttribute('aria-expanded', 'true');
		await expect(sidebar(page).locator('.sidebar-header h2.sidebar-title')).toHaveText('Comments');
	});

	test('threads sort document-first, then by anchor.from, and the all-deleted ghost is omitted', async ({
		page
	}) => {
		await openSidebar(page);

		// Four threads are seeded; `t-empty` has no visible comment, so the
		// sidebar drops it entirely. The count badge counts what it renders.
		await expect(page.getByTestId('thread-count')).toHaveText('threads: 4');
		await expect(threadRows(page)).toHaveCount(3);
		await expect(sidebar(page).locator('.thread-count')).toHaveText('3');

		// Document threads come first regardless of position; text threads follow
		// in ascending `anchor.from` order (1, then 91).
		await expect(sidebar(page).locator('button.thread-item[data-document="true"]')).toHaveCount(1);
		await expect(threadRows(page).nth(0)).toHaveAttribute('data-document', 'true');
		await expect(threadRows(page).nth(0).locator('.thread-document-label')).toHaveText(
			'Document comment'
		);
		await expect(threadRows(page).nth(0).locator('blockquote.thread-quote')).toHaveCount(0);
		await expect(threadRows(page).nth(1).locator('blockquote.thread-quote')).toHaveText(
			'Release Plan'
		);
		await expect(threadRows(page).nth(2).locator('blockquote.thread-quote')).toHaveText(
			SIDEBAR_QUOTE_60
		);

		// The ghost's quote is nowhere in the list even though its anchor is still
		// decorating the document.
		await expect(sidebar(page)).not.toContainText('Timeline risk');
	});

	test('the preview is the first VISIBLE comment, truncated at 80', async ({ page }) => {
		await openSidebar(page);

		await expect(threadRows(page).nth(2).locator('p.thread-preview')).toHaveText(
			SIDEBAR_PREVIEW_80
		);

		// `t-text`'s first comment is by `steve`; soft-deleting it promotes the
		// NEXT visible comment into the preview rather than blanking the row.
		const textRow = rowQuoted(page, 'Release Plan');
		await expect(textRow.locator('p.thread-preview')).toHaveText(
			'Should this say "Launch Plan" instead?'
		);
		const dialog = await selectThread(page, textRow);
		await dialog
			.locator('article.comment[data-comment-id="c-text-steve"]')
			.getByRole('button', { name: 'Delete comment' })
			.click();
		await expect(textRow.locator('p.thread-preview')).toHaveText(
			'Marketing signed off on "Release Plan" last week.'
		);
	});
});

test.describe('review comment lifecycle: the thread popover', () => {
	test.beforeEach(async ({ page }) => {
		await gotoHydrated(page, ROUTE);
		await openSidebar(page);
	});

	test('selecting a thread marks exactly one row active and opens a modal dialog inside the container', async ({
		page
	}) => {
		const dialog = await selectThread(page, rowQuoted(page, 'Release Plan'));

		await expect(rowQuoted(page, 'Release Plan')).toHaveAttribute('data-active', 'true');
		await expect(rowQuoted(page, 'Release Plan')).toHaveAttribute('aria-current', 'true');
		// Exactly one at a time — selection is not additive.
		await expect(sidebar(page).locator('[data-active]')).toHaveCount(1);
		await expect(sidebar(page).locator('[aria-current="true"]')).toHaveCount(1);

		await expect(dialog).toHaveAttribute('role', 'dialog');
		await expect(dialog).toHaveAttribute('aria-modal', 'true');
		await expect(dialog).toHaveAttribute(
			'aria-labelledby',
			'lifecycle-editor-thread-popover-title'
		);

		// NOT portaled — unlike the selection popover, which cinder does portal to
		// `document.body`. This one is a child of the review-editor container, so
		// it inherits the container's stacking context and CSS scope.
		//
		// That container is NOT `#lifecycle-editor`, which is what this used to
		// assert and what never held: the `id` prop lands on the markdown
		// editor's own content div, buried inside `.review-editor-main >
		// .markdown-editor-layout`, and the container merely hangs the DERIVED
		// ids off it (`-controls`, `-sidebar`, `-thread-popover`) while carrying
		// no id of its own. The popover is a direct child of that unlabelled
		// `.review-editor-container`, a sibling of the subtree holding the
		// editor — so pin it by the element that contains both.
		const container = page
			.locator('div.review-editor-container')
			.filter({ has: page.locator('#lifecycle-editor') });
		await expect(container).toHaveCount(1);
		await expect(page.locator('body > #lifecycle-editor-thread-popover')).toHaveCount(0);
		await expect(container.locator('> #lifecycle-editor-thread-popover')).toHaveCount(1);
	});

	test('Escape closes the popover and clears the active row', async ({ page }) => {
		await selectThread(page, rowQuoted(page, 'Release Plan'));

		// The popover traps focus, so a bare page-level Escape lands inside it.
		await page.keyboard.press('Escape');

		await expect(popover(page)).toHaveCount(0);
		await expect(sidebar(page).locator('[data-active]')).toHaveCount(0);
		await expect(sidebar(page)).toBeVisible();
	});

	test('the title truncates the quote at 30 characters and keeps the full quote in `title`', async ({
		page
	}) => {
		const dialog = await selectThread(page, rowQuoted(page, 'Reviewers should verify'));

		await expect(dialog.locator('.thread-popover-quote')).toHaveText(POPOVER_TITLE_30);
		// The only place the untruncated quote survives in the DOM.
		await expect(dialog.locator('.thread-popover-quote')).toHaveAttribute('title', FULL_QUOTE);
	});

	test('a document thread shows a `Document comment` label instead of a quote', async ({
		page
	}) => {
		const dialog = await selectThread(page, docRow(page));

		await expect(dialog.locator('.thread-popover-document-label')).toHaveText('Document comment');
		await expect(dialog.locator('.thread-popover-quote')).toHaveCount(0);
	});
});

test.describe('review comment lifecycle: replying', () => {
	test.beforeEach(async ({ page }) => {
		await gotoHydrated(page, ROUTE);
		await openSidebar(page);
	});

	test('a reply fires oncommentcreate and changes nothing until the reducer applies it', async ({
		page
	}) => {
		const dialog = await selectThread(page, rowQuoted(page, 'Release Plan'));

		// The reply composer's accessible name is `Comment` (from an sr-only
		// label) while its placeholder is `Reply...` — and the inline submit
		// Button is ALSO named `Comment`. Locate the textarea by id to sidestep
		// the collision entirely. The inline submit is `opacity: 0;
		// pointer-events: none` until `:focus-within`, so Cmd/Ctrl+Enter is the
		// reliable path: `fill` focuses first, then the shortcut submits.
		const composer = dialog.locator('#lifecycle-editor-thread-popover-composer');
		await expect(composer).toHaveAttribute('placeholder', 'Reply...');
		await composer.fill('Renaming it now would break the changelog.');
		await composer.press('ControlOrMeta+Enter');

		await expect(page.getByTestId('event-log').locator('li')).toHaveCount(1);
		const [created] = await payloadsFor(page, 'commentcreate');
		expect(created.threadId).toBe('t-text');
		expect(created.authorId).toBe('steve');
		expect(created.body).toBe('Renaming it now would break the changelog.');
		expect(typeof created.requestId).toBe('string');
		expect(created.requestId).not.toBe('');
		// No `@` in the body, so `extractMentions` found nothing and the field is
		// omitted rather than set to an empty array.
		expect('mentions' in created).toBe(false);

		// The point of the whole route: at the moment the callback fired, the
		// bindable `threads` array was untouched. It moved only because the page's
		// reducer called `addComment` on it.
		await expect(page.getByTestId('counts-at-last-event')).toHaveText(
			'at event time: threads:4 visible:4 stored:6'
		);
		await expect(page.getByTestId('visible-comment-count')).toHaveText('visible comments: 5');
		await expect(page.getByTestId('last-changed')).toHaveText('last reducer changed: true');

		// The composer clears itself on submit and keeps focus.
		await expect(composer).toHaveValue('');
		await expect(composer).toBeFocused();
		await expect(dialog.locator('article.comment')).toHaveCount(3);
	});
});

test.describe('review comment lifecycle: editing', () => {
	test.beforeEach(async ({ page }) => {
		await gotoHydrated(page, ROUTE);
		await openSidebar(page);
	});

	test('editing swaps the body for a prefilled textarea labelled `Edit comment`', async ({
		page
	}) => {
		const dialog = await selectThread(page, docRow(page));
		const comment = dialog.locator('article.comment[data-comment-id="c-doc-1"]');
		await comment.getByRole('button', { name: 'Edit comment' }).click();

		// The textarea's id is derived from the COMMENT id, not the editor id, so
		// it is stable across popovers. Its label is sr-only, which is why
		// `getByLabel('Edit comment')` also matches the pencil button — locate by
		// id when you mean the field.
		const draft = dialog.locator('#c-doc-1-edit');
		await expect(draft).toHaveValue('Overall this reads well. One pass for tone and it ships.');
		await expect(dialog.locator('label[for="c-doc-1-edit"]')).toHaveText('Edit comment');
		await expect(comment.locator('.comment-body')).toHaveCount(0);
		// While a comment is being edited its action row is withdrawn entirely.
		await expect(comment.getByRole('button', { name: 'Edit comment' })).toHaveCount(0);

		// Save refuses a whitespace-only body; Cancel never does.
		await expect(
			comment.locator('.comment-edit-actions').getByRole('button', { name: 'Save' })
		).toBeEnabled();
		await draft.fill('   ');
		await expect(
			comment.locator('.comment-edit-actions').getByRole('button', { name: 'Save' })
		).toBeDisabled();
		await expect(
			comment.locator('.comment-edit-actions').getByRole('button', { name: 'Cancel' })
		).toBeEnabled();
	});

	test('Cmd/Ctrl+Enter saves; oncommentupdate carries no timestamp and the consumer supplies it', async ({
		page
	}) => {
		const dialog = await selectThread(page, docRow(page));
		const comment = dialog.locator('article.comment[data-comment-id="c-doc-1"]');
		await comment.getByRole('button', { name: 'Edit comment' }).click();
		await dialog
			.locator('#c-doc-1-edit')
			.fill('Overall this reads well. Ship it after a tone pass.');
		await dialog.locator('#c-doc-1-edit').press('ControlOrMeta+Enter');

		await expect(page.getByTestId('event-log').locator('li')).toHaveCount(1);
		const [updated] = await payloadsFor(page, 'commentupdate');
		expect(updated).toEqual({
			threadId: 't-doc',
			commentId: 'c-doc-1',
			body: 'Overall this reads well. Ship it after a tone pass.'
		});
		// Explicitly: no `editedAt`. `updateComment` from
		// `@lostgradient/editor/comments` REQUIRES one, so the consumer has to
		// mint it — the component has no opinion about the clock.
		expect('editedAt' in updated).toBe(false);

		await expect(comment.locator('.comment-body')).toHaveText(
			'Overall this reads well. Ship it after a tone pass.'
		);
		// `(edited)` is a consequence of the timestamp the PAGE supplied.
		await expect(comment.locator('.comment-edited')).toHaveText('(edited)');
		const editedTitle = await comment.locator('.comment-edited').getAttribute('title');
		expect(editedTitle).toMatch(/^Edited \d{4}-\d{2}-\d{2}T/);

		// Editing does not consume the actions: the comment stays editable.
		await expect(comment.getByRole('button', { name: 'Edit comment' })).toHaveCount(1);
		await expect(comment.getByRole('button', { name: 'Delete comment' })).toHaveCount(1);
	});

	test('PINNED KNOWN BUG: Escape cancels the edit AND closes the whole thread popover', async ({
		page
	}) => {
		const dialog = await selectThread(page, docRow(page));
		const comment = dialog.locator('article.comment[data-comment-id="c-doc-1"]');
		await comment.getByRole('button', { name: 'Edit comment' }).click();
		await dialog.locator('#c-doc-1-edit').fill('Draft I intend to abandon.');

		await dialog.locator('#c-doc-1-edit').press('Escape');

		// The cancel half is correct: no `oncommentupdate` is emitted, so the draft
		// really was abandoned rather than quietly saved.
		await expect(page.getByTestId('event-log').locator('li')).toHaveCount(0);

		// The wrong half, pinned as-is because it is what the component does
		// today. `comment-list.svelte`'s Escape branch calls `cancelEdit()` and
		// then lets the event bubble — it never calls `preventDefault()` (its
		// Cmd+Enter branch does, which is exactly why SAVING keeps the popover
		// open). `thread-popover.svelte`'s keydown handler guards only on
		// `!event.defaultPrevented`, so the same keystroke closes the dialog. One
		// Escape should back out of the edit; it backs out of the thread.
		await expect(popover(page)).toHaveCount(0);

		// Reopening proves the body really was restored rather than lost with the
		// popover.
		const reopened = await selectThread(page, docRow(page));
		await expect(
			reopened.locator('article.comment[data-comment-id="c-doc-1"] .comment-body')
		).toHaveText('Overall this reads well. One pass for tone and it ships.');
	});
});

test.describe('review comment lifecycle: permissions', () => {
	test.beforeEach(async ({ page }) => {
		await gotoHydrated(page, ROUTE);
		await openSidebar(page);
	});

	test('per-comment actions are author-scoped while `Delete thread` only needs a current user', async ({
		page
	}) => {
		// `t-text` mixes authors: one comment by `steve` (the current user) and
		// one by `maya`.
		const mixed = await selectThread(page, rowQuoted(page, 'Release Plan'));
		const mine = mixed.locator('article.comment[data-comment-id="c-text-steve"]');
		const theirs = mixed.locator('article.comment[data-comment-id="c-text-maya"]');

		await expect(mine.locator('.comment-author-name')).toHaveText('steve');
		await expect(mine.getByRole('button', { name: 'Edit comment' })).toHaveCount(1);
		await expect(mine.getByRole('button', { name: 'Delete comment' })).toHaveCount(1);

		await expect(theirs.locator('.comment-author-name')).toHaveText('maya');
		await expect(theirs.getByRole('button', { name: 'Edit comment' })).toHaveCount(0);
		await expect(theirs.getByRole('button', { name: 'Delete comment' })).toHaveCount(0);

		await mixed.getByRole('button', { name: 'Close', exact: true }).click();
		await expect(popover(page)).toHaveCount(0);

		// The asymmetry: `t-long` is authored ENTIRELY by `maya`, so there is not
		// one per-comment action on it — yet `Delete thread` is enabled, because
		// its only guard is `disabled={!currentUserId}`. Any signed-in reviewer
		// can delete someone else's whole thread but cannot delete a single
		// comment inside it.
		const theirThread = await selectThread(page, rowQuoted(page, 'Reviewers should verify'));
		await expect(theirThread.getByRole('button', { name: 'Edit comment' })).toHaveCount(0);
		await expect(theirThread.getByRole('button', { name: 'Delete comment' })).toHaveCount(0);
		await expect(theirThread.getByRole('button', { name: 'Delete thread' })).toBeEnabled();
	});
});

test.describe('review comment lifecycle: deletion is always soft', () => {
	test.beforeEach(async ({ page }) => {
		await gotoHydrated(page, ROUTE);
		await openSidebar(page);
	});

	test('a UI delete carries `soft: true` and leaves the comment in `threads` with a `deletedAt`', async ({
		page
	}) => {
		const dialog = await selectThread(page, rowQuoted(page, 'Release Plan'));
		await expect(badge(page)).toHaveText('4');

		await dialog
			.locator('article.comment[data-comment-id="c-text-steve"]')
			.getByRole('button', { name: 'Delete comment' })
			.click();

		await expect(page.getByTestId('event-log').locator('li')).toHaveCount(1);
		const [deleted] = await payloadsFor(page, 'commentdelete');
		// Hard delete is reachable only through the imperative
		// `deleteComment(threadId, commentId, false)`; nothing in the rendered UI
		// can produce `soft: false`.
		expect(deleted).toEqual({ threadId: 't-text', commentId: 'c-text-steve', soft: true });

		// The comment stops rendering and stops counting…
		await expect(dialog.locator('article.comment[data-comment-id="c-text-steve"]')).toHaveCount(0);
		await expect(badge(page)).toHaveText('3');
		await expect(page.getByTestId('visible-comment-count')).toHaveText('visible comments: 3');
		// …but it is still in `threads`, carrying a timestamp. Soft delete is an
		// audit trail, not an erasure — `stored comments` never drops.
		await expect(page.getByTestId('stored-comment-count')).toHaveText('stored comments: 6');
		await expect(page.getByTestId('soft-deleted-ids')).toContainText('c-text-steve');
		// The thread itself survives: it still has a visible comment.
		await expect(page.getByTestId('thread-count')).toHaveText('threads: 4');
	});

	test('the same reducer call WITHOUT `deletedAt` is a silent no-op', async ({ page }) => {
		// The likeliest consumer mistake in the whole API. `deleteComment(threads,
		// t, c, { soft: true })` — no `deletedAt` — does not throw, does not warn,
		// and does not partially apply. It returns `{ changed: false }` and the
		// identical array, and the only way to notice is to read `changed`.
		await expect(page.getByTestId('visible-comment-count')).toHaveText('visible comments: 4');

		await page.getByTestId('delete-without-deletedat').click();

		await expect(page.getByTestId('last-changed')).toHaveText('last reducer changed: false');
		await expect(page.getByTestId('visible-comment-count')).toHaveText('visible comments: 4');
		await expect(page.getByTestId('stored-comment-count')).toHaveText('stored comments: 6');
		await expect(page.getByTestId('soft-deleted-ids')).not.toContainText('c-doc-1');
		await expect(badge(page)).toHaveText('4');
		// And nothing was reported: this is a page-side reducer call, so the
		// component never even hears about it.
		await expect(page.getByTestId('event-log').locator('li')).toHaveCount(0);
		await expect(docRow(page).locator('p.thread-preview')).toHaveText(
			'Overall this reads well. One pass for tone and it ships.'
		);
	});
});

test.describe('review comment lifecycle: ghost threads', () => {
	test.beforeEach(async ({ page }) => {
		await gotoHydrated(page, ROUTE);
	});

	test('a seeded thread whose only comment is soft-deleted stays anchored and opens an empty popover', async ({
		page
	}) => {
		// `t-empty` is invisible to both counters but fully alive in the document.
		await expect(page.getByTestId('thread-count')).toHaveText('threads: 4');
		await expect(page.getByTestId('visible-thread-count')).toHaveText('visible threads: 3');
		await expect(badge(page)).toHaveText('4');

		// Exactly one decoration span, covering exactly the quoted range. Before
		// the fix in cinder PR #1266 a seeded thread decorated the entire
		// document, and this locator resolved to several spans. (The decoration
		// contract itself belongs to `review-anchoring`; it matters here only
		// because clicking the decoration is the ONLY way to reach a ghost.)
		const ghostAnchor = page.locator('span.comment-anchor[data-thread-id="t-empty"]');
		await expect(ghostAnchor).toHaveCount(1);
		await expect(ghostAnchor).toHaveText('Timeline risk');

		await ghostAnchor.click();
		const dialog = popover(page);
		await expect(dialog).toHaveAttribute('data-position-ready', 'true');

		await expect(dialog.locator('article.comment')).toHaveCount(0);
		await expect(dialog.locator('.comment-list-empty')).toHaveText('No comments yet.');
		// Still deletable, and still able to take a new reply — a ghost is a
		// thread with nothing to show, not a tombstone.
		await expect(dialog.getByRole('button', { name: 'Delete thread' })).toBeEnabled();
		await expect(dialog.locator('#lifecycle-editor-thread-popover-composer')).toBeVisible();
	});

	test('soft-deleting the last visible comment turns a live thread into a ghost in place', async ({
		page
	}) => {
		await openSidebar(page);
		const dialog = await selectThread(page, docRow(page));
		await dialog
			.locator('article.comment[data-comment-id="c-doc-1"]')
			.getByRole('button', { name: 'Delete comment' })
			.click();

		// The row leaves the sidebar and the count drops…
		await expect(docRow(page)).toHaveCount(0);
		await expect(sidebar(page).locator('.thread-count')).toHaveText('2');
		// …while `threads` keeps all four, and the popover stays open on a thread
		// that no longer has anything to list.
		await expect(page.getByTestId('thread-count')).toHaveText('threads: 4');
		await expect(dialog.locator('.comment-list-empty')).toHaveText('No comments yet.');
	});
});

test.describe('review comment lifecycle: clear all', () => {
	test('the confirmation counts VISIBLE threads but `Delete All` deletes every thread', async ({
		page
	}) => {
		await gotoHydrated(page, ROUTE);
		await openSidebar(page);

		await sidebar(page).getByRole('button', { name: 'Comment actions' }).click();
		// Scoped to the sidebar's own menu: the toolbar's export dropdown also
		// renders `[role="menuitem"]` children (Content / Summary / Git Diff /
		// Comments / JSON), and one of them is literally named `Comments`.
		const menu = page.locator('#lifecycle-editor-sidebar-actions-menu');
		await menu.getByRole('menuitem', { name: 'Clear all comments' }).click();

		const confirm = sidebar(page).locator('.confirm-clear');
		await expect(confirm).toHaveAttribute('role', 'alertdialog');
		await expect(confirm).toHaveAttribute(
			'aria-labelledby',
			'lifecycle-editor-sidebar-confirm-title'
		);
		// The banner interpolates the VISIBLE thread count — it says three.
		await expect(confirm.locator('.confirm-message')).toHaveText('Delete all 3 comment threads?');
		await expect(confirm.locator('.confirm-message')).toHaveAttribute(
			'id',
			'lifecycle-editor-sidebar-confirm-title'
		);

		await confirm.getByRole('button', { name: 'Delete All' }).click();

		// …and then emits FOUR. `clearAllThreads` iterates `threads`, not the
		// filtered list the banner was counting, so the invisible ghost is deleted
		// by a dialog that never mentioned it. A consumer sizing an undo buffer or
		// a confirmation from that number is off by every ghost in the document.
		await expect(page.getByTestId('event-log').locator('li')).toHaveCount(4);
		const removed = await payloadsFor(page, 'threaddelete');
		expect(removed).toEqual([
			{ threadId: 't-doc' },
			{ threadId: 't-text' },
			{ threadId: 't-long' },
			{ threadId: 't-empty' }
		]);

		await expect(page.getByTestId('thread-count')).toHaveText('threads: 0');
		await expect(page.locator('span.comment-anchor')).toHaveCount(0);
		await expect(sidebar(page).locator('.empty-message')).toHaveText('No comments yet');
		// With nothing left to act on, the actions trigger withdraws itself.
		await expect(sidebar(page).getByRole('button', { name: 'Comment actions' })).toHaveCount(0);
	});
});

test.describe('review comment lifecycle: counts and announcements', () => {
	test.beforeEach(async ({ page }) => {
		await gotoHydrated(page, ROUTE);
	});

	test('the toolbar badge counts COMMENTS while the sidebar count counts THREADS', async ({
		page
	}) => {
		// Two numbers, both sitting next to the word "Comments", both correct,
		// and never equal for this fixture: four visible comments across three
		// visible threads.
		await expect(badge(page)).toHaveText('4');
		await openSidebar(page);
		await expect(sidebar(page).locator('.thread-count')).toHaveText('3');

		// Only one of them reaches assistive tech as a number: the badge is
		// `aria-hidden`, and the count it carries is restated inside the toggle's
		// accessible name.
		await expect(badge(page)).toHaveAttribute('aria-hidden', 'true');
		await expect(
			page.getByRole('button', { name: 'Close comments sidebar (4 comments)' })
		).toHaveCount(1);

		// The sidebar's count is a bare `<span>` — no role, no label, no name.
		const countAttributes = await sidebar(page)
			.locator('.thread-count')
			.evaluate((element) => element.getAttributeNames());
		expect(countAttributes.filter((name) => name !== 'class')).toEqual([]);
	});

	test('the live announcer is empty on first paint and then mirrors the toggle, singular included', async ({
		page
	}) => {
		// `[role="status"]` alone is ambiguous — the editor also mounts a generic
		// LiveRegion with the same role. Both are `cinder-sr-only` as of cinder PR
		// #1266, so neither is reachable by visible text; scope by class.
		await expect(announcer(page)).toHaveClass(/cinder-sr-only/);
		await expect(announcer(page)).toHaveAttribute('aria-live', 'polite');
		await expect(announcer(page)).toHaveAttribute('aria-atomic', 'true');
		// Deliberate do-not-announce-on-mount guard: the count is 4, and the
		// region says nothing.
		await expect(announcer(page)).toBeEmpty();

		await openSidebar(page);

		// Walk the count down to one. `t-long` is authored by `maya`, so the only
		// way to remove its comment is to delete the whole thread; the remaining
		// two deletions are per-comment on `steve`'s own.
		const theirThread = await selectThread(page, rowQuoted(page, 'Reviewers should verify'));
		await theirThread.getByRole('button', { name: 'Delete thread' }).click();
		// Deleting a thread closes its popover; wait for that before selecting the
		// next one, so `selectThread` cannot latch onto the outgoing dialog.
		await expect(popover(page)).toHaveCount(0);
		await expect(announcer(page)).toHaveText('3 comments');

		const mixed = await selectThread(page, rowQuoted(page, 'Release Plan'));
		await mixed
			.locator('article.comment[data-comment-id="c-text-steve"]')
			.getByRole('button', { name: 'Delete comment' })
			.click();
		await expect(announcer(page)).toHaveText('2 comments');
		await mixed.getByRole('button', { name: 'Close', exact: true }).click();
		await expect(popover(page)).toHaveCount(0);

		const documentThread = await selectThread(page, docRow(page));
		await documentThread
			.locator('article.comment[data-comment-id="c-doc-1"]')
			.getByRole('button', { name: 'Delete comment' })
			.click();

		// Singular, and the toggle's accessible name uses the identical rule.
		await expect(announcer(page)).toHaveText('1 comment');
		await expect(
			page.getByRole('button', { name: 'Close comments sidebar (1 comment)' })
		).toHaveCount(1);
		await expect(badge(page)).toHaveText('1');
	});
});
