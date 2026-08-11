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

// Routes that render a `<Chat>`, plus one that does not. The Chat-free route is
// the control: it proves a failure below is attributable to Chat rather than to
// the shared layout, the base styles, or the hydration beacon.
const CHAT_ROUTES = ['/', '/exercises/presentation', '/exercises/history-scroll'];
const CHAT_FREE_ROUTE = '/exercises';

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

test('a route without Chat hydrates cleanly (control for the Chat routes below)', async ({
	page
}) => {
	expect(await collectHydrationMismatches(page, CHAT_FREE_ROUTE)).toHaveLength(0);
});

for (const route of CHAT_ROUTES) {
	// REGRESSION (pinned, not weakened): every route rendering Chat emits exactly
	// one `hydration_mismatch` on load. The SSR markup and the post-hydration DOM
	// for the Chat subtree do converge — identical tag sequences, differing only
	// in attribute order — so Svelte detects the divergence and recovers; what is
	// lost is the discarded hydration work and any state it resets. Flip this to
	// `toHaveLength(0)` (and fold these into one loop with the control above)
	// once fixed. upstream: stevekinney/cinder#756
	test(`Chat route ${route} emits the known hydration mismatch`, async ({ page }) => {
		expect(await collectHydrationMismatches(page, route)).toHaveLength(1);
	});
}
