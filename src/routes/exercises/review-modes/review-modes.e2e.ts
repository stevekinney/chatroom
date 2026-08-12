import { expect, test } from '@playwright/test';
import { gotoHydrated } from '../hydration';
import type { Locator, Page } from '@playwright/test';

// ReviewEditor's prop matrix: `mode`, `currentUserId`, `snapshotMode`,
// `placeholder`, and `class`. Every claim here is a DIFFERENCE between two
// instances that share a document, a seeded thread, an author, and everything
// else — so each assertion carries its own control, and an affordance that is
// missing for the wrong reason shows up as a failing control rather than as a
// passing test.
//
// Boundaries with the sibling routes: `review-views` owns the view tablist and
// the full Revert All gate (readonly appears here only as the third of its
// three conditions); `review-ssr-and-a11y` owns SSR, hydration, and live-region
// geometry; `review-comment-creation` owns the drag-selection path and the
// page-owned reducer that applies the notification-only events. This route
// never applies them — counting them at zero is the whole point.

/** Each instance is wrapped in `data-testid="modes-<name>-frame"` on the page. */
function frame(page: Page, name: string): Locator {
	return page.getByTestId(`${name}-frame`);
}

/**
 * The component's own container: `data-testid="review-editor"`, and no id.
 *
 * The `id` prop lands on the inner markdown-editor host (`#<id>`), NOT on the
 * container — so `#<id>` vanishes whenever an instance leaves the editor view,
 * because the diff and summary views unmount that host. Everything
 * container-scoped therefore goes through the frame, which never moves.
 */
function surface(scope: Locator): Locator {
	return scope.getByTestId('review-editor');
}

/** All seven instances, in page order. */
const INSTANCES = [
	'modes-edit',
	'modes-readonly',
	'modes-nouser',
	'modes-emptyuser',
	'modes-snapshot',
	'modes-plain',
	'modes-exotic'
] as const;

/**
 * `data-ready` is `editorViewReady && !pendingState`. It is the right signal
 * for the FIRST interaction and useless afterwards — it never resets, so it
 * stays `"true"` while an editor is unmounted in another view.
 */
async function openReviewModes(page: Page, names: readonly string[]): Promise<void> {
	await gotoHydrated(page, '/exercises/review-modes');
	for (const name of names) {
		await expect(surface(frame(page, name))).toHaveAttribute('data-ready', 'true');
	}
}

/**
 * Select `needle` inside an instance's ProseMirror with a real DOM Range.
 *
 * A mouse drag is the user-facing gesture, but it is unusable here: these
 * documents carry an anchor decoration whose pointerup handler steals the drag
 * and opens the thread popover instead. A programmatic Range needs no
 * coordinates and produces the same `selectionchange` the component listens
 * for — but only if the editor is focused first, because ProseMirror's DOM
 * observer ignores selection changes on an editable view it does not hold
 * focus in.
 *
 * The scroll dance in front of that is load-bearing, not hygiene. Focusing an
 * offscreen element makes the browser scroll it into view, and this page
 * inherits `scroll-behavior: smooth`, so that scroll ANIMATES for hundreds of
 * milliseconds after the call returns. SelectionPopover dismisses itself on
 * scroll (movement dismissal — "the user moved on"), and the component only
 * mounts it 20ms after the selection settles, so the popover would mount into
 * a still-running scroll and be torn down a frame or two later. Measured: the
 * popover appeared at 31ms and was removed at 35ms by a scroll event, with the
 * selection still standing. Nothing about that is specific to the popover's
 * correctness — it is an artifact of moving focus across a seven-instance page,
 * which a real user selecting text never does. So scroll the target into view
 * FIRST, wait for the scroll to stop firing, and then take focus with
 * `preventScroll` so the gesture itself moves nothing.
 *
 * Returns what the browser actually selected, so callers assert on a real
 * reading instead of on the string they passed in. That matters most for the
 * absence assertions: "no popover appeared" proves nothing unless the selection
 * it should have reacted to demonstrably existed.
 */
async function selectText(page: Page, editorId: string, needle: string): Promise<string> {
	return page.evaluate(
		async ({ editorId, needle }) => {
			const editor = document.getElementById(editorId)?.querySelector('.ProseMirror');
			if (!editor) throw new Error(`no ProseMirror inside #${editorId}`);
			const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
			let node: Node | null;
			while ((node = walker.nextNode())) {
				const offset = (node as Text).data.indexOf(needle);
				if (offset === -1) continue;
				const range = document.createRange();
				range.setStart(node, offset);
				range.setEnd(node, offset + needle.length);

				// Centre the target, then wait until the page has been quiet for
				// 100ms — `instant` overrides the inherited smooth behavior, but the
				// scroll event still lands a frame later, and a scroll landing after
				// the popover mounts is exactly what dismisses it.
				let lastScrollAt = performance.now();
				const noteScroll = () => (lastScrollAt = performance.now());
				document.addEventListener('scroll', noteScroll, true);
				window.scrollBy({
					top: range.getBoundingClientRect().top - window.innerHeight / 2,
					behavior: 'instant'
				});
				const deadline = performance.now() + 2000;
				while (performance.now() - lastScrollAt < 100 && performance.now() < deadline) {
					await new Promise((resolve) => setTimeout(resolve, 25));
				}
				document.removeEventListener('scroll', noteScroll, true);

				(editor as HTMLElement).focus({ preventScroll: true });
				const selection = document.getSelection();
				if (!selection) throw new Error('no document selection');
				selection.removeAllRanges();
				selection.addRange(range);
				return selection.toString();
			}
			throw new Error(`"${needle}" not found in #${editorId}`);
		},
		{ editorId, needle }
	);
}

/** What the browser has selected right now, across the whole document. */
function currentSelection(page: Page): Promise<string> {
	return page.evaluate(() => document.getSelection()?.toString() ?? '');
}

/** Drop the browser selection so the next instance starts from a clean slate. */
async function clearSelection(page: Page): Promise<void> {
	await page.evaluate(() => document.getSelection()?.removeAllRanges());
}

/**
 * The component debounces its `selectionchange` handler by 20ms before it will
 * even consider showing the selection popover, so an absence assertion that
 * fires inside that window proves nothing. Wait an order of magnitude longer,
 * then confirm the selection is still standing — and, in the same test, show
 * the identical gesture producing a popover in an ungated instance. Between
 * them, the wait is demonstrably ample rather than merely long.
 */
const SELECTION_SETTLE_MS = 400;

/**
 * Record every live-region announcement inside an instance.
 *
 * LiveRegion clears its message one second after setting it, so a polled read
 * can legitimately arrive after the text is gone. Observing from before the
 * interaction turns that race into an append-only log. The regions are
 * `cinder-sr-only`, which also makes this the only honest way to read them —
 * a visible-text locator finds nothing even when the announcement fired.
 */
async function recordAnnouncements(scope: Locator): Promise<void> {
	await scope.evaluate((element) => {
		const win = window as unknown as { __announcements?: string[] };
		const log: string[] = [];
		win.__announcements = log;
		new MutationObserver(() => {
			for (const region of element.querySelectorAll('[role="status"],[role="alert"]')) {
				const text = region.textContent?.trim();
				if (!text) continue;
				if (log[log.length - 1] !== text) log.push(text);
			}
		}).observe(element, { subtree: true, childList: true, characterData: true });
	});
}

function announcements(page: Page): Promise<string[]> {
	return page.evaluate(
		() => (window as unknown as { __announcements?: string[] }).__announcements ?? []
	);
}

/** The paragraph of body copy every instance shares, inside one instance. */
function bodyParagraph(page: Page, editorId: string): Locator {
	return page.locator(`#${editorId} .ProseMirror p`, { hasText: 'The first release includes' });
}

/**
 * Click an instance's anchor decoration and wait for its thread popover.
 *
 * The popover mounts before Floating UI has placed it, and marks that gap with
 * `inert` plus `data-position-ready`. Waiting for the ready flag rather than
 * for mere presence keeps every subsequent click aimed at a positioned,
 * non-inert dialog.
 */
async function openThreadPopover(page: Page, name: string): Promise<void> {
	await frame(page, name).locator('span.comment-anchor[data-thread-id]').click();
	const popover = page.locator(`#${name}-thread-popover`);
	await expect(popover).toHaveCount(1);
	await expect(popover).toHaveAttribute('data-position-ready', 'true');
}

test.describe('review-modes: mode is reflected everywhere and enforced in one place', () => {
	let page: Page;

	test.beforeAll(async ({ browser }) => {
		page = await browser.newPage();
		await openReviewModes(page, INSTANCES);
	});

	test.afterAll(async () => {
		await page.close();
	});

	test('`data-mode` echoes the passed string verbatim, including a value outside the union', async () => {
		// `data-mode={mode}` is an unfiltered reflection of the prop. The exotic
		// instance passes `'suggest'`, which the ReviewMode union does not
		// contain and the component never validates — so it reaches the
		// attribute unchanged.
		const expected: Record<string, string> = {
			'modes-edit': 'edit',
			'modes-readonly': 'readonly',
			'modes-nouser': 'edit',
			'modes-emptyuser': 'edit',
			'modes-snapshot': 'edit',
			'modes-plain': 'edit',
			'modes-exotic': 'suggest'
		};
		for (const name of INSTANCES) {
			await expect(surface(frame(page, name))).toHaveAttribute('data-mode', expected[name]);
		}
	});

	test('only the exact string `readonly` reaches the DOM as a disabled editor', async () => {
		// Enforcement reads `mode === 'readonly'`, never `data-mode`. The exotic
		// instance shows the two are independent: it reflects a non-union mode
		// and is still fully editable.
		await expect(page.locator('#modes-readonly .ProseMirror')).toHaveAttribute(
			'contenteditable',
			'false'
		);
		await expect(page.locator('#modes-readonly')).toHaveAttribute('data-readonly', 'true');

		for (const editorId of ['modes-edit', 'modes-exotic']) {
			await expect(page.locator(`#${editorId} .ProseMirror`)).toHaveAttribute(
				'contenteditable',
				'true'
			);
			// `data-readonly={readonly || undefined}` — the attribute is ABSENT
			// when editable, never `"false"`.
			await expect(page.locator(`#${editorId}`)).not.toHaveAttribute('data-readonly');
		}
	});

	test('readonly withholds the formatting toolbar while the unified control bar survives', async () => {
		const editSurface = surface(frame(page, 'modes-edit'));
		const readonlySurface = surface(frame(page, 'modes-readonly'));

		// One bar, in both modes, named "Review editor controls". It is
		// `role="group"` rather than `role="toolbar"`, because it contains a
		// `tablist` and hosts the editor's own `toolbar` — neither of which is
		// a valid child of a `toolbar`.
		for (const scope of [editSurface, readonlySurface]) {
			await expect(scope.getByRole('group', { name: 'Review editor controls' })).toHaveCount(1);
		}

		const formatting = editSurface.getByRole('toolbar', { name: 'Formatting toolbar' });
		await expect(formatting).toHaveCount(1);
		await expect(formatting).toHaveAttribute('id', 'modes-edit-toolbar');
		// The formatting controls live INSIDE the unified bar, in
		// `.controls-formatting`, rather than in a second stacked row: the
		// editor view has no `.editor-toolbar-wrapper` at all.
		await expect(editSurface.locator('#modes-edit-controls .controls-formatting')).toHaveCount(1);
		await expect(editSurface.locator('.editor-toolbar-wrapper')).toHaveCount(0);

		// `formatting={activeView === 'editor' && !isReadonly ? … : undefined}`:
		// readonly removes the snippet outright, it does not merely disable it.
		await expect(readonlySurface.getByRole('toolbar', { name: 'Formatting toolbar' })).toHaveCount(
			0
		);
		await expect(readonlySurface.locator('.controls-formatting')).toHaveCount(0);
	});

	test('readonly makes the selection popover structurally impossible', async () => {
		// The popover is portaled to `document.body`, so it is addressed by id
		// and never as a descendant of a container.
		const readonlyPopover = page.locator('#modes-readonly-selection-popover');
		const exoticPopover = page.locator('#modes-exotic-selection-popover');
		const editPopover = page.locator('#modes-edit-selection-popover');

		// Readonly text is still selectable — the block lives in the component's
		// handler (`if (mode !== 'edit') { … return; }`), not in the browser.
		expect(await selectText(page, 'modes-readonly', 'dashboard')).toBe('dashboard');
		await page.waitForTimeout(SELECTION_SETTLE_MS);
		expect(await currentSelection(page)).toBe('dashboard');
		await expect(readonlyPopover).toHaveCount(0);

		// `showSelectionPopover` requires `mode === 'edit'` exactly, so the
		// out-of-union mode is gated out from the other side: an editable
		// document with no way to comment on it.
		await clearSelection(page);
		expect(await selectText(page, 'modes-exotic', 'dashboard')).toBe('dashboard');
		await page.waitForTimeout(SELECTION_SETTLE_MS);
		expect(await currentSelection(page)).toBe('dashboard');
		await expect(exoticPopover).toHaveCount(0);

		// The control that makes both absences mean something: the identical
		// gesture in the edit instance produces the popover, well inside the
		// settle window used above.
		await clearSelection(page);
		expect(await selectText(page, 'modes-edit', 'dashboard')).toBe('dashboard');
		await expect(editPopover).toHaveCount(1);
		await expect(editPopover).toHaveAttribute('role', 'toolbar');
		await expect(editPopover).toHaveAttribute('aria-label', 'Selection actions');
		await expect(editPopover.getByLabel('Add comment')).toHaveCount(1);

		// Collapsing the selection tears it back down, which also leaves the
		// page clean for the next test.
		await clearSelection(page);
		await expect(editPopover).toHaveCount(0);
	});

	test('readonly strips the sidebar of every mutating affordance but keeps the thread list', async () => {
		for (const name of ['modes-edit', 'modes-readonly']) {
			// Singular/plural is computed from the visible comment count, so the
			// accessible name is "(1 comment)" and never "(1 comments)".
			await surface(frame(page, name))
				.getByRole('button', { name: 'Open comments sidebar (1 comment)' })
				.click();
			const sidebar = page.locator(`#${name}-sidebar`);
			await expect(sidebar).toHaveCount(1);
			await expect(sidebar).toHaveAttribute('aria-label', 'Comment threads');
			await expect(sidebar.locator('.thread-item')).toHaveCount(1);
		}

		const editSidebar = page.locator('#modes-edit-sidebar');
		await expect(editSidebar.getByRole('button', { name: 'Add document comment' })).toHaveCount(1);
		await expect(editSidebar.getByRole('button', { name: 'Comment actions' })).toHaveCount(1);

		const readonlySidebar = page.locator('#modes-readonly-sidebar');
		await expect(readonlySidebar.getByRole('button', { name: 'Add document comment' })).toHaveCount(
			0
		);
		await expect(readonlySidebar.getByRole('button', { name: 'Comment actions' })).toHaveCount(0);

		// Close both: an open sidebar narrows the editor column, and the later
		// click-and-type test picks its click target by layout.
		for (const name of ['modes-edit', 'modes-readonly']) {
			await surface(frame(page, name))
				.getByRole('button', { name: 'Close comments sidebar (1 comment)' })
				.click();
			await expect(page.locator(`#${name}-sidebar`)).toHaveCount(0);
		}
	});

	test('readonly strips the thread popover down to Close, with no reply composer', async () => {
		const editPopover = page.locator('#modes-edit-thread-popover');
		await openThreadPopover(page, 'modes-edit');
		await expect(editPopover).toHaveAttribute('role', 'dialog');
		await expect(editPopover).toHaveAttribute('aria-modal', 'true');
		await expect(editPopover.getByRole('button', { name: 'Delete thread' })).toBeEnabled();
		await expect(editPopover.getByRole('button', { name: 'Edit comment' })).toHaveCount(1);
		await expect(editPopover.getByRole('button', { name: 'Delete comment' })).toHaveCount(1);
		// The reply composer's textarea is `{popoverId}-composer`.
		await expect(page.locator('#modes-edit-thread-popover-composer')).toHaveCount(1);
		await editPopover.getByRole('button', { name: 'Close' }).click();
		await expect(editPopover).toHaveCount(0);

		const readonlyPopover = page.locator('#modes-readonly-thread-popover');
		await openThreadPopover(page, 'modes-readonly');
		// The seeded comment's author is `steve`, which is also this instance's
		// `currentUserId` — so these four are withheld by readonly and by
		// nothing else. Same seed, same identity, different mode.
		await expect(readonlyPopover.getByRole('button', { name: 'Delete thread' })).toHaveCount(0);
		await expect(readonlyPopover.getByRole('button', { name: 'Edit comment' })).toHaveCount(0);
		await expect(readonlyPopover.getByRole('button', { name: 'Delete comment' })).toHaveCount(0);
		await expect(page.locator('#modes-readonly-thread-popover-composer')).toHaveCount(0);
		// Reading is untouched: the quote and the comment body still render.
		await expect(readonlyPopover.getByText('Title reads well — keep it.')).toBeVisible();
		await readonlyPopover.getByRole('button', { name: 'Close' }).click();
		await expect(readonlyPopover).toHaveCount(0);
	});

	test('typing into a readonly editor leaves `value` byte-identical; the same gesture edits an edit instance', async () => {
		const readonlyValue = page.getByTestId('modes-readonly-value-json');
		const readonlyBefore = ((await readonlyValue.textContent()) ?? '').trim();
		expect(readonlyBefore).toContain('# Release Plan');

		// Clicking a `contenteditable="false"` ProseMirror does not focus it;
		// focus lands on the markdown-editor host, which carries `tabindex="0"`
		// for exactly this reason. Asserting that first is what makes the
		// no-op assertion below mean something: the keystrokes were delivered
		// INSIDE the editor, they just had nowhere to go.
		await page.locator('#modes-readonly .ProseMirror').click();
		await expect(page.locator('#modes-readonly')).toBeFocused();
		await page.keyboard.type('INJECTED');

		// The control does double duty. It shows the same gesture working under
		// `mode="edit"` — and, because it is asserted first, it proves a full
		// keystroke → onchange → DOM cycle has elapsed since the readonly
		// keystrokes above. That is what licenses the negative assertions after
		// it without an arbitrary sleep.
		const editValue = page.getByTestId('modes-edit-value-json');
		const editBefore = ((await editValue.textContent()) ?? '').trim();
		await bodyParagraph(page, 'modes-edit').click();
		await expect(page.locator('#modes-edit .ProseMirror')).toBeFocused();
		await page.keyboard.type('INJECTED');

		await expect(page.locator('#modes-edit .ProseMirror')).toContainText('INJECTED');
		await expect
			.poll(async () => ((await editValue.textContent()) ?? '').trim())
			.not.toBe(editBefore);
		// `onchange` carries the whole new document rather than a delta, which is
		// why the log records a length. How many events a typing burst coalesces
		// into is the editor's business and not pinned here — only that at least
		// one arrived carrying a document length.
		await expect(page.getByTestId('modes-edit-event-log').getByRole('listitem').last()).toHaveText(
			/^change:\d+$/
		);

		await expect(page.locator('#modes-readonly .ProseMirror')).not.toContainText('INJECTED');
		expect(((await readonlyValue.textContent()) ?? '').trim()).toBe(readonlyBefore);
		await expect(page.getByTestId('modes-readonly-event-count')).toHaveText('events: 0');
	});

	test('readonly keeps view switching, the sidebar, and every export action', async () => {
		const scope = surface(frame(page, 'modes-readonly'));

		await frame(page, 'modes-readonly').getByRole('tab', { name: 'Diff' }).click();
		await expect(scope).toHaveAttribute('data-view', 'diff');
		// Revert All is gated on `activeView === 'diff' && hasContentChanges &&
		// !readonly`. This instance satisfies the first two, so readonly is the
		// only thing withholding it; `review-views` owns the other two thirds.
		await expect(scope.getByLabel('Revert all changes')).toHaveCount(0);

		await frame(page, 'modes-readonly').getByRole('tab', { name: 'Summary' }).click();
		await expect(scope).toHaveAttribute('data-view', 'summary');
		await expect(page.locator('#modes-readonly-summary-panel')).toHaveCount(1);

		await frame(page, 'modes-readonly').getByRole('tab', { name: 'Editor' }).click();
		await expect(scope).toHaveAttribute('data-view', 'editor');
		// The editor comes back readonly — a view round trip does not reset
		// `mode`. (It does lose the anchor decoration, which is a separate
		// upstream problem and not this route's to pin, so nothing here depends
		// on the decoration surviving the trip.)
		await expect(page.locator('#modes-readonly .ProseMirror')).toHaveAttribute(
			'contenteditable',
			'false'
		);

		// Export is a read-only capability, so readonly withholds none of it:
		// the trigger opens `{id}-export-menu` with all five formats.
		await scope.getByRole('button', { name: 'Copy to clipboard' }).click();
		const menu = page.locator('#modes-readonly-export-menu');
		await expect(menu).toHaveAttribute('role', 'menu');
		await expect(menu.getByRole('menuitem')).toHaveText([
			'Content',
			'Summary (for LLM)',
			'Git Diff',
			'Comments',
			'JSON'
		]);
	});
});

test.describe('review-modes: currentUserId has three states, not two', () => {
	let page: Page;

	test.beforeAll(async ({ browser }) => {
		page = await browser.newPage();
		await openReviewModes(page, ['modes-edit', 'modes-nouser', 'modes-emptyuser']);
	});

	test.afterAll(async () => {
		await page.close();
	});

	test('an omitted currentUserId blocks the selection popover; an empty-string one does not', async () => {
		// `showSelectionPopover` tests `currentUserId !== undefined`. That single
		// check is the entire difference between these two instances.
		expect(await selectText(page, 'modes-nouser', 'dashboard')).toBe('dashboard');
		await page.waitForTimeout(SELECTION_SETTLE_MS);
		expect(await currentSelection(page)).toBe('dashboard');
		await expect(page.locator('#modes-nouser-selection-popover')).toHaveCount(0);

		await clearSelection(page);
		expect(await selectText(page, 'modes-emptyuser', 'dashboard')).toBe('dashboard');
		await expect(page.locator('#modes-emptyuser-selection-popover')).toHaveCount(1);

		await clearSelection(page);
		await expect(page.locator('#modes-emptyuser-selection-popover')).toHaveCount(0);
	});

	test('an omitted currentUserId renders `Delete thread` disabled and drops the reply composer', async () => {
		const popover = page.locator('#modes-nouser-thread-popover');
		await openThreadPopover(page, 'modes-nouser');

		// Three different gates, three different outcomes, in one popover.
		// `Delete thread` renders because the instance is not readonly, and is
		// DISABLED because `disabled={!currentUserId}`…
		await expect(popover.getByRole('button', { name: 'Delete thread' })).toBeDisabled();
		// …the reply composer is gated on `!isReadonly && currentUserId`, so it
		// is not rendered at all…
		await expect(page.locator('#modes-nouser-thread-popover-composer')).toHaveCount(0);
		// …and Edit/Delete comment are absent for a reason that is neither:
		// authorship. The seeded comment's `authorId` is `steve` while
		// `currentUserId` is undefined, so `comment.authorId === currentUserId`
		// fails. From outside this looks identical to the readonly case, which
		// is why the readonly test uses a matching author to tell them apart.
		await expect(popover.getByRole('button', { name: 'Edit comment' })).toHaveCount(0);
		await expect(popover.getByRole('button', { name: 'Delete comment' })).toHaveCount(0);

		await popover.getByRole('button', { name: 'Close' }).click();
		await expect(popover).toHaveCount(0);
	});

	test('the sidebar still offers `Add document comment` without a user — it accepts a body, closes, and fires nothing', async () => {
		// The sidebar button is gated on `!readonly` alone; the identity check
		// happens later, inside `handleAddDocumentComment`, which `devWarn`s and
		// returns. The affordance is therefore fully interactive and completely
		// inert — indistinguishable from a working one without the event log.
		await surface(frame(page, 'modes-nouser'))
			.getByRole('button', { name: 'Open comments sidebar (1 comment)' })
			.click();
		await page
			.locator('#modes-nouser-sidebar')
			.getByRole('button', { name: 'Add document comment' })
			.click();

		const composer = page.locator('#modes-nouser-sidebar-document-composer');
		await expect(composer).toHaveAttribute(
			'placeholder',
			'Add a comment about the entire document...'
		);
		await composer.fill('Anonymous document note');
		// The composer submits on Cmd/Ctrl+Enter; its inline submit button only
		// becomes clickable on `:focus-within`, so the keyboard path is both the
		// documented one and the stable one.
		await page.keyboard.press('Control+Enter');

		// It closes on submit exactly as a successful one would.
		await expect(composer).toHaveCount(0);
		await expect(page.getByTestId('modes-nouser-threadcreate-count')).toHaveText('threadcreate: 0');
		await expect(page.getByTestId('modes-nouser-event-count')).toHaveText('events: 0');
		await expect(page.locator('#modes-nouser-sidebar .thread-item')).toHaveCount(1);

		// Control: the identical flow with `currentUserId="steve"` fires once,
		// carrying the body and the author on the event.
		await surface(frame(page, 'modes-edit'))
			.getByRole('button', { name: 'Open comments sidebar (1 comment)' })
			.click();
		await page
			.locator('#modes-edit-sidebar')
			.getByRole('button', { name: 'Add document comment' })
			.click();
		await page.locator('#modes-edit-sidebar-document-composer').fill('Real document note');
		await page.keyboard.press('Control+Enter');

		await expect(page.getByTestId('modes-edit-threadcreate-count')).toHaveText('threadcreate: 1');
		await expect(page.getByTestId('modes-edit-event-log').getByRole('listitem')).toHaveText([
			'threadcreate:steve:Real document note'
		]);
		// The thread list is still 1: `onthreadcreate` is notification-only and
		// this page deliberately never applies it.
		await expect(page.locator('#modes-edit-sidebar .thread-item')).toHaveCount(1);
	});

	test('currentUserId="" offers the whole comment-creation flow and then refuses the submit, announcing it assertively', async () => {
		const scope = surface(frame(page, 'modes-emptyuser'));
		await recordAnnouncements(scope);

		const popover = page.locator('#modes-emptyuser-selection-popover');
		expect(await selectText(page, 'modes-emptyuser', 'dashboard')).toBe('dashboard');
		await expect(popover).toHaveCount(1);

		await popover.getByLabel('Add comment').click();
		await popover.getByLabel('Comment text').fill('Should not be accepted');
		await popover.getByLabel('Submit comment').click();

		// `handleSelectionComment` opens with `if (!currentUserId)` — a
		// TRUTHINESS test, where the visibility gate was `!== undefined`. The
		// empty string passes one and fails the other, so the flow is offered in
		// full and dropped at the last step.
		await expect(popover).toHaveCount(0);
		await expect(page.getByTestId('modes-emptyuser-threadcreate-count')).toHaveText(
			'threadcreate: 0'
		);
		await expect(page.getByTestId('modes-emptyuser-event-count')).toHaveText('events: 0');

		// The failure is announced on the assertive region — `role="alert"`,
		// `aria-live="assertive"` — and that region is `cinder-sr-only`, so the
		// text is NOT visible on the page. `review-ssr-and-a11y` owns the
		// geometry; here only the message and its priority matter.
		const alert = scope.locator('[role="alert"][aria-live="assertive"]');
		await expect(alert).toHaveClass(/cinder-sr-only/);
		await expect
			.poll(() => announcements(page))
			.toContain('Could not add comment. Please try selecting text again.');
	});
});

test.describe('review-modes: snapshotMode, placeholder, and class', () => {
	let page: Page;

	test.beforeAll(async ({ browser }) => {
		page = await browser.newPage();
		await openReviewModes(page, ['modes-edit', 'modes-snapshot', 'modes-plain']);
	});

	test.afterAll(async () => {
		await page.close();
	});

	test('snapshotMode stamps `data-snapshot-mode` on the container AND the inner editor wrapper', async () => {
		await expect(surface(frame(page, 'modes-snapshot'))).toHaveAttribute(
			'data-snapshot-mode',
			'true'
		);
		// ReviewEditor forwards the prop to its MarkdownEditor, which stamps its
		// own wrapper: two elements, one prop.
		await expect(frame(page, 'modes-snapshot').locator('.markdown-editor-wrapper')).toHaveAttribute(
			'data-snapshot-mode',
			'true'
		);

		// `data-snapshot-mode={snapshotMode || undefined}`: with the prop false
		// the attribute is ABSENT rather than `"false"`, so an attribute
		// selector matches nothing instead of matching a falsy value.
		await expect(surface(frame(page, 'modes-plain'))).not.toHaveAttribute('data-snapshot-mode');
		await expect(
			frame(page, 'modes-plain').locator('.markdown-editor-wrapper')
		).not.toHaveAttribute('data-snapshot-mode');
	});

	test('snapshotMode suppresses the caret and the selection highlight on the container and every descendant', async () => {
		// The rule is `[data-snapshot-mode], [data-snapshot-mode] *`, so it
		// reaches the container itself AND the ProseMirror several levels below.
		// Computed style is the only way to observe a universal selector's
		// reach; these are CSS keywords and a fully transparent color, not
		// measurements.
		const readStyles = (scope: Locator) =>
			scope.evaluate((container) => {
				const editor = container.querySelector('.ProseMirror')!;
				return {
					containerSelect: getComputedStyle(container).userSelect,
					containerCaret: getComputedStyle(container).caretColor,
					editorSelect: getComputedStyle(editor).userSelect,
					editorCaret: getComputedStyle(editor).caretColor
				};
			});

		expect(await readStyles(surface(frame(page, 'modes-snapshot')))).toEqual({
			containerSelect: 'none',
			containerCaret: 'rgba(0, 0, 0, 0)',
			editorSelect: 'none',
			editorCaret: 'rgba(0, 0, 0, 0)'
		});

		// The control: without the attribute nothing is suppressed, and the
		// caret keeps a real, opaque color.
		const plain = await readStyles(surface(frame(page, 'modes-plain')));
		expect(plain.containerSelect).toBe('auto');
		expect(plain.editorSelect).toBe('auto');
		expect(plain.containerCaret).not.toBe('rgba(0, 0, 0, 0)');
		expect(plain.editorCaret).not.toBe('rgba(0, 0, 0, 0)');
	});

	test('snapshotMode really is purely visual: the editor still takes typed input and still creates comments', async () => {
		// The prop's own doc says it "does NOT affect editability, ProseMirror
		// state, or any prop controlled by readonly / mode". `user-select: none`
		// on a contenteditable makes that non-obvious — but a real click still
		// places a caret and the keystrokes still land.
		const value = page.getByTestId('modes-snapshot-value-json');
		const before = ((await value.textContent()) ?? '').trim();

		await bodyParagraph(page, 'modes-snapshot').click();
		await expect(page.locator('#modes-snapshot .ProseMirror')).toBeFocused();
		await page.keyboard.type('SNAPSHOT');

		await expect(page.locator('#modes-snapshot .ProseMirror')).toContainText('SNAPSHOT');
		await expect.poll(async () => ((await value.textContent()) ?? '').trim()).not.toBe(before);
		// `onchange` fired with a document length, so ProseMirror state genuinely
		// moved rather than the DOM merely repainting.
		await expect(
			page.getByTestId('modes-snapshot-event-log').getByRole('listitem').last()
		).toHaveText(/^change:\d+$/);

		// The mount-time blur is exactly that: a `$effect` whose only reactive
		// dependencies are `snapshotMode` and the container element. It runs
		// once and never again, so focus acquired afterwards is left alone.
		await expect(page.locator('#modes-snapshot .ProseMirror')).toBeFocused();

		// Comment creation is untouched too — the selection popover appears here
		// exactly as it does in a non-snapshot edit instance.
		expect(await selectText(page, 'modes-snapshot', 'Checklist')).toBe('Checklist');
		await expect(page.locator('#modes-snapshot-selection-popover')).toHaveCount(1);
		await clearSelection(page);
		await expect(page.locator('#modes-snapshot-selection-popover')).toHaveCount(0);
	});

	test('`placeholder` becomes an inline custom property unconditionally — and is never painted (pinned known bug)', async () => {
		const inlinePlaceholder = (editorId: string) =>
			page
				.locator(`#${editorId}`)
				.evaluate((element) =>
					(element as HTMLElement).style.getPropertyValue('--editor-placeholder')
				);

		// The prop is written straight onto the markdown-editor host as
		// `style:--editor-placeholder="'{escaped}'"` with no emptiness check, so
		// it is present on a fully populated document too — and it arrives as a
		// QUOTED CSS string, ready for `content:`, not as a bare value.
		expect(await inlinePlaceholder('modes-plain')).toBe("'Start reviewing…'");
		expect(await inlinePlaceholder('modes-edit')).toBe("'Start writing...'");

		// PINNED KNOWN BUG — this is what the shipped build does, not what the
		// component intends. The stylesheet paints the placeholder through
		// `.ProseMirror p.is-editor-empty:first-child::before`, and Milkdown's
		// `placeholderPlugin` is supposed to decorate the first paragraph with
		// that class whenever the document is empty. The decoration never
		// reaches the DOM: `modes-plain` holds an empty document and an empty
		// paragraph, and the class is absent — so the placeholder text is
		// unreachable through the only prop that sets it.
		await expect(page.getByTestId('modes-plain-value-length')).toHaveText('value length: 0');
		const emptyParagraph = page.locator('#modes-plain .ProseMirror p');
		await expect(emptyParagraph).toHaveCount(1);
		await expect(emptyParagraph).not.toHaveClass(/is-editor-empty/);

		// Isolate the failure to the missing decoration rather than to the
		// plumbing: force the class on and the very same `::before` resolves to
		// the passed placeholder, then put the DOM back the way it was.
		const painted = await emptyParagraph.evaluate((paragraph) => {
			const before = getComputedStyle(paragraph, '::before').content;
			paragraph.classList.add('is-editor-empty');
			const after = getComputedStyle(paragraph, '::before').content;
			paragraph.classList.remove('is-editor-empty');
			return { before, after };
		});
		expect(painted.before).toBe('none');
		expect(painted.after).toBe('"Start reviewing…"');

		// Either way the placeholder is decoration and not content: a
		// pseudo-element is invisible to the accessibility tree, and nothing
		// carries a `placeholder` attribute for a locator to find.
		await expect(page.getByPlaceholder('Start reviewing…')).toHaveCount(0);
	});

	test('`class` is merged onto the container after `review-editor-container`, not substituted for it', async () => {
		const classesOf = (scope: Locator) => scope.evaluate((element) => [...element.classList]);

		const merged = await classesOf(surface(frame(page, 'modes-plain')));
		// `classNames('review-editor-container', className)` puts the
		// component's own class first; the Svelte compiler then appends its
		// scoping hash. That trailing hash is why this is a membership plus
		// index check rather than a string comparison.
		expect(merged[0]).toBe('review-editor-container');
		expect(merged).toContain('exercise-frame');
		expect(merged.some((name) => name.startsWith('svelte-'))).toBe(true);

		// An instance that passes no `class` still gets the base class, so the
		// merge added `exercise-frame` rather than replacing anything.
		const bare = await classesOf(surface(frame(page, 'modes-edit')));
		expect(bare[0]).toBe('review-editor-container');
		expect(bare).not.toContain('exercise-frame');
	});
});
