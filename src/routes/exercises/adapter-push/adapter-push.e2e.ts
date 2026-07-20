import { expect, test } from '@playwright/test';

test('adapter push seam: streamed reply, pushed message, typing indicator, and read receipts', async ({
	page
}) => {
	await page.goto('/exercises/adapter-push');

	const log = page.getByRole('log', { name: 'Messages' });

	// --- onStreamBegin / onTokenPush / onStreamEnd -------------------------
	// Sending a message routes through `adapter.sendMessage`, which drives the
	// entire assistant reply through the push handlers Chat wired at
	// `subscribe` time — no bind:this, no imperative beginStreaming call.
	await page.getByRole('textbox', { name: 'Message' }).fill('Hello there');
	await page.getByRole('button', { name: 'Send message' }).click();

	await expect(log.getByText('Hello there')).toBeVisible();
	await expect(
		log.getByText("This entire reply streamed through the adapter's onStreamBegin")
	).toBeVisible();

	// --- onMessage -> onpushmessage forwarding ------------------------------
	await page.getByTestId('push-message').click();
	await expect(
		log.getByText('A teammate just joined and pushed this message in from another client.')
	).toBeVisible();
	await expect(page.getByTestId('event-log').getByText(/onpushmessage received/)).toBeVisible();

	// --- onTypingChange -> typingParticipants indicator (adapter path) -----
	// With no `typingParticipants` prop supplied, the adapter's boolean push
	// drives Chat's built-in per-participant indicator with a synthetic
	// fallback participant.
	const typingIndicator = page.locator('[data-cinder-participant-typing]');
	await expect(typingIndicator).toHaveCount(0);

	await page.getByTestId('push-typing-start').click();
	await expect(typingIndicator).toBeVisible();
	await expect(typingIndicator).toContainText('Someone is typing');
	await expect(page.getByTestId('event-log').getByText('ontypingchange: true')).toBeVisible();

	await page.getByTestId('push-typing-stop').click();
	await expect(page.locator('[data-cinder-participant-typing]')).toHaveCount(0);
	await expect(page.getByTestId('event-log').getByText('ontypingchange: false')).toBeVisible();

	// --- typingParticipants prop, exercised directly ------------------------
	// A DEFINED `typingParticipants` prop is authoritative over the adapter
	// push, so this shows a named participant instead of the generic fallback.
	await page.getByTestId('toggle-direct-typing').click();
	await expect(typingIndicator).toBeVisible();
	await expect(typingIndicator).toContainText('Priya is typing');

	// The adapter's push is now suppressed while the direct prop is active —
	// starting (and clearing) the adapter push does not change the label.
	await page.getByTestId('push-typing-start').click();
	await expect(typingIndicator).toContainText('Priya is typing');
	await page.getByTestId('push-typing-stop').click();
	await expect(typingIndicator).toContainText('Priya is typing');

	await page.getByTestId('toggle-direct-typing').click();
	await expect(page.locator('[data-cinder-participant-typing]')).toHaveCount(0);

	// --- onReadReceipt -> readReceipts badge on the user message (adapter) -
	// Only one user message exists in this transcript, so the badge selector
	// is unambiguous.
	const readBadge = page.locator('[data-cinder-receipt-status="read"]');
	await expect(readBadge).toHaveCount(0);
	await page.getByTestId('push-read-receipt').click();
	await expect(readBadge).toBeVisible();
	await expect(page.getByTestId('event-log').getByText(/onreadreceipt: message/)).toBeVisible();

	// --- readReceipts prop, exercised directly ------------------------------
	await page.getByTestId('toggle-direct-read-receipt').click();
	await expect(readBadge).toBeVisible();
	await expect(readBadge).toHaveAttribute('aria-label', 'Read by Priya');
});
