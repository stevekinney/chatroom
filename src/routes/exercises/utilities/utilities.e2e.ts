import { expect, test } from '@playwright/test';

test.use({ permissions: ['clipboard-read', 'clipboard-write'] });

test('utility functions render correctly against the seeded conversation', async ({ page }) => {
	await page.goto('/exercises/utilities');

	const rows = page.getByTestId('utilities-message-row');
	await expect(rows).toHaveCount(24);

	const userRow = rows.first();
	await expect(userRow.getByTestId('utilities-role-label')).toHaveText('User');
	await expect(userRow.getByTestId('utilities-format-as-markdown')).toHaveText(
		'What is the weather in **Portland**?'
	);
	await expect(userRow.getByTestId('utilities-get-message-text')).toHaveText(
		'What is the weather in **Portland**?'
	);

	const assistantRow = rows.nth(1);
	await expect(assistantRow.getByTestId('utilities-role-label')).toHaveText('Assistant');
	await expect(assistantRow.getByTestId('utilities-format-as-markdown')).toContainText(
		'Let me check that for you.'
	);

	// The tool-call/tool-result messages carry their payload in `toolCall`/`toolResult`,
	// not `content`, so getMessageText/formatMessageAsMarkdown are empty for them —
	// exercising that these utilities are text-only and don't reach into tool payloads.
	const toolCallRow = rows.nth(2);
	await expect(toolCallRow.getByTestId('utilities-role-label')).toHaveText('Tool Call');
	await expect(toolCallRow.getByTestId('utilities-format-as-markdown')).toHaveText('');

	const toolResultRow = rows.nth(3);
	await expect(toolResultRow.getByTestId('utilities-role-label')).toHaveText('Tool Result');
	await expect(toolResultRow.getByTestId('utilities-get-message-text')).toHaveText('');

	const fullTranscript = page.getByTestId('utilities-messages-to-markdown');
	await expect(fullTranscript).toContainText('**User:**');
	await expect(fullTranscript).toContainText('**Assistant:**');
	await expect(fullTranscript).toContainText('**Tool Call:**');
	await expect(fullTranscript).toContainText('**Tool Result:**');
	await expect(fullTranscript).toContainText('---');
});

test('ConversationExportActions copies the transcript and reports success', async ({ page }) => {
	await page.goto('/exercises/utilities');

	const status = page.getByTestId('utilities-export-status');
	await expect(status).toHaveText('');

	await page.getByRole('button', { name: 'Export conversation' }).click();
	await page.getByRole('menuitem', { name: /Copy as Markdown/ }).click();
	await expect(status).toHaveText('exported: markdown');

	const clipboardText = await page.evaluate(() => navigator.clipboard.readText());
	expect(clipboardText).toContain('**User:**');

	await page.getByRole('button', { name: 'Export conversation' }).click();
	await page.getByRole('menuitem', { name: /Copy as JSON/ }).click();
	await expect(status).toHaveText('exported: json');
});

test('imperative Chat methods: announce, scroll, focus, and composer access', async ({ page }) => {
	await page.goto('/exercises/utilities');

	const chatWrapper = page.getByTestId('utilities-full-chat-wrapper');
	const composer = chatWrapper.getByRole('textbox', { name: 'Message' });

	// announce() writes into Chat's own polite live region.
	await page.getByTestId('utilities-announce').click();
	await expect(page.getByText('Announcement: imperative announce() probe fired.')).toBeAttached();

	// The seeded transcript overflows the 24rem viewport, so scrollToTop/scrollToBottom
	// actually move the anchor rather than being no-ops.
	await expect(page.getByTestId('utilities-at-bottom')).toHaveText('atBottom: true');
	await page.getByTestId('utilities-scroll-top').click();
	await expect(page.getByTestId('utilities-at-bottom')).toHaveText('atBottom: false');
	await page.getByTestId('utilities-scroll-bottom').click();
	await expect(page.getByTestId('utilities-at-bottom')).toHaveText('atBottom: true');

	// focusInput() moves focus to the composer textarea.
	await page.getByTestId('utilities-focus-input').click();
	await expect(composer).toBeFocused();

	// getComposerValue() reads the live composer contents.
	await composer.fill('draft reply text');
	await page.getByTestId('utilities-refresh-composer-value').click();
	await expect(page.getByTestId('utilities-composer-value')).toHaveText(
		'Composer value: "draft reply text"'
	);

	// clearInput() empties the composer; a follow-up getComposerValue() confirms it.
	await page.getByTestId('utilities-clear-input').click();
	await expect(composer).toHaveValue('');
	await expect(page.getByTestId('utilities-composer-value')).toHaveText('Composer value: ""');
});

test('standalone building blocks render and behave correctly without the Chat shell', async ({
	page
}) => {
	await page.goto('/exercises/utilities');

	// ChatDateSeparator with a custom formatter for a deterministic label.
	await expect(page.getByRole('separator', { name: 'Messages from 2024-03-14' })).toBeVisible();

	// ChatMessage, rendered bare, still resolves its own role label and body.
	const userMessage = page.getByTestId('utilities-chat-message-user');
	await expect(userMessage.locator('.chat-message-role')).toHaveText('You');
	await expect(userMessage).toContainText(
		'Standalone ChatMessage, rendered with no Chat container'
	);

	const assistantMessage = page.getByTestId('utilities-chat-message-assistant');
	await expect(assistantMessage.locator('.chat-message-role')).toHaveText('Assistant');
	await expect(assistantMessage.locator('strong')).toHaveText('without');

	// MessageContent renders markdown on its own.
	const messageContent = page.getByTestId('utilities-message-content');
	await expect(messageContent.locator('strong')).toHaveText('Bold');
	await expect(messageContent.locator('em')).toHaveText('italic');
	await expect(messageContent.locator('code')).toHaveText('code span');

	// ToolCallGroup renders a pair built by hand (no Chat/pairToolCallsWithResults)
	// and its own disclosure toggle works standalone.
	const toolCallGroup = page.getByTestId('utilities-tool-call-group');
	await expect(toolCallGroup).toContainText('lookup_order');
	const toggle = toolCallGroup.getByRole('button', {
		name: 'Toggle tool call details for lookup_order'
	});
	await expect(toggle).toHaveAttribute('aria-expanded', 'false');
	await toggle.click();
	await expect(toggle).toHaveAttribute('aria-expanded', 'true');
	await expect(toolCallGroup).toContainText('shipped');

	// ChatInput works as a freestanding composer with its own onsubmit callback.
	const standaloneInput = page.getByTestId('utilities-chat-input');
	const standaloneComposer = standaloneInput.getByRole('textbox', { name: 'Message' });
	await expect(page.getByTestId('utilities-last-submission')).toHaveText('no submission yet');

	await standaloneComposer.fill('hello from a bare ChatInput');
	await standaloneInput.getByRole('button', { name: 'Send message' }).click();

	await expect(page.getByTestId('utilities-last-submission')).toContainText(
		'hello from a bare ChatInput'
	);
	// clearOnSubmit defaults to true.
	await expect(standaloneComposer).toHaveValue('');
});
