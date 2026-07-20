import { expect, test } from '@playwright/test';
import { gotoHydrated } from '../hydration';
import type { Page } from '@playwright/test';

// Chat renders SSR without virtualization (`isVirtualized` is gated on a
// client-only `hasMounted` flag), so the server markup — and briefly the
// hydrated DOM — has all 500 `.chat-message` rows. `data-cinder-virtualized`
// on `.chat-timeline` is the component's own signal that the client has
// mounted and switched to the windowed render path; every row-count
// assertion below waits for it before counting, and uses `expect.poll`
// rather than a one-shot `.count()` so a late windowing pass still resolves
// the assertion instead of racing it.
async function waitForVirtualizedTimeline(page: Page) {
	await expect(page.locator('.chat-timeline[data-cinder-virtualized]')).toBeVisible();
}

test('virtualized transcript keeps DOM row count far below the message count', async ({ page }) => {
	await gotoHydrated(page, '/exercises/virtualization');
	await waitForVirtualizedTimeline(page);

	await expect(page.getByTestId('virtualization-message-count')).toHaveText('500');

	// Virtualization windows the DOM to roughly viewport + overscan, not the
	// full 500-message transcript. This is the core proof that virtualized
	// rendering is actually on, not just accepted as a prop.
	await expect.poll(() => page.locator('.chat-message').count()).toBeGreaterThan(0);
	await expect.poll(() => page.locator('.chat-message').count()).toBeLessThan(100);
});

test('scrollToBottom reaches the last message; scrollToTop is fought back to the bottom (upstream bug)', async ({
	page
}) => {
	await gotoHydrated(page, '/exercises/virtualization');
	await waitForVirtualizedTimeline(page);

	// Chat starts pinned to the bottom; the last seeded message is reachable
	// without any scrolling.
	await expect(page.getByText('Message 499')).toBeVisible();

	// `chat.scrollToTop()` is documented to navigate to the start of a
	// virtualized transcript, but under default (non-reduced) motion settings
	// it currently never gets there: Chat's own auto-stick-to-bottom effect
	// re-triggers on every row remeasurement during the smooth-scroll
	// animation (because `atBottom` never flips to `false` for a
	// programmatic scroll) and repeatedly snaps the viewport back toward the
	// bottom. See stevekinney/cinder#774 for the root cause and a
	// `prefers-reduced-motion` repro that avoids the race. This assertion
	// documents the actual current behavior rather than the intended one.
	await page.getByTestId('virtualization-scroll-top').click();
	await page.waitForTimeout(1000);
	await expect(page.getByText('Message 499')).toBeVisible();

	await page.getByTestId('virtualization-scroll-bottom').click();
	await expect(page.getByText('Message 499')).toBeVisible();
	await expect(page.getByText('Message 0')).not.toBeVisible();
});

test('tuning virtualizationOverscan changes the rendered row count but stays well below the message count', async ({
	page
}) => {
	await gotoHydrated(page, '/exercises/virtualization');
	await waitForVirtualizedTimeline(page);

	const baselineRowCount = await page.locator('.chat-message').count();

	await page.getByTestId('virtualization-overscan').fill('40');
	// Overscan is read on the next virtualizer sync; scrolling forces one.
	await page.getByTestId('virtualization-scroll-top').click();
	await page.getByTestId('virtualization-scroll-bottom').click();

	await expect.poll(() => page.locator('.chat-message').count()).toBeGreaterThan(baselineRowCount);
	await expect.poll(() => page.locator('.chat-message').count()).toBeLessThan(250);
});

test('streaming a new message into a virtualized transcript renders and finalizes it', async ({
	page
}) => {
	await gotoHydrated(page, '/exercises/virtualization');
	await waitForVirtualizedTimeline(page);

	await expect(page.getByTestId('virtualization-message-count')).toHaveText('500');

	await page.getByTestId('virtualization-stream-message').click();
	await expect(page.getByText('Streamed reply into the virtualized transcript.')).toBeVisible();
	await expect(page.getByTestId('virtualization-message-count')).toHaveText('501');

	// The streamed message is the new last message; scrolling to bottom still
	// reaches it, proving the virtualizer's item count and keys were kept in
	// sync with the growing transcript. (`scrollToTop` is not exercised here —
	// see stevekinney/cinder#774, the auto-stick-to-bottom effect fights it
	// under default motion settings.)
	await page.getByTestId('virtualization-scroll-bottom').click();
	await expect(page.getByText('Streamed reply into the virtualized transcript.')).toBeVisible();
});
