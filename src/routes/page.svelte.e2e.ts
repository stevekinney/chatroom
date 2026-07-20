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
