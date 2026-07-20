import { createTool, createToolbox } from 'armorer';
import { z } from 'zod';

const rollDice = createTool({
	name: 'roll_dice',
	description: 'Roll one or more dice and return the individual results.',
	input: z.object({
		sides: z.number().int().min(2).max(1000),
		count: z.number().int().min(1).max(20)
	}),
	async execute({ sides, count }) {
		const rolls = Array.from({ length: count }, () => 1 + Math.floor(Math.random() * sides));
		return { rolls, total: rolls.reduce((sum, roll) => sum + roll, 0) };
	}
});

const rememberNote = createTool({
	name: 'remember_note',
	description: 'Save a short note for later reference.',
	input: z.object({ text: z.string() }),
	policy: {
		// agent-bureau#226: `allow` is still required alongside `status` even
		// though armorer's own README example for `needs_approval` omits it.
		beforeExecute: () => ({ allow: false, status: 'needs_approval', reason: 'Save this note?' })
	},
	async execute({ text }) {
		return { saved: true, text };
	}
});

/**
 * Stable for the process's lifetime only. Nothing else in this app survives
 * a server restart either (`conversation` lives in the browser tab), so a
 * restart invalidating an in-flight approval is an acceptable limitation
 * rather than a reason to commit a secret to `.env`.
 */
export const toolbox = createToolbox([rollDice, rememberNote], {
	approvalSecret: crypto.randomUUID()
});
