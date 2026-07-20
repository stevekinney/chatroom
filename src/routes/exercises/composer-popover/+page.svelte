<script lang="ts">
	import {
		appendAssistantMessage,
		appendUserMessage,
		Chat,
		createConversation,
		type ChatSubmitEvent,
		type ConversationHistory
	} from '@lostgradient/chat';
	import ChatComposerPopover, {
		filterFuzzySubsequence,
		fuzzySubsequenceScore,
		type ChatComposerPopoverSelection
	} from '@lostgradient/chat/composer-popover';

	type SlashCommand = {
		value: string;
		label: string;
		description: string;
		insert: string;
		keywords?: readonly string[];
	};

	const commands: SlashCommand[] = [
		{
			value: 'help',
			label: 'Help',
			description: 'Show available commands',
			insert: '/help ',
			keywords: ['docs', 'support']
		},
		{
			value: 'new-thread',
			label: 'New thread',
			description: 'Start a fresh conversation',
			insert: '/new-thread ',
			keywords: ['reset', 'fresh']
		},
		{
			value: 'toggle-theme',
			label: 'Toggle theme',
			description: 'Switch between light and dark',
			insert: '/toggle-theme ',
			keywords: ['dark', 'light']
		},
		{
			value: 'clear-draft',
			label: 'Clear draft',
			description: 'Empty the composer',
			insert: '/clear-draft ',
			keywords: ['reset', 'empty']
		}
	];

	// Plain `let`: imperative handle, only read via `chat?.method()` calls, never reactively.
	let chat: ReturnType<typeof Chat> | undefined;

	let conversation = $state<ConversationHistory>(
		createConversation({ id: 'composer-popover-exercise' })
	);
	let composerSnapshot = $state('');
	let lastSelection = $state<{ label: string; score: number | null } | null>(null);

	function handleSubmit(event: ChatSubmitEvent): void {
		conversation = appendAssistantMessage(
			appendUserMessage(conversation, event.message.content),
			`You said: ${event.message.content}`
		);
	}

	// Explicit filter rather than relying on ChatComposerPopover's default so the
	// exercise proves it's calling the exported fuzzy-subsequence matcher itself.
	function filterCommands(items: readonly SlashCommand[], query: string): readonly SlashCommand[] {
		return filterFuzzySubsequence(items, query);
	}

	function refreshSnapshot(): void {
		composerSnapshot = chat?.getComposerValue() ?? '';
	}

	// Chat exposes no composer write-back API (`setComposerValue` /
	// `insertAtRange`), so committing a popover selection means reaching into
	// the textarea via `getEditorElement()` and dispatching a synthetic
	// `input` event. upstream: stevekinney/cinder#780
	function handleSelect(selection: ChatComposerPopoverSelection<SlashCommand>): void {
		const editor = chat?.getEditorElement();
		if (!editor) return;

		const current = chat?.getComposerValue() ?? '';
		const { start, end } = selection.range;
		const insertion = selection.item.insert;
		const nextValue = `${current.slice(0, start)}${insertion}${current.slice(end)}`;
		const caret = start + insertion.length;

		editor.value = nextValue;
		editor.dispatchEvent(new Event('input', { bubbles: true }));
		editor.setSelectionRange(caret, caret);

		lastSelection = {
			label: selection.item.label,
			score: fuzzySubsequenceScore(selection.item.label, selection.query)
		};
		refreshSnapshot();
		chat?.focusInput();
	}

	function clearDraft(): void {
		chat?.clearInput();
		refreshSnapshot();
	}
</script>

<div style="height: 100dvh; display: flex; flex-direction: column;">
	<div
		style="padding: 0.5rem 1rem; display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: baseline; border-bottom: 1px solid var(--cinder-border);"
	>
		<button type="button" onclick={clearDraft}>Clear draft</button>
		<button type="button" onclick={refreshSnapshot}>Refresh draft preview</button>
		<span data-testid="draft-preview">Draft: "{composerSnapshot}"</span>
		{#if lastSelection}
			<span data-testid="last-selection">
				Inserted "{lastSelection.label}" (fuzzy score: {lastSelection.score})
			</span>
		{/if}
	</div>
	<div style="flex: 1; min-height: 0;">
		<ChatComposerPopover
			id="composer-popover-exercise-commands"
			items={commands}
			filter={filterCommands}
			onselect={handleSelect}
		>
			{#snippet composer(composerProps)}
				<Chat
					bind:this={chat}
					id="composer-popover-exercise-chat"
					{conversation}
					onsubmit={handleSubmit}
					composerRole={composerProps.composerRole}
					composerAriaExpanded={composerProps.composerAriaExpanded}
					composerAriaControls={composerProps.composerAriaControls}
					composerAriaActiveDescendant={composerProps.composerAriaActiveDescendant}
					composerAriaAutocomplete={composerProps.composerAriaAutocomplete}
					oncomposerinput={composerProps.oncomposerinput}
					oncomposerkeydown={composerProps.oncomposerkeydown}
					oncomposerselectionchange={composerProps.oncomposerselectionchange}
					oncomposerblur={composerProps.oncomposerblur}
				/>
			{/snippet}
		</ChatComposerPopover>
	</div>
</div>
