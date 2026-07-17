import { ANTHROPIC_API_KEY } from '$env/static/private';
import { json } from '@sveltejs/kit';
import Anthropic from '@anthropic-ai/sdk';
import { z } from 'zod';

import { toAnthropicTools } from '$lib/tools';

import type { RequestHandler } from './$types';

const MODEL = 'claude-sonnet-5';
const MAX_TOKENS = 4096;

const textBlockSchema = z.object({ type: z.literal('text'), text: z.string() });

const toolUseBlockSchema = z.object({
	type: z.literal('tool_use'),
	id: z.string(),
	name: z.string(),
	input: z.unknown()
});

const toolResultBlockSchema = z.object({
	type: z.literal('tool_result'),
	tool_use_id: z.string(),
	content: z.string(),
	is_error: z.boolean().optional()
});

const requestSchema = z.object({
	messages: z
		.array(
			z.union([
				z.object({
					role: z.literal('user'),
					content: z.array(z.union([textBlockSchema, toolResultBlockSchema])).min(1)
				}),
				z.object({
					role: z.literal('assistant'),
					content: z.array(z.union([textBlockSchema, toolUseBlockSchema])).min(1)
				})
			])
		)
		.min(1)
});

const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY });

export const POST: RequestHandler = async ({ request }) => {
	let body: unknown;

	try {
		body = await request.json();
	} catch {
		return json({ error: 'Invalid JSON' }, { status: 400 });
	}

	const parsed = requestSchema.safeParse(body);

	if (!parsed.success) {
		return json({ error: 'Invalid request body' }, { status: 400 });
	}

	const anthropicStream = anthropic.messages.stream({
		model: MODEL,
		max_tokens: MAX_TOKENS,
		messages: parsed.data.messages,
		tools: toAnthropicTools()
	});

	const encoder = new TextEncoder();

	// `end` can fire after `error` (or after the consumer cancels the stream),
	// and a ReadableStreamDefaultController throws if closed/errored twice —
	// an uncaught throw here happens inside an event-emitter callback, outside
	// SvelteKit's request handling, and crashes the whole process. `settled`
	// makes every controller interaction below a one-shot.
	let settled = false;

	const stream = new ReadableStream<Uint8Array>({
		start(controller) {
			function enqueueEvent(event: unknown) {
				if (settled) return;
				controller.enqueue(encoder.encode(`${JSON.stringify(event)}\n`));
			}

			anthropicStream.on('text', (text) => enqueueEvent({ type: 'text', text }));
			anthropicStream.on('contentBlock', (block) => {
				if (block.type === 'tool_use') {
					enqueueEvent({ type: 'tool_use', id: block.id, name: block.name, input: block.input });
				}
			});
			anthropicStream.on('end', () => {
				if (settled) return;
				settled = true;
				controller.close();
			});
			anthropicStream.on('error', (error) => {
				if (settled) return;
				settled = true;
				controller.error(error);
			});
		},
		cancel() {
			settled = true;
			anthropicStream.abort();
		}
	});

	return new Response(stream, {
		headers: { 'Content-Type': 'application/x-ndjson; charset=utf-8' }
	});
};
