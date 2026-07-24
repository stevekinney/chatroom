import { expect, test } from '@playwright/test';
import { gotoHydrated } from '../hydration';

test('scroll state binds and jump-to-latest fires when new messages arrive while scrolled up', async ({
	page
}) => {
	await gotoHydrated(page, '/exercises/history-scroll');

	const atBottom = page.getByTestId('history-scroll-at-bottom');
	const unreadCount = page.getByTestId('history-scroll-unread-count');
	const indicatorVisible = page.getByTestId('history-scroll-indicator-visible');
	const eventLog = page.getByTestId('history-scroll-event-log-item');

	// Seeded with a long transcript; Chat starts pinned to the bottom.
	await expect(atBottom).toHaveText('true');
	await expect(unreadCount).toHaveText('0');
	await expect(indicatorVisible).toHaveText('false');

	// Scroll away from the bottom deterministically via the imperative API
	// rather than a real wheel gesture.
	await page.getByTestId('history-scroll-scroll-top').click();
	await expect(atBottom).toHaveText('false');
	await expect(eventLog.last()).toHaveText('scrollstatechange: atBottom=false');

	// A message arrives while scrolled away: unreadCount/newMessageIndicatorVisible
	// bind up, onunreadindicatorchange fires, and the jump-to-latest button appears.
	await page.getByTestId('history-scroll-simulate-incoming').click();
	await expect(unreadCount).toHaveText('1');
	await expect(indicatorVisible).toHaveText('true');
	await expect(eventLog.last()).toContainText('unreadindicatorchange: unreadCount=1 visible=true');

	const jumpButton = page.getByRole('button', { name: /Jump to/ });
	await expect(jumpButton).toBeVisible();

	// Clicking Chat's own jump-to-latest button fires onjumptolatest and
	// scrolls back to the bottom, clearing the unread state.
	await jumpButton.click();
	await expect(eventLog.last()).toHaveText('jumptolatest');
	await expect(atBottom).toHaveText('true');
	await expect(unreadCount).toHaveText('0');
	await expect(indicatorVisible).toHaveText('false');
});

test('bottomThreshold override widens the "at bottom" zone', async ({ page }) => {
	await gotoHydrated(page, '/exercises/history-scroll');

	const atBottom = page.getByTestId('history-scroll-at-bottom');

	// An enormous bottomThreshold means the full scroll-to-top distance still
	// counts as "at bottom" (distanceFromBottom <= bottomThreshold).
	await page.getByTestId('history-scroll-bottom-threshold').fill('100000');
	await page.getByTestId('history-scroll-scroll-top').click();
	await expect(atBottom).toHaveText('true');

	// Resetting to the library default lets scrolling to the top actually
	// register as scrolled away from the bottom again.
	await page.getByTestId('history-scroll-bottom-threshold').fill('150');
	await page.getByTestId('history-scroll-scroll-top').click();
	await expect(atBottom).toHaveText('false');
});

test('jumpThreshold override suppresses the jump-to-latest button until reset', async ({
	page
}) => {
	await gotoHydrated(page, '/exercises/history-scroll');

	// A very high jumpThreshold means the scroll-to-top distance never crosses
	// it, so the far-scrolled jump button doesn't render — but Chat still
	// shows its separate "new message indicator" toast (`.chat-new-indicator`,
	// gated on unread state alone, not on jumpThreshold) once a message
	// arrives, and it renders with the same "Jump to N new messages"
	// accessible name as the jump button. Scope by class to tell the two
	// apart rather than `getByRole('button', { name: /Jump to/ })`, which
	// matches both.
	const jumpButton = page.locator('.chat-jump-button');

	await page.getByTestId('history-scroll-jump-threshold').fill('100000');
	await page.getByTestId('history-scroll-scroll-top').click();
	await expect(page.getByTestId('history-scroll-at-bottom')).toHaveText('false');
	// Wait for the scrollstatechange log entry, not just the bound prop: the
	// bottom-sentinel IntersectionObserver can re-assert atBottom=true during
	// the first frames of the programmatic scroll (it ignores the scroll
	// guard), and a message appended in that window never accrues unread
	// count. A real scroll event reporting atBottom=false means the viewport
	// has genuinely left the bottom. upstream: stevekinney/cinder#864
	await expect(page.getByTestId('history-scroll-event-log-item').last()).toHaveText(
		'scrollstatechange: atBottom=false'
	);
	await page.getByTestId('history-scroll-simulate-incoming').click();

	await expect(page.getByTestId('history-scroll-unread-count')).toHaveText('1');
	await expect(jumpButton).toHaveCount(0);

	// Resetting jumpThreshold back to the library default lets the button
	// reappear once threshold and unread state actually agree.
	await page.getByTestId('history-scroll-jump-threshold').fill('200');
	await page.getByTestId('history-scroll-scroll-top').click();
	await expect(jumpButton).toBeVisible();
});

test('history pagination via adapter.loadOlderMessages prepends pages and exhausts moreHistoryAvailable', async ({
	page
}) => {
	await gotoHydrated(page, '/exercises/history-scroll');

	const messageCount = page.getByTestId('history-scroll-message-count');
	const pagesRemaining = page.getByTestId('history-scroll-pages-remaining');
	const moreHistory = page.getByTestId('history-scroll-more-history');
	const loadEarlier = page.getByRole('button', { name: 'Load earlier messages (custom)' });

	await expect(messageCount).toHaveText('60');
	await expect(pagesRemaining).toHaveText('3');
	await expect(moreHistory).toHaveText('true');
	await expect(loadEarlier).toBeVisible();

	// `loadEarlier.click()` scrolls the trigger into view first (it sits above
	// the currently-loaded messages), which is itself a legitimate scroll
	// away from the bottom — Chat may log a trailing `scrollstatechange`
	// entry after the "loaded a page" one. Assert the log contains the
	// expected entry rather than assuming it's strictly the last one.
	await loadEarlier.click();
	await expect(messageCount).toHaveText('64');
	await expect(pagesRemaining).toHaveText('2');
	await expect(
		page
			.getByTestId('history-scroll-event-log-item')
			.getByText('adapter: loaded a page, hasMore=true', { exact: true })
	).toBeVisible();

	await loadEarlier.click();
	await expect(messageCount).toHaveText('68');
	await expect(pagesRemaining).toHaveText('1');

	// Third and final page exhausts the queue: moreHistoryAvailable flips to
	// false and Chat hides the "Load earlier messages" trigger entirely.
	await loadEarlier.click();
	await expect(messageCount).toHaveText('72');
	await expect(pagesRemaining).toHaveText('0');
	await expect(moreHistory).toHaveText('false');
	await expect(
		page
			.getByTestId('history-scroll-event-log-item')
			.getByText('adapter: loaded a page, hasMore=false', { exact: true })
	).toBeVisible();
	await expect(loadEarlier).toHaveCount(0);
});

test('history pagination via onloadhistory callback (no adapter.loadOlderMessages)', async ({
	page
}) => {
	await gotoHydrated(page, '/exercises/history-scroll');

	await page.getByTestId('history-scroll-mode-callback').check();
	await expect(page.getByTestId('history-scroll-message-count')).toHaveText('60');
	await expect(page.getByTestId('history-scroll-pages-remaining')).toHaveText('3');

	const loadEarlier = page.getByRole('button', { name: 'Load earlier messages (custom)' });
	await loadEarlier.click();

	await expect(page.getByTestId('history-scroll-message-count')).toHaveText('64');
	await expect(page.getByTestId('history-scroll-pages-remaining')).toHaveText('2');
	// See the adapter-mode test above: `loadEarlier.click()` scrolls the
	// trigger into view first, which can legitimately log a trailing
	// `scrollstatechange` entry after this one.
	await expect(
		page
			.getByTestId('history-scroll-event-log-item')
			.getByText('callback: loaded a page, hasMore=true', { exact: true })
	).toBeVisible();

	// Exhaust the remaining two pages: onloadhistory is driving this (there is
	// no adapter.loadOlderMessages in this mode), and moreHistoryAvailable is
	// managed entirely by this page's own state, not by Chat internals.
	await loadEarlier.click();
	await loadEarlier.click();

	await expect(page.getByTestId('history-scroll-message-count')).toHaveText('72');
	await expect(page.getByTestId('history-scroll-more-history')).toHaveText('false');
	await expect(loadEarlier).toHaveCount(0);
});
