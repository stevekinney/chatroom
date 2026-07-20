<script lang="ts">
	import '@lostgradient/chat/styles';

	import {
		appendMessages,
		appendStreamingMessage,
		Chat,
		createConversation,
		finalizeStreamingMessage,
		updateStreamingMessage,
		type ChatSubmitEvent,
		type ConversationHistory,
		type JSONValue,
		type Message
	} from '@lostgradient/chat';

	// `StepInfo` (the type `ChatProps.messageSteps` is declared in terms of) is
	// not re-exported from `@lostgradient/chat`'s public entry point — only from
	// an internal `./components/chat/utilities/types.js` path. Reconstructed
	// locally rather than importing a private subpath. See friction notes.
	type StepStatus = 'pending' | 'running' | 'done' | 'error';
	type StepInfo = { title: string; content: string; status: StepStatus };

	/**
	 * A per-message override, keyed by message id, used to exercise the
	 * `messageReasoning`/`messageSteps`/`messageSuggestions` callback path.
	 * Messages NOT present here fall through to Chat's own
	 * `message.metadata['cinder:*']` fallback.
	 */
	type MessageOverride = {
		reasoning?: string;
		steps?: StepInfo[];
		suggestions?: string[];
	};

	type ScriptedTurn = {
		reply: string;
		/** Turn 0: demonstrates the `metadata['cinder:*']` fallback path. */
		metadata?: Record<string, JSONValue>;
		/** Turn 1: demonstrates the `messageReasoning`/`messageSteps`/`messageSuggestions` callback override path. */
		override?: MessageOverride;
	};

	const script: ScriptedTurn[] = [
		{
			reply:
				'Quantum entanglement is a phenomenon where two particles become correlated so that measuring one instantly tells you about the other, no matter the distance between them.',
			metadata: {
				'cinder:reasoning':
					'Recall the EPR paradox and Bell inequality, then simplify without the full quantum-mechanical formalism.',
				'cinder:steps': [
					{
						title: 'Recall physics',
						content: 'EPR paradox and Bell inequality basics.',
						status: 'done'
					},
					{ title: 'Simplify', content: 'Draft a plain-language explanation.', status: 'done' }
				] satisfies StepInfo[],
				'cinder:suggestions': ['Explain superposition', "What is Bell's theorem?"]
			}
		},
		{
			reply:
				'Superposition is the idea that a quantum system can exist in multiple states at once until it is measured, at which point it collapses to one outcome.',
			override: {
				reasoning:
					'Override reasoning: contrast superposition with entanglement using a coin-flip analogy.',
				steps: [
					{
						title: 'Contrast concepts',
						content: 'Compare entanglement with superposition.',
						status: 'done'
					}
				],
				suggestions: ['Explain wave-particle duality']
			}
		}
	];

	const fallbackReply = "Noted — is there anything else you'd like to explore?";
	const starterPrompts = ['Explain quantum entanglement', 'What is superposition?'];

	function delay(ms: number): Promise<void> {
		return new Promise((resolve) => setTimeout(resolve, ms));
	}

	function countUserMessages(history: ConversationHistory): number {
		return Object.values(history.messages).filter((message) => message.role === 'user').length;
	}

	let chat: ReturnType<typeof Chat> | undefined;
	let conversation = $state<ConversationHistory>(
		createConversation({ id: 'assistant-metadata-demo' })
	);
	let streaming = $state(false);
	let overrides = $state<Record<string, MessageOverride>>({});
	// Plain `let`: read only inside `handleSuggestionSelect`, never reactively.
	// `Chat` does NOT clear a message's suggestion chips on its own when one is
	// selected (see friction notes) — the consumer is expected to suppress them,
	// which requires knowing which message they belonged to.
	let lastAssistantMessageId: string | undefined;

	function snapshot(): ConversationHistory {
		return $state.snapshot(conversation as unknown) as ConversationHistory;
	}

	async function submit(content: string): Promise<void> {
		const text = content.trim();
		if (!text) return;

		const turnIndex = countUserMessages(conversation);
		conversation = appendMessages(conversation, { role: 'user', content: text });

		streaming = true;
		// Streaming is `true` but no placeholder message exists yet, so Chat
		// shows the "Thinking…" typing indicator (via `streamingStatus`)
		// instead of an empty message row.
		await delay(700);

		const { conversation: withPlaceholder, messageId } = appendStreamingMessage(
			snapshot(),
			'assistant'
		);
		conversation = withPlaceholder;
		chat?.beginStreaming(messageId);

		const turn = script[turnIndex];
		const replyText = turn?.reply ?? fallbackReply;
		if (turn?.override) {
			overrides = { ...overrides, [messageId]: turn.override };
		}

		let buffer = '';
		const words = replyText.split(' ');
		for (const [index, word] of words.entries()) {
			const chunk = index === 0 ? word : ` ${word}`;
			buffer += chunk;
			conversation = updateStreamingMessage(snapshot(), messageId, buffer);
			chat?.pushToken(chunk);
			await delay(25);
		}

		conversation = finalizeStreamingMessage(
			snapshot(),
			messageId,
			turn?.metadata ? { metadata: turn.metadata } : undefined
		);
		chat?.endStreaming();
		streaming = false;
		lastAssistantMessageId = messageId;
	}

	function handleSubmit(event: ChatSubmitEvent): void {
		void submit(typeof event.message.content === 'string' ? event.message.content : '');
	}

	function handleSuggestionSelect(label: string): void {
		// Suppress the suggestion chips on the message the chip came from —
		// otherwise they persist under that message row indefinitely (Chat
		// itself does not clear them; see the comment on `lastAssistantMessageId`).
		if (lastAssistantMessageId) {
			overrides = {
				...overrides,
				[lastAssistantMessageId]: { ...overrides[lastAssistantMessageId], suggestions: [] }
			};
		}
		void submit(label);
	}

	function messageReasoning(message: Message): string | undefined {
		return overrides[message.id]?.reasoning;
	}

	function messageSteps(message: Message): StepInfo[] | undefined {
		return overrides[message.id]?.steps;
	}

	function messageSuggestions(message: Message): string[] | undefined {
		return overrides[message.id]?.suggestions;
	}
</script>

<div style="height: 100dvh; display: flex; flex-direction: column;">
	<div style="flex: 1; min-height: 0;">
		<Chat
			bind:this={chat}
			id="assistant-metadata-exercise-chat"
			{conversation}
			{streaming}
			streamingStatus="Thinking…"
			emptyPrompts={starterPrompts}
			onsubmit={handleSubmit}
			{messageReasoning}
			{messageSteps}
			{messageSuggestions}
			onsuggestionselect={handleSuggestionSelect}
		/>
	</div>
</div>
