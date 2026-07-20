<script lang="ts">
	import '@lostgradient/chat/styles';

	import {
		appendMessages,
		ArtifactViewer,
		ChatArtifactLayout,
		Chat,
		createConversation,
		type ConversationHistory,
		type Message
	} from '@lostgradient/chat';
	import type { ComponentProps } from 'svelte';

	/**
	 * The shape we stash under `message.metadata.artifact` to drive the
	 * "open an artifact from conversation activity" flow. It has to be
	 * assembled by hand — nothing on the conversation side (a tool result, a
	 * message) knows about artifacts at all. `type` is derived from
	 * `ArtifactViewer`'s own prop rather than importing `ArtifactContentType`
	 * directly: that type is defined in the package but not re-exported from
	 * its public entry point — see stevekinney/cinder upstream friction notes.
	 */
	type ArtifactMetadata = {
		type: ComponentProps<typeof ArtifactViewer>['type'];
		title: string;
		content: string;
		language?: string;
	};

	function isArtifactMetadata(value: unknown): value is ArtifactMetadata {
		if (typeof value !== 'object' || value === null) return false;
		const candidate = value as Record<string, unknown>;
		return (
			typeof candidate.type === 'string' &&
			['html', 'svg', 'code', 'mermaid'].includes(candidate.type) &&
			typeof candidate.title === 'string' &&
			typeof candidate.content === 'string'
		);
	}

	function artifactFromMessage(message: Message): ArtifactMetadata | undefined {
		const candidate = message.metadata['artifact'];
		return isArtifactMetadata(candidate) ? candidate : undefined;
	}

	const heroHtml = `<!doctype html><html><body style="font-family: sans-serif; margin: 0; padding: 3rem; background: #f5f3ff; color: #2e1065;"><h1>Build faster</h1><p>A generated hero section, rendered in a sandboxed iframe.</p></body></html>`;

	const logoSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120"><circle cx="60" cy="60" r="50" fill="#7c3aed" /><text x="60" y="68" font-size="28" text-anchor="middle" fill="white" font-family="sans-serif">CR</text></svg>`;

	const pricingTableCode = `<script lang="ts">\n\tconst tiers = ['Starter', 'Team', 'Enterprise'];\n<\u002Fscript>\n\n<ul>\n\t{#each tiers as tier}\n\t\t<li>{tier}</li>\n\t{/each}\n</ul>`;

	const flowMermaid = `flowchart TD\n\tA[Request] --> B{Cache hit?}\n\tB -- yes --> C[Return cached artifact]\n\tB -- no --> D[Generate artifact]\n\tD --> C`;

	/**
	 * Static, deterministic transcript: a user message per artifact, an
	 * assistant text reply carrying `metadata.artifact` directly, and one
	 * tool-call/tool-result pair (the SVG logo) so the "open from a
	 * tool-result" path is exercised via the tool-call's own row — Chat
	 * folds paired tool-result rows into their tool-call's row, so the
	 * artifact metadata has to live on the tool-call message to render a
	 * clickable row at all.
	 */
	function buildConversation(): ConversationHistory {
		let conversation = createConversation({ id: 'artifacts-demo' });

		conversation = appendMessages(
			conversation,
			{ role: 'user', content: 'Generate a hero section for the landing page.' },
			{
				role: 'assistant',
				content: "Here's a hero section artifact — open it to preview the rendered HTML.",
				metadata: {
					artifact: {
						type: 'html',
						title: 'Landing Page Hero',
						content: heroHtml
					} satisfies ArtifactMetadata
				}
			},
			{ role: 'user', content: 'Can you pull up the logo you generated earlier?' },
			{
				role: 'tool-call',
				content: '',
				toolCall: { id: 'call_logo', name: 'fetch_artifact', arguments: { title: 'Company Logo' } },
				metadata: {
					artifact: {
						type: 'svg',
						title: 'Company Logo',
						content: logoSvg
					} satisfies ArtifactMetadata
				}
			},
			{
				role: 'tool-result',
				content: '',
				toolResult: { callId: 'call_logo', outcome: 'success', content: { title: 'Company Logo' } }
			},
			{ role: 'user', content: 'Show me the source for the pricing table component.' },
			{
				role: 'assistant',
				content: "Here's the component source as a code artifact.",
				metadata: {
					artifact: {
						type: 'code',
						title: 'Pricing Table Source',
						content: pricingTableCode,
						language: 'svelte'
					} satisfies ArtifactMetadata
				}
			},
			{ role: 'user', content: 'And a diagram of how artifact generation is cached.' },
			{
				role: 'assistant',
				content: "Here's the flow as a Mermaid diagram artifact.",
				metadata: {
					artifact: {
						type: 'mermaid',
						title: 'Artifact Cache Flow',
						content: flowMermaid
					} satisfies ArtifactMetadata
				}
			}
		);

		return conversation;
	}

	// Plain `const`: this transcript is static for the lifetime of the page —
	// there is no adapter, streaming, or editing that would mutate it.
	const conversation: ConversationHistory = buildConversation();

	// Kept separate from `activeArtifact`: closing the panel clears `panelOpen`
	// but preserves the last-viewed artifact, so "reopen" can restore it
	// without requiring the user to click a message row again.
	let activeArtifact = $state<ArtifactMetadata | undefined>(undefined);
	let panelOpen = $state(false);

	function openArtifact(artifact: ArtifactMetadata): void {
		activeArtifact = artifact;
		panelOpen = true;
	}

	function closePanel(): void {
		panelOpen = false;
	}

	function reopenPanel(): void {
		if (!activeArtifact) return;
		panelOpen = true;
	}
</script>

<div style="height: 100dvh; display: flex; flex-direction: column;">
	<div style="padding: 0.5rem 1rem; border-bottom: 1px solid var(--cinder-border);">
		{#if !panelOpen && activeArtifact}
			<button type="button" data-testid="reopen-artifact" onclick={reopenPanel}>
				Reopen "{activeArtifact.title}"
			</button>
		{:else}
			<span data-testid="panel-status">
				{panelOpen ? 'Artifact panel open' : 'No artifact open'}
			</span>
		{/if}
	</div>

	<div style="flex: 1; min-height: 0;">
		<ChatArtifactLayout
			instanceId="artifacts-demo"
			open={panelOpen}
			panelTitle={activeArtifact?.title}
			onclose={closePanel}
		>
			<Chat id="artifacts-exercise-chat" {conversation}>
				{#snippet messageActions(message: Message)}
					{@const artifact = artifactFromMessage(message)}
					{#if artifact}
						<button
							type="button"
							data-testid="open-artifact-{artifact.type}"
							onclick={() => openArtifact(artifact)}
						>
							View "{artifact.title}"
						</button>
					{/if}
				{/snippet}
			</Chat>

			{#snippet panel()}
				{#if activeArtifact}
					<ArtifactViewer
						type={activeArtifact.type}
						content={activeArtifact.content}
						title={activeArtifact.title}
						language={activeArtifact.language}
					/>
				{/if}
			{/snippet}
		</ChatArtifactLayout>
	</div>
</div>
