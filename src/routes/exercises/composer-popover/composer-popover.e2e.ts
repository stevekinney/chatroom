import { expect, test } from '@playwright/test';

test.describe('ChatComposerPopover slash-command menu', () => {
	test('typing "/" opens the menu and Escape dismisses it', async ({ page }) => {
		await page.goto('/exercises/composer-popover');

		const composer = page.getByRole('combobox', { name: 'Message' });
		const menu = page.getByRole('listbox', { name: 'Composer suggestions' });

		await expect(menu).toBeHidden();
		await composer.click();
		await composer.pressSequentially('/');

		await expect(menu).toBeVisible();
		await expect(composer).toHaveAttribute('aria-expanded', 'true');
		await expect(menu.getByRole('option', { name: 'Help, Show available commands' })).toBeVisible();
		await expect(
			menu.getByRole('option', { name: 'New thread, Start a fresh conversation' })
		).toBeVisible();

		await page.keyboard.press('Escape');
		await expect(menu).toBeHidden();
		await expect(composer).toHaveAttribute('aria-expanded', 'false');
	});

	test('arrow keys navigate the menu without sending, Enter inserts the selection', async ({
		page
	}) => {
		await page.goto('/exercises/composer-popover');

		const composer = page.getByRole('combobox', { name: 'Message' });
		const log = page.getByRole('log', { name: 'Messages' });

		await composer.click();
		await composer.pressSequentially('/');

		const help = page.getByRole('option', { name: 'Help, Show available commands' });
		const newThread = page.getByRole('option', {
			name: 'New thread, Start a fresh conversation'
		});

		// The first row is active by default; arrow down moves to the second.
		await expect(help).toHaveAttribute('aria-selected', 'true');
		await page.keyboard.press('ArrowDown');
		await expect(newThread).toHaveAttribute('aria-selected', 'true');
		await expect(help).toHaveAttribute('aria-selected', 'false');

		// Navigating never submits — the message log stays empty and the
		// composer keeps focus with the raw "/" still in place.
		await expect(log.locator('[data-role]')).toHaveCount(0);
		await expect(composer).toHaveValue('/');

		await page.keyboard.press('ArrowUp');
		await expect(help).toHaveAttribute('aria-selected', 'true');

		await page.keyboard.press('Enter');

		// Enter inserted the active row's text instead of sending the message.
		await expect(log.locator('[data-role]')).toHaveCount(0);
		await expect(composer).toHaveValue('/help ');
		await expect(page.getByTestId('last-selection')).toHaveText(/Inserted "Help"/);
		await expect(page.getByRole('listbox', { name: 'Composer suggestions' })).toBeHidden();

		// The inserted command behaves like ordinary composer text: it submits
		// normally through the regular send flow, proving the popover only
		// intercepted Enter while the menu was open.
		await composer.pressSequentially('me');
		await page.getByRole('button', { name: 'Send message' }).click();
		await expect(log.getByText('/help me', { exact: true })).toBeVisible();
		await expect(log.getByText('You said: /help me')).toBeVisible();
	});

	test('fuzzy filtering narrows the menu via filterFuzzySubsequence', async ({ page }) => {
		await page.goto('/exercises/composer-popover');

		const composer = page.getByRole('combobox', { name: 'Message' });
		const menu = page.getByRole('listbox', { name: 'Composer suggestions' });

		await composer.click();
		await composer.pressSequentially('/cd');

		await expect(menu.getByRole('option')).toHaveCount(1);
		await expect(
			menu.getByRole('option', { name: 'Clear draft, Empty the composer' })
		).toBeVisible();
	});

	test('empty query shows no matches for an unmatched subsequence', async ({ page }) => {
		await page.goto('/exercises/composer-popover');

		const composer = page.getByRole('combobox', { name: 'Message' });
		const menu = page.getByRole('listbox', { name: 'Composer suggestions' });

		await composer.click();
		await composer.pressSequentially('/zzz');

		// The `role="listbox"` element itself renders with zero options and zero
		// height when nothing matches — the "No suggestions" copy lives in a
		// sibling `.cinder-command-menu__empty` element, not inside the listbox.
		// That makes the listbox a legitimate zero-size element by CSS geometry
		// (Playwright's `toBeVisible()` treats it as hidden), even though the
		// popover is genuinely open and showing content to the user. Assert on
		// attachment plus the actual visible content rather than the listbox's
		// own geometry. See stevekinney/cinder upstream friction notes.
		await expect(menu).toBeAttached();
		await expect(menu.getByRole('option')).toHaveCount(0);
		await expect(page.getByText('No suggestions')).toBeVisible();
	});

	test('clearInput and getComposerValue drive the draft preview imperatively', async ({ page }) => {
		await page.goto('/exercises/composer-popover');

		const composer = page.getByRole('combobox', { name: 'Message' });
		const preview = page.getByTestId('draft-preview');

		await expect(preview).toHaveText('Draft: ""');

		await composer.click();
		await composer.pressSequentially('hello there');
		await page.getByRole('button', { name: 'Refresh draft preview' }).click();
		await expect(preview).toHaveText('Draft: "hello there"');

		await page.getByRole('button', { name: 'Clear draft' }).click();
		await expect(composer).toHaveValue('');
		await expect(preview).toHaveText('Draft: ""');
	});
});
