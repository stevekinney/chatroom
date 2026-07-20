<script lang="ts">
	import {
		Chat,
		appendMessages,
		appendStreamingMessage,
		cancelStreamingMessage,
		createConversation,
		finalizeStreamingMessage,
		updateStreamingMessage,
		type ChatAdapter,
		type ChatAdapterErrorEvent,
		type ConversationHistory,
		type ToolResult
	} from '@lostgradient/chat';
	import { resolve } from '$app/paths';
	import { isJSONValue } from 'conversationalist';
	import { SvelteMap } from 'svelte/reactivity';

	import type { SignedPendingToolApproval } from 'armorer';

	type TextEvent = { type: 'text'; text: string };
	type ToolCallEvent = { type: 'tool_call'; id: string; name: string; arguments: unknown };
	type ToolResultEvent = {
		type: 'tool_result';
		callId: string;
		outcome: ToolResult['outcome'];
		content: unknown;
		error?: ToolResult['error'];
		action?: ToolResult['action'];
		pendingApproval?: SignedPendingToolApproval;
	};
	type StreamEvent = TextEvent | ToolCallEvent | ToolResultEvent;

	const MAX_TOOL_TURNS = 5;

	// Plain `let`: only read via `chat?.method()` calls, never reactively.
	let chat: ReturnType<typeof Chat> | undefined;
	// Plain `let`: reset per user turn, read only inside runTurn's own recursion.
	let turnCount = 0;
	// Plain `let`: server-issued approval descriptors, needed only to resume
	// on approve. Not part of the rendered transcript.
	const pendingApprovals = new SvelteMap<string, SignedPendingToolApproval>();

	let conversation = $state<ConversationHistory>(createConversation({ id: 'chatroom-demo' }));
	let error = $state<string | null>(null);
	let streaming = $state(false);

	function hasUnresolvedApprovals(history: ConversationHistory): boolean {
		return Object.values(history.messages).some(
			(message) =>
				message.role === 'tool-result' && message.toolResult?.outcome === 'action_required'
		);
	}

	function findToolResultMessageId(
		history: ConversationHistory,
		toolCallId: string
	): string | undefined {
		return Object.values(history.messages).find(
			(message) => message.role === 'tool-result' && message.toolResult?.callId === toolCallId
		)?.id;
	}

	function replaceToolResult(
		history: ConversationHistory,
		messageId: string,
		toolResult: ToolResult
	): ConversationHistory {
		const existing = history.messages[messageId];
		if (!existing) return history;
		return {
			...history,
			messages: { ...history.messages, [messageId]: { ...existing, toolResult } },
			updatedAt: new Date().toISOString()
		};
	}

	// `$state.snapshot`'s return type recurses too deeply over
	// ConversationHistory's shape for TS to resolve ("Type instantiation is
	// excessively deep") — the runtime snapshot is exactly what these
	// streaming builders need (a plain object, not a Svelte proxy — passing
	// the proxy through breaks their internal structuredClone), so a single
	// assertion bridges the typing gap.
	// upstream: stevekinney/agent-bureau#245
	function snapshot(): ConversationHistory {
		return $state.snapshot(conversation as unknown) as ConversationHistory;
	}

	async function withStreamingIndicator(run: () => Promise<void>): Promise<void> {
		streaming = true;
		try {
			await run();
		} finally {
			streaming = false;
		}
	}

	async function runTurn(): Promise<void> {
		turnCount += 1;
		if (turnCount > MAX_TOOL_TURNS) {
			error = 'Reached the tool-call limit for this response.';
			return;
		}

		const { conversation: withPlaceholder, messageId } = appendStreamingMessage(
			snapshot(),
			'assistant'
		);
		conversation = withPlaceholder;
		chat?.beginStreaming(messageId);

		let buffer = '';
		let sawToolResult = false;

		try {
			const response = await fetch('/api/chat', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ conversation })
			});

			if (!response.ok || !response.body) {
				throw new Error(await response.text());
			}

			const reader = response.body.getReader();
			const decoder = new TextDecoder();
			let lineBuffer = '';

			for (;;) {
				const { done, value } = await reader.read();
				if (done) break;

				lineBuffer += decoder.decode(value, { stream: true });
				const lines = lineBuffer.split('\n');
				lineBuffer = lines.pop() ?? '';

				for (const line of lines) {
					if (!line) continue;
					const event = JSON.parse(line) as StreamEvent;

					if (event.type === 'text') {
						buffer += event.text;
						conversation = updateStreamingMessage(snapshot(), messageId, buffer);
						chat?.pushToken(event.text);
						continue;
					}

					if (event.type === 'tool_call') {
						if (!isJSONValue(event.arguments)) continue;
						conversation = appendMessages(conversation, {
							role: 'tool-call',
							content: '',
							toolCall: { id: event.id, name: event.name, arguments: event.arguments }
						});
						continue;
					}

					// tool_result
					if (!isJSONValue(event.content)) continue;
					sawToolResult = true;
					if (event.pendingApproval) {
						pendingApprovals.set(event.callId, event.pendingApproval);
					}
					conversation = appendMessages(conversation, {
						role: 'tool-result',
						content: '',
						toolResult: {
							callId: event.callId,
							outcome: event.outcome,
							content: event.content,
							...(event.error ? { error: event.error } : {}),
							...(event.action ? { action: event.action } : {})
						}
					});
				}
			}

			conversation = buffer
				? finalizeStreamingMessage(snapshot(), messageId)
				: cancelStreamingMessage(snapshot(), messageId);
		} catch (cause) {
			conversation = cancelStreamingMessage(snapshot(), messageId);
			throw cause;
		} finally {
			chat?.endStreaming();
		}

		if (sawToolResult && !hasUnresolvedApprovals(conversation)) {
			await runTurn();
		}
	}

	const adapter: ChatAdapter = {
		sendMessage: async (message) => {
			error = null;
			conversation = appendMessages(conversation, message);
			await withStreamingIndicator(async () => {
				turnCount = 0;
				await runTurn();
			});
		},
		approveToolCall: async (toolCallId) => {
			await withStreamingIndicator(async () => {
				const approval = pendingApprovals.get(toolCallId);
				const resultMessageId = findToolResultMessageId(conversation, toolCallId);
				if (!approval || !resultMessageId) return;

				const response = await fetch('/api/chat/resume', {
					method: 'POST',
					headers: { 'Content-Type': 'application/json' },
					body: JSON.stringify({ approval, decision: 'approve' })
				});

				if (!response.ok) {
					error = await response.text();
					return;
				}

				const result = (await response.json()) as ToolResult;
				pendingApprovals.delete(toolCallId);
				conversation = replaceToolResult(conversation, resultMessageId, result);
				await runTurn();
			});
		},
		denyToolCall: async (toolCallId) => {
			await withStreamingIndicator(async () => {
				const resultMessageId = findToolResultMessageId(conversation, toolCallId);
				if (!resultMessageId) return;

				pendingApprovals.delete(toolCallId);
				conversation = replaceToolResult(conversation, resultMessageId, {
					callId: toolCallId,
					outcome: 'error',
					content: null,
					error: {
						code: 'denied',
						category: 'permission',
						retryable: false,
						message: 'The user denied this request.'
					}
				});
				await runTurn();
			});
		}
	};

	function handleAdapterError(event: ChatAdapterErrorEvent): void {
		error = event.error instanceof Error ? event.error.message : 'Something went wrong.';
	}
</script>

<div style="height: 100dvh; display: flex; flex-direction: column;">
	<a href={resolve('/exercises')} style="padding: 0.5rem 1rem;">Exercises</a>
	{#if error}
		<p role="alert" style="padding: 0.5rem 1rem; margin: 0; color: var(--cinder-danger);">
			{error}
		</p>
	{/if}
	<div style="flex: 1; min-height: 0;">
		<Chat
			bind:this={chat}
			id="chatroom-demo-chat"
			{conversation}
			{adapter}
			{streaming}
			onadaptererror={handleAdapterError}
		/>
	</div>
</div>
