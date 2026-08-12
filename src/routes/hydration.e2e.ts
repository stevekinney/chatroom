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
// The ReviewEditor routes joined this list once cinder#1277 shipped. That one
// was NOT the LiveRegion or the empty `{#if name}` block it looked like: the
// editor package listed `node` before `svelte` in its conditional exports, so
// SvelteKit SSR loaded the precompiled `dist/server` bundle while the browser
// compiled the same components from source — two independent compilations of
// one page, disagreeing on hydration anchor comments. Exactly what cinder#1261
// fixed for chat and cinder; editor was missed by that sweep.
const HYDRATING_ROUTES = [
	'/',
	'/exercises',
	'/exercises/presentation',
	'/exercises/history-scroll',
	'/exercises/review-basics',
	'/exercises/review-views'
];

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
