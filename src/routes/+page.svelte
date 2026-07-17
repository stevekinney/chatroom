<script lang="ts">
	import '@lostgradient/cinder/chat/styles';

	import {
		Chat,
		appendMessages,
		createConversation,
		getMessageText,
		type ChatAdapter,
		type ChatAdapterErrorEvent,
		type ConversationHistory,
		type Message,
		type ToolResult
	} from '@lostgradient/cinder/chat';
	// upstream: stevekinney/cinder#753 — drop the direct conversationalist import once
	// Chat re-exports what we need.
	import { isJSONValue } from 'conversationalist';
	import {
		appendStreamingMessage,
		cancelStreamingMessage,
		finalizeStreamingMessage,
		updateStreamingMessage
	} from 'conversationalist/streaming';

	import { getTool } from '$lib/tools';

	type AnthropicTextBlock = { type: 'text'; text: string };
	type AnthropicToolUseBlock = { type: 'tool_use'; id: string; name: string; input: unknown };
	type AnthropicToolResultBlock = {
		type: 'tool_result';
		tool_use_id: string;
		content: string;
		is_error?: boolean;
	};
	type AnthropicMessage =
		| { role: 'user'; content: (AnthropicTextBlock | AnthropicToolResultBlock)[] }
		| { role: 'assistant'; content: (AnthropicTextBlock | AnthropicToolUseBlock)[] };

	type TextEvent = { type: 'text'; text: string };
	type ToolUseEvent = { type: 'tool_use'; id: string; name: string; input: unknown };
	type StreamEvent = TextEvent | ToolUseEvent;

	const MAX_TOOL_TURNS = 5;

	// Plain `let`: only read via `chat?.method()` calls, never reactively.
	let chat: ReturnType<typeof Chat> | undefined;
	// Plain `let`: reset per user turn, read only inside runTurn's own recursion.
	let turnCount = 0;

	let conversation = $state<ConversationHistory>(createConversation({ id: 'chatroom-demo' }));
	let error = $state<string | null>(null);
	let streaming = $state(false);

	function toAnthropicHistory(history: ConversationHistory): AnthropicMessage[] {
		const result: AnthropicMessage[] = [];
		let pendingAssistant: (AnthropicTextBlock | AnthropicToolUseBlock)[] = [];

		function flushAssistant(): void {
			if (pendingAssistant.length === 0) return;
			result.push({ role: 'assistant', content: pendingAssistant });
			pendingAssistant = [];
		}

		for (const id of history.ids) {
			const message = history.messages[id];
			if (!message || message.hidden) continue;

			if (message.role === 'user') {
				flushAssistant();
				result.push({ role: 'user', content: [{ type: 'text', text: getMessageText(message) }] });
				continue;
			}

			if (message.role === 'assistant') {
				const text = getMessageText(message);
				if (text) pendingAssistant.push({ type: 'text', text });
				continue;
			}

			if (message.role === 'tool-call' && message.toolCall) {
				pendingAssistant.push({
					type: 'tool_use',
					id: message.toolCall.id,
					name: message.toolCall.name,
					input: message.toolCall.arguments
				});
				continue;
			}

			if (message.role === 'tool-result' && message.toolResult) {
				// Never sent to the model — runTurn only calls the API once every
				// pending approval has resolved.
				if (message.toolResult.outcome === 'action_required') continue;

				flushAssistant();
				result.push({
					role: 'user',
					content: [
						{
							type: 'tool_result',
							tool_use_id: message.toolResult.callId,
							content:
								message.toolResult.outcome === 'error'
									? (message.toolResult.error?.message ?? 'Tool execution failed.')
									: JSON.stringify(message.toolResult.content),
							is_error: message.toolResult.outcome === 'error'
						}
					]
				});
			}
		}

		flushAssistant();
		return result;
	}

	function hasUnresolvedApprovals(history: ConversationHistory): boolean {
		return Object.values(history.messages).some(
			(message) =>
				message.role === 'tool-result' && message.toolResult?.outcome === 'action_required'
		);
	}

	function findToolCallMessage(
		history: ConversationHistory,
		toolCallId: string
	): Message | undefined {
		return Object.values(history.messages).find(
			(message) => message.role === 'tool-call' && message.toolCall?.id === toolCallId
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

	function buildToolResultInput(toolName: string, input: unknown): Omit<ToolResult, 'callId'> {
		const tool = getTool(toolName);

		if (!tool) {
			return {
				outcome: 'error',
				content: null,
				error: {
					code: 'unknown_tool',
					category: 'not_found',
					retryable: false,
					message: `No tool named "${toolName}" is registered.`
				}
			};
		}

		try {
			const result = tool.execute(input);
			if (!isJSONValue(result)) {
				throw new Error(`${toolName} returned a non-JSON-serializable result.`);
			}
			return { outcome: 'success', content: result };
		} catch (cause) {
			return {
				outcome: 'error',
				content: null,
				error: {
					code: 'execution_failed',
					category: 'internal',
					retryable: false,
					message: cause instanceof Error ? cause.message : 'Tool execution failed.'
				}
			};
		}
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

		const history = toAnthropicHistory(conversation);
		const { conversation: withPlaceholder, messageId } = appendStreamingMessage(
			conversation,
			'assistant'
		);
		conversation = withPlaceholder;
		chat?.beginStreaming(messageId);

		const toolUses: ToolUseEvent[] = [];
		let buffer = '';

		try {
			const response = await fetch('/api/chat', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ messages: history })
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
						conversation = updateStreamingMessage(conversation, messageId, buffer);
						chat?.pushToken(event.text);
					} else {
						toolUses.push(event);
					}
				}
			}

			conversation = buffer
				? finalizeStreamingMessage(conversation, messageId)
				: cancelStreamingMessage(conversation, messageId);
		} catch (cause) {
			conversation = cancelStreamingMessage(conversation, messageId);
			throw cause;
		} finally {
			chat?.endStreaming();
		}

		if (toolUses.length === 0) return;

		for (const toolUse of toolUses) {
			if (!isJSONValue(toolUse.input)) continue;

			conversation = appendMessages(conversation, {
				role: 'tool-call',
				content: '',
				toolCall: { id: toolUse.id, name: toolUse.name, arguments: toolUse.input }
			});

			const tool = getTool(toolUse.name);
			if (tool?.requiresApproval) {
				conversation = appendMessages(conversation, {
					role: 'tool-result',
					content: '',
					toolResult: {
						callId: toolUse.id,
						outcome: 'action_required',
						content: null,
						action: { type: 'approval', message: tool.approvalMessage ?? `Approve ${tool.name}?` }
					}
				});
				continue;
			}

			conversation = appendMessages(conversation, {
				role: 'tool-result',
				content: '',
				toolResult: { callId: toolUse.id, ...buildToolResultInput(toolUse.name, toolUse.input) }
			});
		}

		if (!hasUnresolvedApprovals(conversation)) {
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
				const callMessage = findToolCallMessage(conversation, toolCallId);
				const resultMessageId = findToolResultMessageId(conversation, toolCallId);
				if (!callMessage?.toolCall || !resultMessageId) return;

				conversation = replaceToolResult(conversation, resultMessageId, {
					callId: toolCallId,
					...buildToolResultInput(callMessage.toolCall.name, callMessage.toolCall.arguments)
				});
				await runTurn();
			});
		},
		denyToolCall: async (toolCallId) => {
			await withStreamingIndicator(async () => {
				const resultMessageId = findToolResultMessageId(conversation, toolCallId);
				if (!resultMessageId) return;

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
