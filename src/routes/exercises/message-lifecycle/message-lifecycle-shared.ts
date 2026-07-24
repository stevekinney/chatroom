import {
	appendAssistantMessage,
	appendStreamingMessage,
	appendUserMessage,
	cancelStreamingMessage,
	createConversation,
	finalizeStreamingMessage,
	updateStreamingMessage,
	type ConversationHistory,
	type JSONValue,
	type Message
} from '@lostgradient/chat';

// Deterministic stand-in for a token stream — no network call, no timers
// beyond a short fixed delay so a Playwright test can reliably interrupt it
// mid-stream with the stop-generating button.
export const STREAM_TOKENS = [
	'Streaming ',
	'a ',
	'deterministic ',
	'reply ',
	'token ',
	'by ',
	'token.'
];
export const STREAM_DELAY_MS = 120;

/** The marker `streamReply` appends when a simulated post-stop token attempt is (wrongly) applied. */
export const LATE_TOKEN_MARKER = 'LATE TOKEN AFTER STOP';

export function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

// Seeds a conversation with one user message and one FAILED assistant
// message (`_deliveryStatus: 'failed'` is the metadata flag `ChatMessage`
// reads to show the "Failed to send" banner + retry button — see
// `chat-message.svelte`'s `isFailed` derivation).
export function seedConversation(id: string): ConversationHistory {
	let conversation = createConversation({ id });
	conversation = appendUserMessage(conversation, 'What is the capital of deterministic testing?');
	conversation = appendAssistantMessage(conversation, 'This reply failed to send.', {
		_deliveryStatus: 'failed'
	});
	return conversation;
}

export function replaceMessage(
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

export function metadataWithoutFailedFlag(
	metadata: Message['metadata']
): Record<string, JSONValue> {
	const next: Record<string, JSONValue> = { ...metadata };
	delete next['_deliveryStatus'];
	return next;
}

export type StreamCallbacks = {
	getSnapshot: () => ConversationHistory;
	setConversation: (next: ConversationHistory) => void;
	setStreaming: (value: boolean) => void;
	shouldStop: () => boolean;
	log: (entry: string) => void;
};

// Shared by both Chat instances: appends a streaming assistant placeholder,
// then reveals `STREAM_TOKENS` one at a time. `shouldStop` is polled between
// tokens so `stopGenerating`/`onstopgenerating` can halt the stream early —
// the assertion a real backend abort would need to satisfy.
//
// After an early stop, it also simulates a backend race: a token arriving
// just after the stream already finalized/cancelled. `updateStreamingMessage`
// (from `conversationalist`) does NOT itself check whether a message is still
// streaming — it clones the message by id regardless of the streaming flag —
// so a caller that reapplied it here unguarded would silently grow a message
// the user already stopped. This guards on `shouldStop()` itself rather than
// trusting the library, and logs which branch ran so a test can assert the
// transcript stayed frozen. upstream: stevekinney/agent-bureau#296
export async function streamReply(callbacks: StreamCallbacks): Promise<void> {
	const { conversation: withPlaceholder, messageId } = appendStreamingMessage(
		callbacks.getSnapshot(),
		'assistant'
	);
	callbacks.setConversation(withPlaceholder);
	callbacks.setStreaming(true);

	let buffer = '';
	let stoppedEarly = false;

	try {
		for (const token of STREAM_TOKENS) {
			if (callbacks.shouldStop()) {
				stoppedEarly = true;
				break;
			}
			await sleep(STREAM_DELAY_MS);
			if (callbacks.shouldStop()) {
				stoppedEarly = true;
				break;
			}

			buffer += token;
			callbacks.setConversation(updateStreamingMessage(callbacks.getSnapshot(), messageId, buffer));
		}

		callbacks.setConversation(
			buffer
				? finalizeStreamingMessage(callbacks.getSnapshot(), messageId)
				: cancelStreamingMessage(callbacks.getSnapshot(), messageId)
		);

		if (stoppedEarly) {
			await sleep(STREAM_DELAY_MS);

			if (callbacks.shouldStop()) {
				callbacks.log('post-stop-token:blocked');
			} else {
				callbacks.setConversation(
					updateStreamingMessage(
						callbacks.getSnapshot(),
						messageId,
						`${buffer}${LATE_TOKEN_MARKER}`
					)
				);
				callbacks.log('post-stop-token:applied');
			}
		}
	} finally {
		callbacks.setStreaming(false);
	}
}
