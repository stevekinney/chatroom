<script lang="ts">
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
		type ConversationHistory,
		type JSONValue,
		type Message
	} from '@lostgradient/chat';
	import { SvelteSet } from 'svelte/reactivity';

	// Drives streaming, editing, retrying, and stopping through the SAME
	// adapter and observes what Chat actually guards against versus what a
	// consumer has to guard for itself — the seams called out in the exercise
	// brief: shared internal state (the `conversation` snapshot) mutated from
	// overlapping async operations.

	const SEND_TOKENS = ['Sure, ', 'here ', 'is ', 'a ', 'deterministic ', 'reply.'];
	const RETRY_TOKENS = ['Retried ', 'reply: ', 'the ', 'quarterly ', 'numbers ', 'are ', 'in.'];
	const TOKEN_DELAY_MS = 150;

	function sleep(ms: number): Promise<void> {
		return new Promise((resolve) => setTimeout(resolve, ms));
	}

	function seedConversation(id: string): {
		conversation: ConversationHistory;
		retryTargetId: string;
	} {
		let conversation = createConversation({ id });
		conversation = appendUserMessage(conversation, "What's the weather like today?");
		conversation = appendAssistantMessage(conversation, "It's sunny and 72 degrees.");
		conversation = appendUserMessage(conversation, 'Summarize the quarterly report.');
		conversation = appendAssistantMessage(conversation, 'This reply failed to send.', {
			_deliveryStatus: 'failed'
		});
		const retryTargetId = conversation.ids[conversation.ids.length - 1];
		if (!retryTargetId) throw new Error('Expected a seeded message id.');
		return { conversation, retryTargetId };
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

	const seed = seedConversation('interleaving-demo');
	let conversation = $state<ConversationHistory>(seed.conversation);
	const retryTargetId = seed.retryTargetId;

	let log = $state<string[]>([]);
	let error = $state<string | null>(null);

	// Every stream (a send, or a retry) increments this on start and
	// decrements it on completion/cancellation, so `streaming` stays `true`
	// as long as ANY stream is active — including two overlapping retries of
	// the same message.
	let activeStreamCount = $state(0);
	const streaming = $derived(activeStreamCount > 0);

	// Ids for which `stopGenerating` has been requested. Checked by the
	// token-reveal loops between tokens.
	const stopRequestedIds = new SvelteSet<string>();

	function requestStop(messageId: string): void {
		stopRequestedIds.add(messageId);
	}

	function clearStopRequest(messageId: string): void {
		stopRequestedIds.delete(messageId);
	}

	function snapshot(): ConversationHistory {
		return $state.snapshot(conversation);
	}

	const adapter: ChatAdapter = {
		sendMessage: async (message) => {
			error = null;
			log = [...log, 'sendMessage'];
			conversation = appendMessages(conversation, message);

			const { conversation: withPlaceholder, messageId } = appendStreamingMessage(
				snapshot(),
				'assistant'
			);
			conversation = withPlaceholder;
			activeStreamCount += 1;

			try {
				let buffer = '';
				for (const token of SEND_TOKENS) {
					if (stopRequestedIds.has(messageId)) break;
					await sleep(TOKEN_DELAY_MS);
					if (stopRequestedIds.has(messageId)) break;

					buffer += token;
					conversation = updateStreamingMessage(snapshot(), messageId, buffer);
				}
				conversation = buffer
					? finalizeStreamingMessage(snapshot(), messageId)
					: cancelStreamingMessage(snapshot(), messageId);
			} finally {
				clearStopRequest(messageId);
				activeStreamCount -= 1;
			}
		},

		// Not blocked by an in-flight stream — Chat's `canEdit` derivation never
		// checks `streaming`, so this runs concurrently with any active
		// send/retry loop above. Both write into `conversation` through the
		// same read-current-snapshot-then-write pattern, so a write from one
		// never clobbers a write from the other: each reads the LATEST
		// snapshot at the moment it runs, not a stale closure.
		editMessage: async (event) => {
			log = [...log, `editMessage:${event.messageId}`];
			conversation = replaceMessage(conversation, event.messageId, { content: event.content });
		},

		// PINS ACTUAL CHAT BEHAVIOR: Chat's dispatcher has no re-entrancy guard
		// on `retryMessage` (unlike tool-approval's commit-before-adapter-call
		// guard) — nothing stops a consumer, or a second in-flight call, from
		// invoking this twice for the same message id. The only guard here is
		// UI-level and incidental: clearing `_deliveryStatus` up front unmounts
		// the Retry button, so a SECOND click through the UI can't happen. A
		// second PROGRAMMATIC dispatch (this exercise's "Force retry again"
		// button) is NOT guarded — both loops run concurrently against the
		// same message id.
		retryMessage: async (messageId) => {
			log = [...log, `retryMessage:${messageId}`];
			const target = conversation.messages[messageId];
			if (!target) return;

			clearStopRequest(messageId);
			conversation = replaceMessage(conversation, messageId, {
				metadata: metadataWithoutFailedFlag(target.metadata)
			});
			activeStreamCount += 1;

			try {
				let buffer = '';
				for (const token of RETRY_TOKENS) {
					if (stopRequestedIds.has(messageId)) break;
					await sleep(TOKEN_DELAY_MS);
					if (stopRequestedIds.has(messageId)) break;

					buffer += token;
					conversation = replaceMessage(conversation, messageId, { content: buffer });
				}
				if (stopRequestedIds.has(messageId) && buffer !== RETRY_TOKENS.join('')) {
					const stopped = conversation.messages[messageId];
					conversation = replaceMessage(conversation, messageId, {
						metadata: { ...stopped?.metadata, _deliveryStatus: 'failed' }
					});
				}
			} finally {
				clearStopRequest(messageId);
				activeStreamCount -= 1;
			}
		},

		stopGenerating: async (messageId) => {
			log = [...log, `stopGenerating:${messageId}`];
			requestStop(messageId);
		}
	};

	function handleAdapterError(event: ChatAdapterErrorEvent): void {
		error = event.error instanceof Error ? event.error.message : 'Something went wrong.';
	}

	function forceRetryAgain(): void {
		void adapter.retryMessage?.(retryTargetId);
	}
</script>

<div
	style="height: 100dvh; display: flex; flex-direction: column; gap: 0.75rem; padding: 1rem; box-sizing: border-box;"
>
	{#if error}
		<p
			role="alert"
			data-testid="interleaving-error"
			style="margin: 0; color: var(--cinder-danger);"
		>
			{error}
		</p>
	{/if}
	<div style="flex: 1; min-height: 0; display: flex; gap: 0.75rem;">
		<div style="flex: 2; min-height: 0; display: flex; flex-direction: column;">
			<Chat
				id="interleaving-chat"
				{conversation}
				{adapter}
				{streaming}
				onadaptererror={handleAdapterError}
			/>
		</div>
		<div style="flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.5rem;">
			<button type="button" data-testid="force-retry-again" onclick={forceRetryAgain}>
				Force retry again (bypasses the UI's Retry button)
			</button>
			<ul
				data-testid="interleaving-log"
				style="flex: 1; overflow-y: auto; margin: 0; padding: 0.5rem; font-size: 0.75rem; list-style: none;"
			>
				{#each log as entry, index (index)}
					<li>{entry}</li>
				{/each}
			</ul>
		</div>
	</div>
</div>
