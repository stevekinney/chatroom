<script lang="ts">
	import {
		appendAssistantMessage,
		appendUserMessage,
		Chat,
		createConversation,
		type ChatSubmitEvent,
		type ConversationHistory
	} from '@lostgradient/chat';
	import {
		ChatConversationList,
		conversationSummaryTimestamp,
		deriveConversationSummary
	} from '@lostgradient/chat/conversation-list';
	import { ChatConversationHeader } from '@lostgradient/chat/conversation-header';

	/**
	 * Seeds three fixed conversations so the exercise is deterministic: no
	 * network calls, no clock-dependent ordering beyond what's baked in here.
	 */
	function seedConversations(): Record<string, ConversationHistory> {
		let launch = createConversation({ id: 'launch', title: 'Launch support' });
		launch = appendUserMessage(launch, 'When do we launch the rocket?');
		launch = appendAssistantMessage(launch, 'We launch the rocket on Friday at 9am.');

		let billing = createConversation({ id: 'billing', title: 'Billing question' });
		billing = appendUserMessage(billing, 'Can you resend the invoice?');
		billing = appendAssistantMessage(billing, "Sure, I've resent the invoice to your inbox.");

		let onboarding = createConversation({ id: 'onboarding', title: 'Onboarding walkthrough' });
		onboarding = appendUserMessage(onboarding, 'How do I invite my team?');
		onboarding = appendAssistantMessage(
			onboarding,
			'Go to Settings, then Team, then Invite Members.'
		);

		return { launch, billing, onboarding };
	}

	let conversations = $state<Record<string, ConversationHistory>>(seedConversations());
	let activeConversationId = $state('launch');

	const summaries = $derived(
		Object.values(conversations)
			.map(deriveConversationSummary)
			.sort((a, b) => conversationSummaryTimestamp(b) - conversationSummaryTimestamp(a))
	);
	const activeConversation = $derived(conversations[activeConversationId]);

	function selectConversation(conversationId: string): void {
		activeConversationId = conversationId;
	}

	// Deterministic stand-in for a backend: echoes the user's message back as
	// the assistant reply, scoped to whichever conversation is active. `onsubmit`
	// hands back the raw message (mirroring the adapter's `sendMessage`
	// contract) — the consumer owns appending it to the transcript.
	function handleSubmit(event: ChatSubmitEvent): void {
		const conversationId = activeConversationId;
		const content = event.message.content;
		let next = appendUserMessage(conversations[conversationId], content);
		next = appendAssistantMessage(
			next,
			typeof content === 'string' ? `You said: ${content}` : 'Got it.'
		);
		conversations = { ...conversations, [conversationId]: next };
	}
</script>

<div style="height: 100dvh; display: flex;">
	<div style="width: 20rem; border-right: 1px solid var(--cinder-border); overflow-y: auto;">
		<ChatConversationList
			conversations={summaries}
			{activeConversationId}
			onselectconversation={selectConversation}
		/>
	</div>
	<div style="flex: 1; min-height: 0; display: flex; flex-direction: column;">
		{#key activeConversationId}
			<Chat
				id="conversation-list-exercise-chat"
				conversation={activeConversation}
				onsubmit={handleSubmit}
			>
				{#snippet header()}
					<ChatConversationHeader conversation={activeConversation} showExportActions={false} />
				{/snippet}
			</Chat>
		{/key}
	</div>
</div>
