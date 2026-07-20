import { expect, test } from '@playwright/test';

// A valid, tiny (1x1 transparent) PNG so `deriveAttachmentKind` classifies it
// as `'image'` and the composer accepts it under the default `image/*` rule.
const TINY_PNG_BASE64 =
	'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

const FILE_PICKER = '#chatroom-attachments-chat-input-file-picker';
const CHAT_CONTAINER = '#chatroom-attachments-chat';

test('composer file attachment: add, preview, submit, and render via MessageAttachments', async ({
	page
}) => {
	await page.goto('/exercises/attachments');

	const filePicker = page.locator(FILE_PICKER);

	// onattachmentadd fired, and the attachment reached 'ready' synchronously
	// (images skip the async text-read path code attachments take). Retried
	// via `toPass()`: this is the page's first interaction, and under heavy
	// parallel test load SvelteKit's hydration can still be attaching event
	// listeners when `setInputFiles` dispatches its change event, so the
	// event is silently lost rather than slow. The file is only re-set when
	// the event hasn't landed yet, so a retry can't double-fire it.
	const events = page.getByTestId('attachment-events');
	const addedEvent = events.getByText('added: tiny.png (image, ready)');
	await expect(async () => {
		if ((await addedEvent.count()) === 0) {
			await filePicker.setInputFiles({
				name: 'tiny.png',
				mimeType: 'image/png',
				buffer: Buffer.from(TINY_PNG_BASE64, 'base64')
			});
		}
		await expect(addedEvent).toBeVisible({ timeout: 1000 });
	}).toPass();

	// ChatAttachmentPreview is rendered inline in the composer for the pending
	// attachment. For an image attachment it renders only an <img alt={name}>
	// (the filename <span> is the non-image branch), so assert on that image's
	// accessible name rather than searching for filename text.
	const attachmentList = page.getByRole('list', { name: 'Attached files' });
	await expect(attachmentList.getByRole('img', { name: 'tiny.png' })).toBeVisible();

	await page.getByRole('textbox', { name: 'Message' }).fill('Here is a picture');
	await page.getByRole('button', { name: 'Send message' }).click();

	const log = page.getByRole('log', { name: 'Messages' });
	await expect(log.getByText('Here is a picture')).toBeVisible();
	await expect(log.getByText('Received 1 attachment(s): tiny.png (image).')).toBeVisible();

	// The submitted attachment was serialized (serializeChatAttachments) into an
	// ImageContent part, appended to the transcript, and rendered by the
	// standalone MessageAttachments gallery as a real <img>.
	const gallery = page.getByTestId('attachment-gallery');
	await expect(gallery.locator('img')).toHaveCount(1);

	// The composer's own attachment list is cleared after a successful submit.
	await expect(attachmentList).toHaveCount(0);
});

test('composer file attachment: remove before submit fires onattachmentremove', async ({
	page
}) => {
	await page.goto('/exercises/attachments');

	// First interaction on the page — see the `toPass()` note in the test
	// above for why the file set is retried idempotently.
	const filePicker = page.locator(FILE_PICKER);
	const events = page.getByTestId('attachment-events');
	const addedEvent = events.getByText('added: removable.png (image, ready)');
	await expect(async () => {
		if ((await addedEvent.count()) === 0) {
			await filePicker.setInputFiles({
				name: 'removable.png',
				mimeType: 'image/png',
				buffer: Buffer.from(TINY_PNG_BASE64, 'base64')
			});
		}
		await expect(addedEvent).toBeVisible({ timeout: 1000 });
	}).toPass();

	await page.getByRole('button', { name: 'Remove removable.png' }).click();

	await expect(events.getByText('removed: removable.png (image)')).toBeVisible();
	await expect(page.getByRole('list', { name: 'Attached files' })).toHaveCount(0);
});

test('composer file attachment: rejected file type fires onattachmentfailure', async ({ page }) => {
	await page.goto('/exercises/attachments');

	// video/* is not in ChatInput's default acceptedTypes list, so this is
	// rejected deterministically before a ChatAttachment is ever built. First
	// interaction on the page — see the `toPass()` note in the first test in
	// this file for why the file set is retried idempotently.
	const filePicker = page.locator(FILE_PICKER);
	const events = page.getByTestId('attachment-events');
	const failedEvent = events.getByText(
		'failed: clip.mp4 (document) — Invalid file type: video/mp4.',
		{ exact: false }
	);
	await expect(async () => {
		if ((await failedEvent.count()) === 0) {
			await filePicker.setInputFiles({
				name: 'clip.mp4',
				mimeType: 'video/mp4',
				buffer: Buffer.from('not a real video', 'utf-8')
			});
		}
		await expect(failedEvent).toBeVisible({ timeout: 1000 });
	}).toPass();
});

test('drag-and-drop onto the chat surface adds an attachment', async ({ page }) => {
	await page.goto('/exercises/attachments');

	async function dispatchDrop(): Promise<void> {
		await page.evaluate(
			async ({ containerSelector, base64, name, mimeType }) => {
				const binary = atob(base64);
				const bytes = new Uint8Array(binary.length);
				for (let index = 0; index < binary.length; index += 1) {
					bytes[index] = binary.charCodeAt(index);
				}
				const file = new File([bytes], name, { type: mimeType });
				const dataTransfer = new DataTransfer();
				dataTransfer.items.add(file);

				const container = document.querySelector(containerSelector);
				if (!container) throw new Error(`Container not found: ${containerSelector}`);

				container.dispatchEvent(
					new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer })
				);
				container.dispatchEvent(
					new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer })
				);
			},
			{
				containerSelector: CHAT_CONTAINER,
				base64: TINY_PNG_BASE64,
				name: 'dropped.png',
				mimeType: 'image/png'
			}
		);
	}

	// First interaction on the page — see the `toPass()` note in the first
	// test in this file for why the drop is retried idempotently.
	const events = page.getByTestId('attachment-events');
	const addedEvent = events.getByText('added: dropped.png (image, ready)');
	await expect(async () => {
		if ((await addedEvent.count()) === 0) await dispatchDrop();
		await expect(addedEvent).toBeVisible({ timeout: 1000 });
	}).toPass();
});
