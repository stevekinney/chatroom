<script lang="ts">
	import '@lostgradient/chat/styles';

	import {
		appendAssistantMessage,
		appendMessages,
		appendStreamingMessage,
		appendUserMessage,
		cancelStreamingMessage,
		Chat,
		createConversation,
		finalizeStreamingMessage,
		updateStreamingMessage,
		type ChatAdapter,
		type ChatAdapterErrorEvent,
		type ChatStopGeneratingEvent,
		type ChatSubmitEvent,
		type ConversationHistory,
		type JSONValue,
		type Message
	} from '@lostgradient/chat';

	// Deterministic stand-in for a token stream — no network call, no timers
	// beyond a short fixed delay so a Playwright test can reliably interrupt it
	// mid-stream with the stop-generating button.
	const STREAM_TOKENS = ['Streaming ', 'a ', 'deterministic ', 'reply ', 'token ', 'by ', 'token.'];
	const STREAM_DELAY_MS = 120;

	function sleep(ms: number): Promise<void> {
		return new Promise((resolve) => setTimeout(resolve, ms));
	}

	// Seeds a conversation with one user message and one FAILED assistant
	// message (`_deliveryStatus: 'failed'` is the metadata flag `ChatMessage`
	// reads to show the "Failed to send" banner + retry button — see
	// `chat-message.svelte`'s `isFailed` derivation).
	function seedConversation(id: string): ConversationHistory {
		let conversation = createConversation({ id });
		conversation = appendUserMessage(conversation, 'What is the capital of deterministic testing?');
		conversation = appendAssistantMessage(conversation, 'This reply failed to send.', {
			_deliveryStatus: 'failed'
		});
		return conversation;
	}

	function replaceMessage(
		history: ConversationHistory,
		messageId: string,
		updates: Partial<Pick<Message, 'content' | 'metadata'>>
	): ConversationHistory {
		const existing = history.messages[messageId];
		if (!existing) return history;

		return {
			...history,
			messages: { ...history.messages, [messageId]: { ...existing, ...updates } },
			updatedAt: new Date().toISOString()
		};
	}

	function metadataWithoutFailedFlag(metadata: Message['metadata']): Record<string, JSONValue> {
		const next: Record<string, JSONValue> = { ...metadata };
		delete next['_deliveryStatus'];
		return next;
	}

	type StreamCallbacks = {
		getSnapshot: () => ConversationHistory;
		setConversation: (next: ConversationHistory) => void;
		setStreaming: (value: boolean) => void;
		shouldStop: () => boolean;
	};

	// Shared by both Chat instances below: appends a streaming assistant
	// placeholder, then reveals `STREAM_TOKENS` one at a time. `shouldStop` is
	// polled between tokens so `stopGenerating`/`onstopgenerating` can halt the
	// stream early — the assertion a real backend abort would need to satisfy.
	async function streamReply(callbacks: StreamCallbacks): Promise<void> {
		const { conversation: withPlaceholder, messageId } = appendStreamingMessage(
			callbacks.getSnapshot(),
			'assistant'
		);
		callbacks.setConversation(withPlaceholder);
		callbacks.setStreaming(true);

		let buffer = '';

		try {
			for (const token of STREAM_TOKENS) {
				if (callbacks.shouldStop()) break;
				await sleep(STREAM_DELAY_MS);
				if (callbacks.shouldStop()) break;

				buffer += token;
				callbacks.setConversation(
					updateStreamingMessage(callbacks.getSnapshot(), messageId, buffer)
				);
			}

			callbacks.setConversation(
				buffer
					? finalizeStreamingMessage(callbacks.getSnapshot(), messageId)
					: cancelStreamingMessage(callbacks.getSnapshot(), messageId)
			);
		} finally {
			callbacks.setStreaming(false);
		}
	}

	// --- Instance A: driven entirely through a ChatAdapter -------------------

	let conversationA = $state<ConversationHistory>(seedConversation('message-lifecycle-adapter'));
	let streamingA = $state(false);
	let errorA = $state<string | null>(null);
	let logA = $state<string[]>([]);
	let stopRequestedA = false;

	function snapshotA(): ConversationHistory {
		return $state.snapshot(conversationA as unknown) as ConversationHistory;
	}

	const adapter: ChatAdapter = {
		sendMessage: async (message) => {
			errorA = null;
			logA = [...logA, 'sendMessage'];
			conversationA = appendMessages(conversationA, message);
			stopRequestedA = false;
			await streamReply({
				getSnapshot: snapshotA,
				setConversation: (next) => (conversationA = next),
				setStreaming: (value) => (streamingA = value),
				shouldStop: () => stopRequestedA
			});
		},
		retryMessage: async (messageId) => {
			logA = [...logA, `retryMessage:${messageId}`];
			const target = conversationA.messages[messageId];
			if (!target) return;

			conversationA = replaceMessage(conversationA, messageId, {
				content: 'Retried reply: the deterministic fact arrived on retry.',
				metadata: metadataWithoutFailedFlag(target.metadata)
			});
		},
		editMessage: async (event) => {
			logA = [...logA, `editMessage:${event.messageId}:${event.content}`];
			conversationA = replaceMessage(conversationA, event.messageId, { content: event.content });
		},
		stopGenerating: async (messageId) => {
			logA = [...logA, `stopGenerating:${messageId}`];
			stopRequestedA = true;
		}
	};

	function handleAdapterError(event: ChatAdapterErrorEvent): void {
		errorA = event.error instanceof Error ? event.error.message : 'Something went wrong.';
	}

	// --- Instance B: plain onsubmit / onretry / onedit / onstopgenerating ----
	// No `adapter` prop at all — proves Chat works purely off callback props.

	let conversationB = $state<ConversationHistory>(seedConversation('message-lifecycle-plain'));
	let streamingB = $state(false);
	let errorB = $state<string | null>(null);
	let logB = $state<string[]>([]);
	let stopRequestedB = false;

	function snapshotB(): ConversationHistory {
		return $state.snapshot(conversationB as unknown) as ConversationHistory;
	}

	function handleSubmitB(event: ChatSubmitEvent): void {
		errorB = null;
		logB = [...logB, 'onsubmit'];
		conversationB = appendMessages(conversationB, event.message);
		stopRequestedB = false;
		void streamReply({
			getSnapshot: snapshotB,
			setConversation: (next) => (conversationB = next),
			setStreaming: (value) => (streamingB = value),
			shouldStop: () => stopRequestedB
		});
	}

	function handleRetryB(messageId: string): void {
		logB = [...logB, `onretry:${messageId}`];
		const target = conversationB.messages[messageId];
		if (!target) return;

		conversationB = replaceMessage(conversationB, messageId, {
			content: 'Retried via plain callback: the deterministic fact arrived on retry.',
			metadata: metadataWithoutFailedFlag(target.metadata)
		});
	}

	function handleEditB(event: { messageId: string; content: string }): void {
		logB = [...logB, `onedit:${event.messageId}:${event.content}`];
		conversationB = replaceMessage(conversationB, event.messageId, { content: event.content });
	}

	function handleStopGeneratingB(event: ChatStopGeneratingEvent): void {
		logB = [...logB, `onstopgenerating:${event.messageId}`];
		stopRequestedB = true;
	}
</script>

<div
	style="height: 100dvh; display: flex; flex-direction: column; gap: 1rem; padding: 1rem; box-sizing: border-box;"
>
	<section style="flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 0.5rem;">
		<h2 style="margin: 0;">Adapter-driven (retryMessage / editMessage / stopGenerating)</h2>
		{#if errorA}
			<p role="alert" data-testid="adapter-error" style="margin: 0; color: var(--cinder-danger);">
				{errorA}
			</p>
		{/if}
		<div style="flex: 1; min-height: 0; display: flex; gap: 0.5rem;">
			<div style="flex: 2; min-height: 0; display: flex; flex-direction: column;">
				<Chat
					id="message-lifecycle-adapter-chat"
					conversation={conversationA}
					{adapter}
					streaming={streamingA}
					onadaptererror={handleAdapterError}
				/>
			</div>
			<ul
				data-testid="adapter-log"
				style="flex: 1; min-width: 0; overflow-y: auto; margin: 0; padding: 0.5rem; font-size: 0.75rem; list-style: none;"
			>
				{#each logA as entry, index (index)}
					<li>{entry}</li>
				{/each}
			</ul>
		</div>
	</section>

	<section style="flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 0.5rem;">
		<h2 style="margin: 0;">Callback-only (no adapter)</h2>
		{#if errorB}
			<p role="alert" data-testid="plain-error" style="margin: 0; color: var(--cinder-danger);">
				{errorB}
			</p>
		{/if}
		<div style="flex: 1; min-height: 0; display: flex; gap: 0.5rem;">
			<div style="flex: 2; min-height: 0; display: flex; flex-direction: column;">
				<Chat
					id="message-lifecycle-plain-chat"
					conversation={conversationB}
					streaming={streamingB}
					onsubmit={handleSubmitB}
					onretry={handleRetryB}
					onedit={handleEditB}
					onstopgenerating={handleStopGeneratingB}
				/>
			</div>
			<ul
				data-testid="plain-log"
				style="flex: 1; min-width: 0; overflow-y: auto; margin: 0; padding: 0.5rem; font-size: 0.75rem; list-style: none;"
			>
				{#each logB as entry, index (index)}
					<li>{entry}</li>
				{/each}
			</ul>
		</div>
	</section>
</div>
