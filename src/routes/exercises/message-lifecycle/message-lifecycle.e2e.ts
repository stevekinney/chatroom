import { expect, test } from '@playwright/test';
import type { Locator, Page } from '@playwright/test';

// Exercises retry / edit / stop-generating across two Chat instances on the
// same page: one wired through a ChatAdapter, one wired through plain
// onsubmit/onretry/onedit/onstopgenerating callback props with no adapter at
// all. Everything is deterministic — the "assistant reply" is a fixed,
// in-page token sequence, never a real network call.

async function retryFailedMessage(
	chat: Locator,
	log: Locator,
	replacementText: string,
	expectedLogSubstring: string
) {
	await expect(chat.getByText('Failed to send', { exact: true })).toBeVisible();

	const retryButton = chat.getByRole('button', { name: 'Retry' });
	await expect(retryButton).toBeVisible();
	await retryButton.click();

	await expect(log).toContainText(expectedLogSubstring);
	await expect(chat.getByText('Failed to send', { exact: true })).toHaveCount(0);
	await expect(chat.getByText(replacementText)).toBeVisible();
}

async function editUserMessage(
	chat: Locator,
	log: Locator,
	newText: string,
	expectedLogSubstring: string
) {
	// User-message action buttons (Edit, etc.) render outside their message
	// wrapper's own box (positioned to the left of a right-aligned bubble) and
	// only become pointer-hit-testable while their wrapper is hovered — a
	// region that doesn't geometrically overlap the buttons themselves, so a
	// literal mouse hover-then-click can never reach them. Focusing first
	// exercises the same keyboard-accessible reveal path real keyboard/AT
	// users rely on, and makes the button hit-testable for the click that
	// follows.
	const editButton = chat.getByRole('button', { name: 'Edit message' });
	await editButton.focus();
	await editButton.click();

	const editBox = chat.getByRole('textbox', { name: 'Edit message content' });
	await editBox.fill(newText);
	await chat.getByRole('button', { name: 'Save & Resend' }).click();

	await expect(log).toContainText(expectedLogSubstring);
	await expect(chat.getByText(newText)).toBeVisible();
}

async function sendAndStopGenerating(chat: Locator, log: Locator, expectedLogSubstring: string) {
	const messagesLog = chat.getByRole('log', { name: 'Messages' });

	await chat.getByRole('textbox', { name: 'Message' }).fill('Tell me something long, please.');
	await chat.getByRole('button', { name: 'Send message' }).click();

	// Wait for the stream to have produced some, but not all, of its content
	// before interrupting it — proves the stop actually landed mid-stream
	// rather than after it had already finished on its own.
	await expect(messagesLog).toContainText('Streaming a');

	await chat.getByRole('button', { name: 'Stop generating' }).click();

	await expect(log).toContainText(expectedLogSubstring);
	await expect(chat.getByRole('button', { name: 'Send message' })).toBeVisible();
	await expect(messagesLog).not.toContainText('by token.');
}

test.describe('message lifecycle: retry, edit, and stop-generating', () => {
	let page: Page;

	test.beforeAll(async ({ browser }) => {
		page = await browser.newPage();
		await page.goto('/exercises/message-lifecycle');
	});

	test.afterAll(async () => {
		await page.close();
	});

	test('adapter-driven Chat: adapter.retryMessage, adapter.editMessage, adapter.stopGenerating', async () => {
		const chat = page.locator('#message-lifecycle-adapter-chat');
		const log = page.getByTestId('adapter-log');

		await retryFailedMessage(
			chat,
			log,
			'Retried reply: the deterministic fact arrived on retry.',
			'retryMessage:'
		);
		await editUserMessage(chat, log, 'Updated question via adapter.editMessage', 'editMessage:');
		await sendAndStopGenerating(chat, log, 'stopGenerating');
	});

	test('callback-only Chat (no adapter): onretry, onedit, onstopgenerating', async () => {
		const chat = page.locator('#message-lifecycle-plain-chat');
		const log = page.getByTestId('plain-log');

		await retryFailedMessage(
			chat,
			log,
			'Retried via plain callback: the deterministic fact arrived on retry.',
			'onretry:'
		);
		await editUserMessage(chat, log, 'Updated question via plain onedit', 'onedit:');
		await sendAndStopGenerating(chat, log, 'onstopgenerating:');

		// Sanity check that the plain-callback path really has no adapter wired.
		await expect(log).toContainText('onsubmit');
		await expect(log).toContainText('onretry:');
		await expect(log).toContainText('onedit:');
		await expect(log).toContainText('onstopgenerating:');
	});
});
