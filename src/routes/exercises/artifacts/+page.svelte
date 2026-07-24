<script lang="ts">
	import {
		appendMessages,
		ArtifactViewer,
		Chat,
		ChatArtifactLayout,
		CINDER_ARTIFACT_METADATA_KEY,
		createConversation,
		type ChatArtifact,
		type ChatRowContext,
		type ConversationHistory
	} from '@lostgradient/chat';

	const heroHtml = `<!doctype html><html><body style="font-family: sans-serif; margin: 0; padding: 3rem; background: #f5f3ff; color: #2e1065;"><h1>Build faster</h1><p>A generated hero section, rendered in a sandboxed iframe.</p></body></html>`;

	const logoSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120"><circle cx="60" cy="60" r="50" fill="#7c3aed" /><text x="60" y="68" font-size="28" text-anchor="middle" fill="white" font-family="sans-serif">CR</text></svg>`;

	const pricingTableCode = `<script lang="ts">\n\tconst tiers = ['Starter', 'Team', 'Enterprise'];\n<\u002Fscript>\n\n<ul>\n\t{#each tiers as tier}\n\t\t<li>{tier}</li>\n\t{/each}\n</ul>`;

	const flowMermaid = `flowchart TD\n\tA[Request] --> B{Cache hit?}\n\tB -- yes --> C[Return cached artifact]\n\tB -- no --> D[Generate artifact]\n\tD --> C`;

	/**
	 * Static, deterministic transcript: a user message per artifact, an
	 * assistant text reply carrying `cinder:artifact` metadata directly, and
	 * one tool-call/tool-result pair (the SVG logo) with the artifact
	 * metadata on the tool-RESULT message — Chat folds paired tool-results
	 * into the visible tool-call row and resolves the folded result's
	 * artifact into that row's `ChatRowContext.artifact` (the first-class
	 * convention added in chat 0.2.0).
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
					[CINDER_ARTIFACT_METADATA_KEY]: {
						type: 'html',
						title: 'Landing Page Hero',
						content: heroHtml
					} satisfies ChatArtifact
				}
			},
			{ role: 'user', content: 'Can you pull up the logo you generated earlier?' },
			{
				role: 'tool-call',
				content: '',
				toolCall: { id: 'call_logo', name: 'fetch_artifact', arguments: { title: 'Company Logo' } }
			},
			{
				role: 'tool-result',
				content: '',
				toolResult: { callId: 'call_logo', outcome: 'success', content: { title: 'Company Logo' } },
				metadata: {
					[CINDER_ARTIFACT_METADATA_KEY]: {
						type: 'svg',
						title: 'Company Logo',
						content: logoSvg
					} satisfies ChatArtifact
				}
			},
			{ role: 'user', content: 'Show me the source for the pricing table component.' },
			{
				role: 'assistant',
				content: "Here's the component source as a code artifact.",
				metadata: {
					[CINDER_ARTIFACT_METADATA_KEY]: {
						type: 'code',
						title: 'Pricing Table Source',
						content: pricingTableCode,
						language: 'svelte'
					} satisfies ChatArtifact
				}
			},
			{ role: 'user', content: 'And a diagram of how artifact generation is cached.' },
			{
				role: 'assistant',
				content: "Here's the flow as a Mermaid diagram artifact.",
				metadata: {
					[CINDER_ARTIFACT_METADATA_KEY]: {
						type: 'mermaid',
						title: 'Artifact Cache Flow',
						content: flowMermaid
					} satisfies ChatArtifact
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
	let activeArtifact = $state<ChatArtifact | undefined>(undefined);
	let panelOpen = $state(false);

	function openArtifact(artifact: ChatArtifact): void {
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

{#snippet mermaidRenderer(content: string)}
	<pre data-testid="custom-mermaid-renderer">custom renderer: {content}</pre>
{/snippet}

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
				{#snippet messageActions(context: ChatRowContext)}
					{#if context.artifact}
						{@const artifact = context.artifact}
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
						{mermaidRenderer}
					/>
				{/if}
			{/snippet}
		</ChatArtifactLayout>
	</div>
</div>
