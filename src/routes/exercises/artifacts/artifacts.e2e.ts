import { expect, test } from '@playwright/test';
import { gotoHydrated } from '../hydration';

test('opens, closes, and reopens an artifact from conversation activity', async ({ page }) => {
	await gotoHydrated(page, '/exercises/artifacts');

	const log = page.getByRole('log', { name: 'Messages' });
	const layout = page.locator('.chat-artifact-layout');

	// Panel starts closed: no panel content, status says so, layout reports
	// closed via its own `data-panel-open` attribute and a single-column grid.
	await expect(page.getByText('No artifact open')).toBeVisible();
	await expect(layout).toHaveAttribute('data-panel-open', 'false');
	await expect(page.getByRole('complementary')).toHaveCount(0);
	await expect
		.poll(() => layout.evaluate((element) => getComputedStyle(element).gridTemplateColumns))
		.toMatch(/^\S+$/);

	// Opening an artifact from a button on an assistant message row (html
	// type). The action bar is hover/focus-revealed (opacity 0, pointer-events
	// none at rest), and it's positioned outside its message wrapper's own
	// box, so a mouse hover at the button's own coordinates never actually
	// lands on a hoverable ancestor — `elementFromPoint` there resolves clean
	// through to `.chat-timeline`. Focusing first exercises the same
	// keyboard-accessible reveal path real keyboard/AT users rely on, and
	// makes the button hit-testable for the click that follows. See message
	// lifecycle exercise notes / upstream friction.
	const openHero = page.getByTestId('open-artifact-html');
	await openHero.focus();
	await openHero.click();

	const panel = page.getByRole('complementary');
	await expect(panel).toBeVisible();
	await expect(layout).toHaveAttribute('data-panel-open', 'true');
	await expect(panel.getByText('Landing Page Hero')).toBeVisible();
	// The layout grid splits into two columns (chat + panel) once open.
	await expect
		.poll(() => layout.evaluate((element) => getComputedStyle(element).gridTemplateColumns))
		.toMatch(/^\S+ \S+$/);

	const heroFrame = panel.locator('iframe.artifact-viewer-html');
	await expect(heroFrame).toBeVisible();
	await expect(
		heroFrame.contentFrame().getByRole('heading', { name: 'Build faster' })
	).toBeVisible();

	// Closing via the panel's own close button hides the panel but keeps the
	// artifact remembered — the layout's grid collapses back to one column.
	await page.getByRole('button', { name: 'Close artifact panel' }).click();
	await expect(panel).toHaveCount(0);
	await expect(layout).toHaveAttribute('data-panel-open', 'false');

	const reopen = page.getByTestId('reopen-artifact');
	await expect(reopen).toHaveText('Reopen "Landing Page Hero"');
	await reopen.click();
	await expect(page.getByRole('complementary').getByText('Landing Page Hero')).toBeVisible();
	await expect(layout).toHaveAttribute('data-panel-open', 'true');

	// Opening an artifact from the tool-call row (svg type): the artifact
	// metadata lives on the folded tool-RESULT message, and Chat resolves it
	// into the visible tool-call row's `ChatRowContext.artifact` (the
	// convention added in chat 0.2.0 — resolved cinder#777/#783).
	const openSvg = page.getByTestId('open-artifact-svg');
	await openSvg.focus();
	await openSvg.click();
	const svgPanel = page.getByRole('complementary');
	await expect(svgPanel.getByText('Company Logo')).toBeVisible();

	// Code artifact renders as a code block, not an iframe.
	const openCode = page.getByTestId('open-artifact-code');
	await openCode.focus();
	await openCode.click();
	const codePanel = page.getByRole('complementary');
	await expect(codePanel.getByText('Pricing Table Source')).toBeVisible();
	await expect(codePanel.locator('pre.artifact-code-block[data-language="svelte"]')).toBeVisible();
	await expect(codePanel.getByText('tiers')).toBeVisible();

	// Mermaid artifact renders through the consumer-supplied `mermaidRenderer`
	// snippet (the extension point added in chat 0.2.0 for cinder#784) rather
	// than the built-in raw-source fallback.
	const openMermaid = page.getByTestId('open-artifact-mermaid');
	await openMermaid.focus();
	await openMermaid.click();
	const mermaidPanel = page.getByRole('complementary');
	await expect(mermaidPanel.getByText('Artifact Cache Flow')).toBeVisible();
	await expect(mermaidPanel.getByTestId('custom-mermaid-renderer')).toContainText(
		'custom renderer: flowchart TD'
	);

	// The chat log itself is unaffected by panel state.
	await expect(log.getByText('Generate a hero section for the landing page.')).toBeVisible();
});
