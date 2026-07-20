import { expect, test } from '@playwright/test';

test('switching conversations swaps the header and the rendered transcript', async ({ page }) => {
	await page.goto('/exercises/conversation-list');

	// Launch support is seeded as the initial active conversation.
	await expect(page.getByRole('heading', { name: 'Launch support' })).toBeVisible();

	const log = page.getByRole('log', { name: 'Messages' });
	await expect(log.getByText('When do we launch the rocket?')).toBeVisible();
	await expect(log.getByText('We launch the rocket on Friday at 9am.')).toBeVisible();
	await expect(log.getByText('Can you resend the invoice?')).not.toBeVisible();

	// Selecting a different conversation in the list swaps both the header
	// and the Chat transcript.
	await page.getByRole('button', { name: 'Billing question' }).click();

	await expect(page.getByRole('heading', { name: 'Billing question' })).toBeVisible();
	await expect(log.getByText('Can you resend the invoice?')).toBeVisible();
	await expect(log.getByText("Sure, I've resent the invoice to your inbox.")).toBeVisible();

	// The previous conversation's transcript is gone, not just scrolled away.
	await expect(log.getByText('When do we launch the rocket?')).not.toBeVisible();
	await expect(log.getByText('We launch the rocket on Friday at 9am.')).not.toBeVisible();

	// Sending a message appends only to the active conversation.
	const composer = page.getByRole('textbox', { name: 'Message' });
	await composer.fill('What is the total?');
	await page.getByRole('button', { name: 'Send message' }).click();

	await expect(log.getByText('What is the total?', { exact: true })).toBeVisible();
	await expect(log.getByText('You said: What is the total?')).toBeVisible();

	// Switching back to the third seeded conversation confirms the echoed
	// reply above stayed scoped to billing, not bled into onboarding.
	await page.getByRole('button', { name: 'Onboarding walkthrough' }).click();

	await expect(page.getByRole('heading', { name: 'Onboarding walkthrough' })).toBeVisible();
	await expect(log.getByText('How do I invite my team?')).toBeVisible();
	await expect(log.getByText('What is the total?')).not.toBeVisible();

	// Switching back to billing shows the echoed reply persisted.
	await page.getByRole('button', { name: 'Billing question' }).click();
	await expect(log.getByText('You said: What is the total?')).toBeVisible();
});
