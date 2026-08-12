import { expect, test } from '@playwright/test';

// Hydration cleanliness can only be observed in a DEV build: Svelte strips the
// `hydration_mismatch` warning from production output, and the rest of this
// suite runs against `build && preview`. That is exactly how cinder#756 went
// unnoticed here through 91 passing tests — including SSR-sensitive ones —
// while every Chat route emitted a mismatch on load.
//
// These tests drive the second `webServer` in playwright.config.ts (a dev
// server on DEV_PORT) with absolute URLs, so they are unaffected by `baseURL`.
const DEV_ORIGIN = 'http://localhost:5175';

// Every route here must hydrate cleanly. `/exercises` renders neither Chat nor
// ReviewEditor and stays in the list as the control: if all of them go red at
// once it points at the shared layout, the base styles, or the hydration
// beacon rather than at a component.
//
// This used to assert that each Chat route emitted EXACTLY ONE mismatch — a
// pinned bug, not a passing test. Fixed upstream by cinder#1261 and verified
// here against `@lostgradient/cinder@0.24.1` / `@lostgradient/chat@0.9.1`: all
// three Chat routes now report zero, as does a page containing nothing but a
// Cinder icon, which is where that one was localized.
const HYDRATING_ROUTES = [
	'/',
	'/exercises',
	'/exercises/presentation',
	'/exercises/history-scroll'
];

// ReviewEditor still emits one, for a DIFFERENT reason than the Chat issue —
// bisected on the same dev server, same run: a bare `MarkdownEditor` is clean
// and a bare `ReviewEditor` is not, so it is ReviewEditor's own shell rather
// than the inner editor or the shared icons. SSR emits keyed block markers
// (`<!--[0-->…<!--]-->`, `<!--[-1--><!--]-->`) around the LiveRegion and the
// empty `{#if name}` hidden-input block where the client renders plain anchors.
//
// Pinned at exactly one, not weakened to "at most one": if it becomes two, that
// is a new divergence worth knowing about, and if it becomes zero this test
// fails and the route moves up into HYDRATING_ROUTES.
// upstream: stevekinney/cinder#1277
const REVIEW_EDITOR_ROUTES = ['/exercises/review-basics', '/exercises/review-views'];

async function collectHydrationMismatches(
	page: import('@playwright/test').Page,
	path: string
): Promise<string[]> {
	const mismatches: string[] = [];
	// Attached BEFORE navigation: the warning is emitted during hydration and is
	// gone by the time any post-load hook could subscribe.
	page.on('console', (message) => {
		if (/hydration_mismatch|hydration failed/i.test(message.text())) {
			mismatches.push(message.text());
		}
	});
	await page.goto(`${DEV_ORIGIN}${path}`);
	await page.locator('body[data-hydrated="true"]').waitFor();
	// Hydration warnings can trail the beacon by a frame or two.
	await page.waitForTimeout(1000);
	return mismatches;
}

for (const route of HYDRATING_ROUTES) {
	test(`${route} hydrates without a mismatch`, async ({ page }) => {
		expect(await collectHydrationMismatches(page, route)).toHaveLength(0);
	});
}

for (const route of REVIEW_EDITOR_ROUTES) {
	test(`ReviewEditor route ${route} emits the known hydration mismatch`, async ({ page }) => {
		expect(await collectHydrationMismatches(page, route)).toHaveLength(1);
	});
}
