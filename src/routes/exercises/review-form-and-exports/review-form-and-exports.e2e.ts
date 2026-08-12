import { expect, test } from '@playwright/test';
import { gotoHydrated } from '../hydration';
import type { Locator, Page } from '@playwright/test';

// ReviewEditor's form participation and its export menu are two renderings of
// the same five derivations, so this file pins them together, plus the pure
// functions (`@lostgradient/editor/review-editor` and `.../export`) that are
// supposed to reproduce them outside the component.
//
// Everything asserted here was checked against the running component; where a
// behavior is WRONG but real it is pinned as such, with a comment saying so,
// rather than softened into something that passes.

test.use({ permissions: ['clipboard-read', 'clipboard-write'] });

const ROUTE = '/exercises/review-form-and-exports';

// The five hidden inputs, in DOM order. `name` is a PREFIX: the component
// joins it to each field with a hyphen.
const REVIEW_FIELDS = [
	'review-original',
	'review-current',
	'review-comments',
	'review-diff',
	'review-summary'
];

// The unified diff for the seeded fixture, byte for byte. One modified line and
// one added line, three lines of context, merged into a single hunk. Written
// out rather than derived so a change in the diff algorithm shows up as a
// failure here instead of being absorbed by a self-referential comparison.
const EXPECTED_DIFF = [
	'--- a/document.md',
	'+++ b/document.md',
	'@@ -1,8 +1,9 @@',
	' # Release Plan',
	' ',
	'-The first release includes a dashboard and export actions.',
	'+The first release includes a dashboard, export actions, and inline review.',
	' ',
	' ## Checklist',
	' ',
	' - Finalize the component API',
	' - Add playground coverage',
	'+- Document review export behavior',
	''
].join('\n');

// `generateCommentsExport` output for the same fixture. Note `**Total
// comments:** 1` against a thread that holds TWO comments — the second carries
// `deletedAt`, and every comments export filters soft-deleted comments out.
const EXPECTED_COMMENTS_MARKDOWN = [
	'# Review Comments\n',
	'Comments on specific text selections:\n',
	'### Comment at offset 0\n',
	'> Release Plan',
	'',
	'**maya** (2026-08-11):',
	'Title reads well — keep it.',
	'',
	'---\n',
	'---\n',
	'**Total threads:** 1',
	'**Total comments:** 1'
].join('\n');

// Everything the published wrapper must forward through `bind:this`. An earlier
// build forwarded NONE of it — `bind:this` handed back an object with no
// methods — so this list is the regression guard, not decoration.
const IMPERATIVE_METHODS = [
	'clearAllThreads',
	'createBlockThread',
	'createComment',
	'createDocumentThread',
	'createThread',
	'deleteComment',
	'deleteThread',
	'exportMarkdownSummary',
	'exportUnifiedDiff',
	'focus',
	'getAst',
	'getEditor',
	'getFormData',
	'getMarkdown',
	'getSelection',
	'getState',
	'getView',
	'reset',
	'scrollToThread',
	'setMarkdown',
	'setState',
	'updateComment'
];

const namedEditor = (page: Page) => page.getByTestId('named-editor');
const bareEditor = (page: Page) => page.getByTestId('bare-editor');
const exportTrigger = (page: Page) =>
	namedEditor(page).getByRole('button', { name: 'Copy to clipboard' });
const exportMenu = (page: Page) => page.locator('#exports-editor-export-menu');
// The copy announcer is `cinder-sr-only` — clipped, not hidden — so it has text
// but is never visible. Assert on it through the DOM, never through a
// visible-text locator.
const copyAnnouncer = (page: Page) =>
	namedEditor(page).locator('.export-actions .cinder-sr-only[aria-live="polite"]');

/**
 * Navigate and wait until all three ReviewEditor instances have a live
 * ProseMirror view. `data-ready` is set once the view exists and no pending
 * state is queued; without it, an early click can land on markup whose editor
 * has not mounted.
 */
async function gotoReady(page: Page) {
	await gotoHydrated(page, ROUTE);
	// Three Milkdown instances mount here (~270ms locally). The generous
	// timeout is headroom for parallel-worker CPU contention, not an
	// expectation that it is ever slow.
	await expect(page.locator('[data-testid="review-editor"][data-ready="true"]')).toHaveCount(3, {
		timeout: 15000
	});
}

/**
 * Open the export menu, click one item, and return what landed on the
 * clipboard.
 *
 * The clipboard read is gated on the copy announcement rather than issued
 * straight after the click: `createCopyState.trigger()` awaits
 * `copyToClipboard(text)` and only then writes `copiedKey`, so the announcement
 * strictly follows the write. Waiting for it with an auto-retrying matcher is
 * what makes the `evaluate` below deterministic.
 */
async function copyFromExportMenu(
	page: Page,
	itemName: string | RegExp,
	announcement: string
): Promise<string> {
	await exportTrigger(page).click();
	await expect(exportMenu(page)).toBeVisible();
	await exportMenu(page).getByRole('menuitem', { name: itemName }).click();
	await expect(copyAnnouncer(page)).toHaveText(announcement);
	return page.evaluate(() => navigator.clipboard.readText());
}

async function submitAndRead(page: Page, submitTestId: string, countTestId: string) {
	const count = Number(
		(await page.getByTestId(countTestId).textContent())?.replace(/\D/g, '') ?? 0
	);
	await page.getByTestId(submitTestId).click();
	await expect(page.getByTestId(countTestId)).toHaveText(`submits: ${count + 1}`);
}

const valueOf = (locator: Locator) => locator.inputValue();

test.describe('review form participation', () => {
	let page: Page;

	test.beforeAll(async ({ browser }) => {
		page = await browser.newPage();
		await gotoReady(page);
	});

	test.afterAll(async () => {
		await page.close();
	});

	test('`name` emits exactly five prefixed hidden inputs, server-rendered, and nothing unprefixed', async ({
		request
	}) => {
		// Fetched as raw HTML rather than read from the hydrated page: the claim
		// is that the inputs exist in the SSR payload, so a form posted before
		// hydration still carries the review. A DOM read cannot tell the two
		// apart.
		const html = await (await request.get(ROUTE)).text();

		for (const field of REVIEW_FIELDS) {
			expect(html).toContain(`name="${field}"`);
		}
		expect(html.match(/name="review-/g)).toHaveLength(5);
		// The third editor sets `name="bare"`, so the page's full hidden-input
		// census is 5 + 0 + 5.
		expect(html.match(/name="bare-/g)).toHaveLength(5);
		expect(html.match(/type="hidden"/g)).toHaveLength(10);

		// PINNED KNOWN BUG. `getFieldName()` reads
		// `name ? \`${name}-${field}\` : field`, and the prop is documented as a
		// "form field name prefix" — which reads as though omitting it yields
		// bare `original` / `current` / … inputs. It does not: the whole block is
		// wrapped in `{#if name}`, so the fallback branch is dead code and an
		// editor without `name` contributes nothing to its form at all. The
		// second editor on this page proves the DOM half; this proves no bare
		// names leak into the SSR payload either.
		for (const bare of ['original', 'current', 'comments', 'diff', 'summary']) {
			expect(html).not.toContain(`name="${bare}"`);
		}
	});

	test('submitting the surrounding form yields exactly those five keys, carrying the live props', async () => {
		await submitAndRead(page, 'submit-named', 'named-submit-count');

		await expect(page.getByTestId('named-form-keys')).toHaveText(REVIEW_FIELDS.join(','));

		// `review-current` is the live `value` verbatim...
		expect(await valueOf(page.getByTestId('submitted-current'))).toBe(
			await valueOf(page.getByTestId('live-value'))
		);
		// ...and `review-comments` is `JSON.stringify(threads)` on the RUNTIME
		// array, ProseMirror positions included. That is a different shape from
		// what `getState()` persists (below), which drops `from`/`to`.
		const comments = await valueOf(page.getByTestId('submitted-comments'));
		expect(comments).toBe(await valueOf(page.getByTestId('live-threads-json')));
		const parsed = JSON.parse(comments) as Array<{ anchor: Record<string, unknown> }>;
		expect(parsed[0].anchor).toMatchObject({ from: 1, to: 13, lastKnownOffset: 0 });

		// The diff and summary are the module functions' output, unmodified.
		expect(await valueOf(page.getByTestId('submitted-diff'))).toBe(EXPECTED_DIFF);
		expect(await valueOf(page.getByTestId('submitted-summary'))).toBe(
			await valueOf(page.getByTestId('module-summary'))
		);
	});

	test('the submitted summary is structured for an LLM and drops soft-deleted comments', async () => {
		await submitAndRead(page, 'submit-named', 'named-submit-count');
		const summary = await valueOf(page.getByTestId('submitted-summary'));

		expect(summary.startsWith('## Changes Made')).toBe(true);
		expect(summary).toContain('## Feedback');
		expect(summary).toContain('### On "Release Plan"');
		expect(summary).toContain('Title reads well — keep it.');
		// The thread's second comment carries `deletedAt`. It is still in
		// `threads` (and still in the hidden `review-comments` JSON), but every
		// export filters it.
		expect(summary).not.toContain('Retracted: ignore this one.');
	});

	test('typing changes `review-current` and `review-diff` — and rewrites list markers nobody touched', async ({
		page: ownPage
	}) => {
		// Its own page: this test mutates the document, which would invalidate
		// the byte-exact fixtures every other test in the file depends on.
		await gotoReady(ownPage);
		const before = await valueOf(ownPage.getByTestId('live-value'));

		// Clicking the editor's centre lands the caret at an arbitrary offset.
		// Target the first paragraph and press End instead, so the insertion
		// point is the same on every run.
		const paragraph = namedEditor(ownPage)
			.getByRole('textbox', { name: 'Markdown editor' })
			.locator('p')
			.first();
		await paragraph.click();
		await ownPage.keyboard.press('End');
		await ownPage.keyboard.type(' ZZTOP');

		await expect(ownPage.getByTestId('live-value')).not.toHaveValue(before);
		await submitAndRead(ownPage, 'submit-named', 'named-submit-count');

		const current = await valueOf(ownPage.getByTestId('submitted-current'));
		expect(current).toBe(await valueOf(ownPage.getByTestId('live-value')));
		expect(current).toContain('inline review. ZZTOP');
		expect(await valueOf(ownPage.getByTestId('submitted-diff'))).toContain(
			'+The first release includes a dashboard, export actions, and inline review. ZZTOP'
		);

		// PINNED QUIRK, and the reason `generateUnifiedDiff` normalizes by
		// default. One keystroke re-serializes the WHOLE document through
		// Milkdown, whose Markdown serializer prefers `*` bullets and terminates
		// the file with a newline. So `review-current` comes back changed in
		// three places the reviewer never touched...
		expect(before).toContain('- Finalize the component API');
		expect(current).toContain('* Finalize the component API');
		expect(current.endsWith('\n')).toBe(true);
		// ...while `review-diff` shows none of it, because the diff normalizes
		// both sides back to `-` before comparing. The two fields disagree about
		// what the document says, and the diff is the one telling the truth.
		expect(await valueOf(ownPage.getByTestId('submitted-diff'))).toContain(
			' - Finalize the component API'
		);
	});

	test('omitting `name` emits no hidden inputs at all and contributes nothing to its form', async () => {
		await expect(page.locator('#exports-unnamed-form input[type="hidden"]')).toHaveCount(0);

		await submitAndRead(page, 'submit-unnamed', 'unnamed-submit-count');
		await expect(page.getByTestId('unnamed-form-keys')).toHaveText('');
	});

	test('without `original` the toolbar reports no changes while the form claims the whole document was added', async () => {
		// Half one: the control bar. `showDiffTabs={!!original}` hides the Diff
		// and Summary tabs, and `diffStats` short-circuits to all zeroes, so the
		// DiffStatistics group is not rendered at all.
		await expect(bareEditor(page).getByRole('tab')).toHaveText(['Editor']);
		await expect(bareEditor(page).getByRole('group', { name: /lines? changed/ })).toHaveCount(0);
		// The seeded editor, for contrast: three tabs and a live count.
		await expect(namedEditor(page).getByRole('tab')).toHaveText(['Editor', 'Diff', 'Summary']);
		await expect(namedEditor(page).getByRole('group', { name: '2 lines changed' })).toBeVisible();

		// Half two: the same instance's hidden inputs. `generateUnifiedDiff`
		// reads a missing original as an empty left-hand side, which is
		// indistinguishable from "this file is new".
		await submitAndRead(page, 'submit-bare', 'bare-submit-count');
		await expect(page.getByTestId('bare-form-keys')).toHaveText(
			'bare-original,bare-current,bare-comments,bare-diff,bare-summary'
		);
		expect(await valueOf(page.getByTestId('bare-submitted-original'))).toBe('');

		const diff = await valueOf(page.getByTestId('bare-submitted-diff'));
		// PINNED KNOWN BUG: two answers to "what changed?" from one component.
		// The toolbar says nothing; the form says every line is an addition.
		// `@@ -0,0 +…` is the git convention for an empty original side, so the
		// output is well-formed — it just contradicts the chrome next to it.
		expect(diff).toContain('@@ -0,0 +1,3 @@');
		const addedLines = diff
			.split('\n')
			.filter((line) => line.startsWith('+') && line !== '+++ b/document.md');
		const lineCount = Number(
			(await page.getByTestId('bare-line-count').textContent())?.replace(/\D/g, '')
		);
		expect(addedLines).toHaveLength(lineCount);
		expect(
			diff.split('\n').some((line) => line.startsWith('-') && line !== '--- a/document.md')
		).toBe(false);
	});
});

test.describe('the imperative surface behind bind:this', () => {
	let page: Page;

	test.beforeAll(async ({ browser }) => {
		page = await browser.newPage();
		await gotoReady(page);
	});

	test.afterAll(async () => {
		await page.close();
	});

	test('`bind:this` exposes the documented methods', async () => {
		const keys = (await page.getByTestId('instance-keys').textContent())?.split(',') ?? [];
		// Not an exact-list assertion: a DEV build also hangs `$destroy`, `$on`
		// and `$set` on the instance (Svelte's legacy-API stubs, which only
		// throw a "the component API changed" error), and this suite runs
		// against a production preview where those are compiled out.
		for (const method of IMPERATIVE_METHODS) {
			expect(keys).toContain(method);
		}
	});

	test('getFormData() returns the same five values the hidden inputs carry', async () => {
		await page.getByTestId('read-form-data').click();
		await expect(page.getByTestId('imperative-form-data')).not.toHaveValue('');

		const data = JSON.parse(await valueOf(page.getByTestId('imperative-form-data'))) as Record<
			string,
			string
		>;
		expect(Object.keys(data)).toEqual(['original', 'current', 'comments', 'diff', 'summary']);

		// The hidden inputs and getFormData() read the same `$derived`s, and
		// this is where that stops being a claim in the README.
		for (const [field, key] of [
			['review-original', 'original'],
			['review-current', 'current'],
			['review-comments', 'comments'],
			['review-diff', 'diff'],
			['review-summary', 'summary']
		] as const) {
			expect(data[key]).toBe(
				await page.locator(`#exports-form input[name="${field}"]`).inputValue()
			);
		}
		expect(data.diff).toBe(EXPECTED_DIFF);
	});

	test('getState() carries a `reviewSession` key that JSON.stringify silently drops', async () => {
		await page.getByTestId('read-state-keys').click();
		// The object literal always sets `reviewSession: undefined`, so the key
		// EXISTS on the returned state...
		await expect(page.getByTestId('imperative-state-keys')).toHaveText(
			'schemaVersion,content,original,threads,reviewSession,frontMatter,frontMatterRaw,updatedAt'
		);
		// ...but `JSON.stringify` omits undefined-valued keys, which is why the
		// JSON export below has seven keys and not eight. Two different answers
		// to "what shape is ReviewState?" depending on how you look at it.
	});
});

test.describe('the export menu', () => {
	let page: Page;

	test.beforeAll(async ({ browser }) => {
		// An explicit context: `test.use({ permissions })` configures the `page`
		// FIXTURE, and a describe-shared page built from `browser.newPage()`
		// would not inherit it — clipboard reads would fail on permission.
		const context = await browser.newContext({
			permissions: ['clipboard-read', 'clipboard-write']
		});
		page = await context.newPage();
		await gotoReady(page);
	});

	test.afterAll(async () => {
		await page.context().close();
	});

	test('the trigger opens a five-item menu in a fixed order', async () => {
		const trigger = exportTrigger(page);
		await expect(trigger).toHaveAttribute('aria-haspopup', 'menu');
		await expect(trigger).toHaveAttribute('aria-controls', 'exports-editor-export-menu');
		await expect(trigger).toHaveAttribute('aria-expanded', 'false');

		await trigger.click();
		// `aria-expanded` is driven off the popover's `toggle` event rather than
		// the click, so it lands a tick late — an auto-retrying matcher, not a
		// read-after-click.
		await expect(trigger).toHaveAttribute('aria-expanded', 'true');

		const menu = exportMenu(page);
		await expect(menu).toHaveAttribute('role', 'menu');
		// DOM order is Content, Summary, Git Diff, Comments, JSON — note that
		// JSON is LAST in the DOM even though the format list in the source
		// declares it third.
		await expect(menu.getByRole('menuitem')).toHaveText([
			'Content',
			'Summary (for LLM)',
			'Git Diff',
			'Comments',
			'JSON'
		]);

		// Close it again: the trigger is a toggle, and every test below opens
		// the menu from a closed state.
		await trigger.click();
		await expect(trigger).toHaveAttribute('aria-expanded', 'false');
		await expect(menu).toBeHidden();
	});

	test('Content copies the live value verbatim', async () => {
		const copied = await copyFromExportMenu(page, 'Content', 'Copied Content');
		expect(copied).toBe(await valueOf(page.getByTestId('live-value')));
	});

	test('Summary (for LLM) copies generateMarkdownSummary().markdown', async () => {
		const copied = await copyFromExportMenu(
			page,
			/^Summary \(for LLM\)/,
			'Copied Summary (for LLM)'
		);
		expect(copied).toBe(await valueOf(page.getByTestId('module-summary')));
		expect(copied.startsWith('## Changes Made')).toBe(true);
		expect(copied).toContain('## Feedback');
		expect(copied).toContain('### On "Release Plan"');
	});

	test('Git Diff copies generateUnifiedDiff().diff', async () => {
		const copied = await copyFromExportMenu(page, /^Git Diff/, 'Copied Git Diff');
		expect(copied).toBe(EXPECTED_DIFF);
		expect(copied).toBe(await valueOf(page.getByTestId('module-diff')));
	});

	test('Comments copies generateCommentsExport().markdown', async () => {
		const copied = await copyFromExportMenu(page, /^Comments/, 'Copied Comments');
		expect(copied).toBe(EXPECTED_COMMENTS_MARKDOWN);
		expect(copied).toBe(await valueOf(page.getByTestId('module-comments-markdown')));
		// Worth stating because the two sibling exports disagree: this one opens
		// `# Review Comments`, while the empty-input path opens `# Comments`.
		expect(copied.startsWith('# Review Comments')).toBe(true);
		expect(copied.endsWith('**Total comments:** 1')).toBe(true);
	});

	test('JSON copies the whole ReviewState — not the comments-only JSON export', async () => {
		const copied = await copyFromExportMenu(page, /^JSON/, 'Copied JSON');
		const state = JSON.parse(copied) as {
			schemaVersion: number;
			original: string;
			threads: Array<{ anchor: Record<string, unknown>; comments: unknown[] }>;
			frontMatter: unknown;
			frontMatterRaw: unknown;
		};

		expect(Object.keys(state)).toEqual([
			'schemaVersion',
			'content',
			'original',
			'threads',
			'frontMatter',
			'frontMatterRaw',
			'updatedAt'
		]);
		expect(state.schemaVersion).toBe(4);
		// `reviewSession` is set to `undefined` by getState() and therefore never
		// survives serialization — see the imperative test above.
		expect(copied).not.toContain('reviewSession');
		// No front matter in this fixture, and the parser reports that as null
		// rather than as an empty object. (`review-front-matter` owns the
		// populated case.)
		expect(state.frontMatter).toBeNull();
		expect(state.frontMatterRaw).toBeNull();

		// The PERSISTED anchor shape: `from`/`to` are runtime ProseMirror
		// positions and are stripped, and undefined-valued optional fields
		// (`type`, `blockId`, `originalPosition`) vanish with them. This is a
		// different serialization of the same thread from the one the
		// `review-comments` hidden input carries.
		expect(Object.keys(state.threads[0].anchor)).toEqual([
			'quote',
			'prefix',
			'suffix',
			'status',
			'originalQuote',
			'lastKnownOffset'
		]);
		// Soft-deleted comments DO survive here — the state is an audit trail,
		// unlike the markdown exports, which filter them.
		expect(state.threads[0].comments).toHaveLength(2);

		// And the proof that this is not `generateCommentsJSON`: that export
		// produces `{ threads: [{ type, selection, … }] }` with no document
		// content at all.
		const commentsJson = await valueOf(page.getByTestId('module-comments-json'));
		expect(commentsJson).not.toBe(copied);
		expect(JSON.parse(commentsJson)).toEqual({
			threads: [
				{
					id: 'thread-release-plan-title',
					type: 'text',
					comments: [
						{
							id: 'comment-visible',
							body: 'Title reads well — keep it.',
							authorId: 'maya',
							createdAt: '2026-08-11T12:00:00.000Z'
						}
					],
					// `from`/`to` here are TEXT OFFSETS derived from
					// `lastKnownOffset` and the quote length — a third coordinate
					// space, sharing field names with the ProseMirror positions in
					// the hidden input.
					selection: { text: 'Release Plan', from: 0, to: 12 }
				}
			]
		});
	});

	test('copy confirmation announces, swaps the icon, and reverts after ~2s', async () => {
		await exportTrigger(page).click();
		await expect(exportMenu(page)).toBeVisible();
		await exportMenu(page)
			.getByRole('menuitem', { name: /^Git Diff/ })
			.click();

		// Selecting an item closes the menu (`closeOnSelect` defaults true), but
		// the popover stays in the DOM, so the confirmation state is still
		// readable — through the DOM, not through role locators, which skip
		// hidden subtrees.
		const menu = exportMenu(page);
		await expect(copyAnnouncer(page)).toHaveText('Copied Git Diff');
		await expect(menu.locator('.copied-label')).toHaveText('Copied!');
		await expect(menu.locator('svg.export-icon-success')).toHaveCount(1);

		// GOTCHA, pinned deliberately: `Copied!` is a sibling span INSIDE the
		// menu item, so for those two seconds the item's accessible name is
		// "Git Diff Copied!" and an exact-name locator stops matching it. Any
		// follow-up interaction in that window has to use a prefix match.
		// (Reopening costs ~25ms against the 2000ms window.)
		await exportTrigger(page).click();
		await expect(
			menu.getByRole('menuitem', { name: 'Git Diff Copied!', exact: true })
		).toBeVisible();
		await expect(menu.getByRole('menuitem', { name: 'Git Diff', exact: true })).toHaveCount(0);

		// After the window the label, the icon, the announcement and the
		// original accessible name all come back. Auto-retry rather than a
		// fixed sleep — the reset is a 2000ms `setTimeout` from the copy, not
		// from here.
		await expect(menu.getByRole('menuitem', { name: 'Git Diff', exact: true })).toBeVisible({
			timeout: 5000
		});
		await expect(menu.locator('.copied-label')).toHaveCount(0);
		await expect(menu.locator('svg.export-icon-success')).toHaveCount(0);
		await expect(copyAnnouncer(page)).toHaveText('');
	});
});

test.describe('the pure export functions', () => {
	let page: Page;

	test.beforeAll(async ({ browser }) => {
		page = await browser.newPage();
		await gotoReady(page);
	});

	test.afterAll(async () => {
		await page.close();
	});

	test('buildFormDataFromValues reproduces four of the five hidden inputs and quietly drops anchor positions from the fifth', async () => {
		await submitAndRead(page, 'submit-named', 'named-submit-count');

		for (const [moduleTestId, submittedTestId] of [
			['module-original', 'submitted-original'],
			['module-current', 'submitted-current'],
			['module-diff', 'submitted-diff'],
			['module-summary', 'submitted-summary']
		] as const) {
			expect(await valueOf(page.getByTestId(moduleTestId))).toBe(
				await valueOf(page.getByTestId(submittedTestId))
			);
		}

		// PINNED KNOWN BUG. `buildFormDataFromValues` is the documented stand-in
		// for the component's own form payload, but it rebuilds every anchor
		// field by field and never copies `from`/`to`. `buildFormData(state)`,
		// which serializes `state.threads` as-is, keeps them — so the two
		// "equivalent" helpers emit different JSON for the same threads, and
		// only one of them matches the DOM.
		const submitted = await valueOf(page.getByTestId('submitted-comments'));
		expect(await valueOf(page.getByTestId('module-comments-from-state'))).toBe(submitted);
		const fromValues = await valueOf(page.getByTestId('module-comments-from-values'));
		expect(fromValues).not.toBe(submitted);

		const [fromValuesAnchor] = (
			JSON.parse(fromValues) as Array<{ anchor: Record<string, unknown> }>
		).map((thread) => thread.anchor);
		expect(fromValuesAnchor).not.toHaveProperty('from');
		expect(fromValuesAnchor).not.toHaveProperty('to');
		// Everything else about the thread is untouched, which is what makes the
		// omission easy to miss.
		expect(JSON.parse(fromValues.replace(/"from":\d+,"to":\d+,/, ''))).toEqual(
			JSON.parse(submitted.replace(/"from":\d+,"to":\d+,/, ''))
		);
	});

	test('the review-editor export helpers are pass-throughs to @lostgradient/editor/export', async () => {
		// Two separate published entry points. `exportMarkdownSummary(state)` is
		// documented as a "stateless wrapper" around `generateMarkdownSummary`,
		// and this is where that stops being a docstring: same state in, byte
		// identical markdown out.
		expect(await valueOf(page.getByTestId('module-summary'))).toBe(
			await valueOf(page.getByTestId('core-summary'))
		);
	});

	test('getSummaryContentWithoutHeading is an identity function', async () => {
		const summary = await valueOf(page.getByTestId('module-summary'));
		// PINNED KNOWN BUG (dead code). The helper strips a leading
		// `# Review Summary` heading so UI previews can skip it — but
		// `generateMarkdownSummary` never emits that heading. Its sections start
		// at `## Changes Made`, so the regex matches nothing and the function
		// returns its input for every state that can be constructed.
		expect(summary).not.toContain('# Review Summary');
		expect(await valueOf(page.getByTestId('module-summary-without-heading'))).toBe(summary);
	});

	test('generateUnifiedDiff normalizes both sides, so a formatting-only edit produces no diff at all', async () => {
		// `- item one` vs `* item one`: the same list, two bullet characters.
		await expect(page.getByTestId('normalized-diff')).toHaveValue('');
		await expect(page.getByTestId('normalized-stats')).toHaveText(
			'additions:0 deletions:0 hunks:0'
		);

		// `normalizeInputs: false` compares the raw strings and finds the change.
		const raw = await valueOf(page.getByTestId('raw-diff'));
		expect(raw).toBe(
			[
				'--- a/document.md',
				'+++ b/document.md',
				'@@ -1,1 +1,1 @@',
				'-- item one',
				'+* item one',
				''
			].join('\n')
		);
		await expect(page.getByTestId('raw-stats')).toHaveText('additions:1 deletions:1 hunks:1');

		// PINNED DEVIATION: the hunk header spells out a count of 1
		// (`@@ -1,1 +1,1 @@`). Git omits `,1` and writes `@@ -1 +1 @@`. Both are
		// accepted by `git apply`, so this is cosmetic — but it means the output
		// is not byte-identical to what git would produce for the same change.
		expect(raw).toContain('@@ -1,1 +1,1 @@');
	});

	test('the comments export falls through three location formats and two headings', async () => {
		// `originalPosition` wins when present, and adds a `*Position: …*` line.
		const withPosition = await valueOf(page.getByTestId('location-position'));
		expect(withPosition).toContain('### Comment at Line 3:1');
		expect(withPosition).toContain('*Position: Line 3, Column 1 (offset 4)*');

		// Without it, the textBetween offset is the next-best address...
		expect(await valueOf(page.getByTestId('location-offset'))).toContain('### Comment at offset 4');
		// ...and with neither, the comment is printed with no location at all
		// rather than being dropped.
		expect(await valueOf(page.getByTestId('location-unknown'))).toContain(
			'### Comment (location unknown)'
		);

		// `formatTimestamp` calls `toISOString()` on an Invalid Date, which
		// throws, and swallows it — so an unparseable `createdAt` costs the
		// parenthetical, not the comment.
		const unparseable = await valueOf(page.getByTestId('unparseable-timestamp'));
		expect(unparseable).toContain('**maya**:');
		expect(unparseable).not.toContain('(');

		// The empty path uses a DIFFERENT top-level heading from the populated
		// one (`# Comments` vs `# Review Comments`) — a real inconsistency, not
		// a typo in this test.
		expect(await valueOf(page.getByTestId('empty-comments-export'))).toBe(
			'# Comments\n\nNo comments to export.'
		);
		// A thread whose every comment is soft-deleted is filtered before the
		// heading is chosen, so it takes the empty path even though
		// `state.threads` is non-empty.
		expect(await valueOf(page.getByTestId('all-soft-deleted-export'))).toBe(
			'# Comments\n\nNo comments to export.'
		);
	});
});
