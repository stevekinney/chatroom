import { expect, test } from '@playwright/test';
import { gotoHydrated } from './exercises/hydration';

test('sends a message and streams the assistant reply into the conversation log', async ({
	page
}) => {
	await page.route('**/api/chat', async (route) => {
		const events = [
			{ type: 'text', text: 'Hello ' },
			{ type: 'text', text: 'there!' }
		];
		const body = events.map((event) => JSON.stringify(event)).join('\n') + '\n';

		await route.fulfill({
			status: 200,
			contentType: 'application/x-ndjson; charset=utf-8',
			body
		});
	});

	await gotoHydrated(page, '/');

	const composer = page.getByRole('textbox', { name: 'Message' });
	await expect(composer).toBeVisible();

	await composer.fill('Hello from Playwright');
	await page.getByRole('button', { name: 'Send message' }).click();

	const log = page.getByRole('log', { name: 'Messages' });
	await expect(log.getByText('Hello from Playwright')).toBeVisible();
	await expect(log.getByText('Hello there!')).toBeVisible();
});

test('stop generating aborts the in-flight request without surfacing an error', async ({
	page
}) => {
	// A request that is never fulfilled keeps the turn in its streaming state
	// so Stop is clickable; the client-side abort is the only way it ends,
	// and Chromium reports that abort as a failed request.
	let requestAborted = false;
	page.on('requestfailed', (request) => {
		if (request.url().includes('/api/chat')) requestAborted = true;
	});
	await page.route('**/api/chat', () => {
		// Intentionally left pending — see above.
	});

	await gotoHydrated(page, '/');
	const composer = page.getByRole('textbox', { name: 'Message' });
	await composer.fill('Long question, interrupted');
	await page.getByRole('button', { name: 'Send message' }).click();

	await page.getByRole('button', { name: 'Stop generating' }).click();

	// Streaming state fully unwinds: the composer is sendable again and no
	// error alert appears — a user-initiated stop is not a failure.
	await expect(page.getByRole('button', { name: 'Send message' })).toBeVisible();
	await expect(page.getByRole('alert')).toHaveCount(0);
	await expect.poll(() => requestAborted).toBe(true);
});

test('editing a user message rewinds the superseded branch and resends', async ({ page }) => {
	const replies = ['First reply.', 'Second reply.'];
	const requestBodies: string[] = [];
	await page.route('**/api/chat', async (route) => {
		requestBodies.push(route.request().postData() ?? '');
		const text = replies[requestBodies.length - 1] ?? 'Extra reply.';
		await route.fulfill({
			status: 200,
			contentType: 'application/x-ndjson; charset=utf-8',
			body: JSON.stringify({ type: 'text', text }) + '\n'
		});
	});

	await gotoHydrated(page, '/');
	const chat = page.locator('#chatroom-demo-chat');
	const composer = page.getByRole('textbox', { name: 'Message' });
	await composer.fill('Original question');
	await page.getByRole('button', { name: 'Send message' }).click();
	await expect(chat.getByText('First reply.')).toBeVisible();

	const editButton = chat.getByRole('button', { name: 'Edit message' });
	await editButton.focus();
	await editButton.click();
	const editBox = chat.getByRole('textbox', { name: 'Edit message content' });
	await editBox.fill('Edited question');
	await chat.getByRole('button', { name: 'Save & Resend' }).click();

	await expect(chat.getByText('Second reply.')).toBeVisible();
	// The superseded branch is gone from the transcript…
	await expect(chat.getByText('Original question')).toHaveCount(0);
	await expect(chat.getByText('First reply.')).toHaveCount(0);
	// …and from the payload the model sees: the resent conversation contains
	// the edited content and none of the superseded messages.
	expect(requestBodies).toHaveLength(2);
	expect(requestBodies[1]).toContain('Edited question');
	expect(requestBodies[1]).not.toContain('Original question');
	expect(requestBodies[1]).not.toContain('First reply.');
});

test('retry after a failed send re-runs the assistant turn', async ({ page }) => {
	let calls = 0;
	await page.route('**/api/chat', async (route) => {
		calls += 1;
		if (calls === 1) {
			await route.fulfill({ status: 500, body: 'Simulated upstream failure' });
			return;
		}
		await route.fulfill({
			status: 200,
			contentType: 'application/x-ndjson; charset=utf-8',
			body: JSON.stringify({ type: 'text', text: 'Recovered reply.' }) + '\n'
		});
	});

	await gotoHydrated(page, '/');
	const chat = page.locator('#chatroom-demo-chat');
	const composer = page.getByRole('textbox', { name: 'Message' });
	await composer.fill('Please fail once');
	await page.getByRole('button', { name: 'Send message' }).click();

	// Two alerts appear: the page-level error banner and Chat's own
	// "Failed to send" label on the failed user message.
	await expect(
		page.getByRole('alert').filter({ hasText: 'Simulated upstream failure' })
	).toBeVisible();
	await expect(page.getByRole('alert').filter({ hasText: 'Failed to send' })).toBeVisible();

	const retryButton = chat.getByRole('button', { name: 'Retry' });
	await retryButton.focus();
	await retryButton.click();

	await expect(chat.getByText('Recovered reply.')).toBeVisible();
	// Both the error banner and the failed mark clear on success.
	await expect(page.getByRole('alert')).toHaveCount(0);
	expect(calls).toBe(2);
});
