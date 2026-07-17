/**
 * Isomorphic tool registry — schemas are used server-side to build the
 * Anthropic `tools` param; `execute` runs wherever a tool call is resolved
 * (currently client-side, since both tools here are deterministic/mocked
 * and need no secrets).
 */
/** Matches Anthropic's `Tool.input_schema` shape without importing the SDK. */
type ToolInputSchema = {
	type: 'object';
	properties?: Record<string, unknown>;
	required?: string[];
};

export type ToolDefinition = {
	name: string;
	description: string;
	inputSchema: ToolInputSchema;
	requiresApproval: boolean;
	approvalMessage?: string;
	/** May throw; callers are responsible for turning that into an error outcome. */
	execute: (input: unknown) => unknown;
};

type RollDiceInput = { sides: number; count: number };
type RememberNoteInput = { text: string };

function isRollDiceInput(value: unknown): value is RollDiceInput {
	return (
		typeof value === 'object' &&
		value !== null &&
		typeof (value as Record<string, unknown>).sides === 'number' &&
		typeof (value as Record<string, unknown>).count === 'number'
	);
}

function isRememberNoteInput(value: unknown): value is RememberNoteInput {
	return (
		typeof value === 'object' &&
		value !== null &&
		typeof (value as Record<string, unknown>).text === 'string'
	);
}

export const TOOLS: ToolDefinition[] = [
	{
		name: 'roll_dice',
		description: 'Roll one or more dice and return the individual results.',
		inputSchema: {
			type: 'object',
			properties: {
				sides: { type: 'integer', minimum: 2, maximum: 1000 },
				count: { type: 'integer', minimum: 1, maximum: 20 }
			},
			required: ['sides', 'count']
		},
		requiresApproval: false,
		execute: (input) => {
			if (!isRollDiceInput(input)) throw new Error('roll_dice requires numeric sides and count.');
			const rolls = Array.from(
				{ length: input.count },
				() => 1 + Math.floor(Math.random() * input.sides)
			);
			return { rolls, total: rolls.reduce((sum, roll) => sum + roll, 0) };
		}
	},
	{
		name: 'remember_note',
		description: 'Save a short note for later reference. Requires the user to approve first.',
		inputSchema: {
			type: 'object',
			properties: { text: { type: 'string' } },
			required: ['text']
		},
		requiresApproval: true,
		approvalMessage: 'Save this note?',
		execute: (input) => {
			if (!isRememberNoteInput(input)) throw new Error('remember_note requires a text field.');
			return { saved: true, text: input.text };
		}
	}
];

export function getTool(name: string): ToolDefinition | undefined {
	return TOOLS.find((tool) => tool.name === name);
}

export function toAnthropicTools(): {
	name: string;
	description: string;
	input_schema: ToolInputSchema;
}[] {
	return TOOLS.map((tool) => ({
		name: tool.name,
		description: tool.description,
		input_schema: tool.inputSchema
	}));
}
