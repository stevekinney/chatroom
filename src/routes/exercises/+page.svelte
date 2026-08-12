<script lang="ts">
	import { resolve } from '$app/paths';

	type ExerciseSlug =
		| 'attachments'
		| 'adapter-push'
		| 'message-lifecycle'
		| 'assistant-metadata'
		| 'conversation-list'
		| 'composer-popover'
		| 'history-scroll'
		| 'virtualization'
		| 'presentation'
		| 'artifacts'
		| 'utilities'
		| 'tool-approval'
		| 'interleaving'
		| 'contracts'
		| 'review-basics'
		| 'review-views'
		| 'review-modes'
		| 'review-comment-creation'
		| 'review-comment-lifecycle'
		| 'review-anchoring'
		| 'review-form-and-exports'
		| 'review-front-matter'
		| 'review-state-and-session'
		| 'review-ssr-and-a11y';

	type Exercise = {
		slug: ExerciseSlug;
		title: string;
		description: string;
	};

	const exercises: Exercise[] = [
		{
			slug: 'attachments',
			title: 'Attachments',
			description: 'Add, remove, and fail file attachments through the composer.'
		},
		{
			slug: 'adapter-push',
			title: 'Adapter Push',
			description: "Drive the transcript entirely through a ChatAdapter's push handlers."
		},
		{
			slug: 'message-lifecycle',
			title: 'Message Lifecycle',
			description: 'Stream, cancel, and retry a message mid-flight.'
		},
		{
			slug: 'assistant-metadata',
			title: 'Assistant Metadata',
			description: 'Exercise reasoning, steps, and suggestions on assistant messages.'
		},
		{
			slug: 'conversation-list',
			title: 'Conversation List',
			description: 'Switch between multiple seeded conversations with a conversation header.'
		},
		{
			slug: 'composer-popover',
			title: 'Composer Popover',
			description: 'Trigger a slash-command popover with fuzzy filtering in the composer.'
		},
		{
			slug: 'history-scroll',
			title: 'History Scroll',
			description: 'Load older pages of history and track scroll/unread state.'
		},
		{
			slug: 'virtualization',
			title: 'Virtualization',
			description: 'Confirm a large transcript stays virtualized while streaming.'
		},
		{
			slug: 'presentation',
			title: 'Presentation',
			description: 'Exercise copy, retry, edit, and search capabilities on a seeded transcript.'
		},
		{
			slug: 'artifacts',
			title: 'Artifacts',
			description: 'Open an artifact viewer from message metadata.'
		},
		{
			slug: 'utilities',
			title: 'Utilities',
			description: 'Exercise the standalone message and export utility exports.'
		},
		{
			slug: 'tool-approval',
			title: 'Tool Approval',
			description:
				'Approve or deny action-required tool calls through the adapter and callback contract.'
		},
		{
			slug: 'interleaving',
			title: 'Interleaving',
			description: 'Race streaming, editing, retrying, and stopping against a shared transcript.'
		},
		{
			slug: 'contracts',
			title: 'Contracts',
			description:
				'Pin the schema-version compatibility and height-collapse environmental contracts.'
		},

		// ReviewEditor (`@lostgradient/editor`) — a second component under the
		// same treatment as Chat. Ordered roughly from the surface inward:
		// props, then views, then comments, then the machinery underneath.
		{
			slug: 'review-basics',
			title: 'Review Basics',
			description: 'Round-trip the bindable props and observe every notification callback fire.'
		},
		{
			slug: 'review-views',
			title: 'Review Views and Diff',
			description: 'Switch editor/diff/summary, drive the diff view modes, and revert all changes.'
		},
		{
			slug: 'review-modes',
			title: 'Review Modes and Identity',
			description: 'Exercise readonly mode and what currentUserId gates.'
		},
		{
			slug: 'review-comment-creation',
			title: 'Review Comment Creation',
			description: 'Create threads from a selection and as document-level feedback.'
		},
		{
			slug: 'review-comment-lifecycle',
			title: 'Review Comment Lifecycle',
			description: 'Edit, soft-delete, and hard-delete comments through a thread.'
		},
		{
			slug: 'review-anchoring',
			title: 'Review Anchoring',
			description: 'Follow anchors through edits, re-anchoring, and orphaned text.'
		},
		{
			slug: 'review-form-and-exports',
			title: 'Review Form and Exports',
			description: 'Submit a real form and copy each export the actions menu offers.'
		},
		{
			slug: 'review-front-matter',
			title: 'Review Front Matter',
			description: 'Edit YAML front matter and check its round-trip fidelity.'
		},
		{
			slug: 'review-state-and-session',
			title: 'Review State and Session',
			description:
				'Serialize and restore a review through getState/setState and the session helpers.'
		},
		{
			slug: 'review-ssr-and-a11y',
			title: 'Review SSR and Accessibility',
			description: 'Pin SSR output, hydration, live regions, and the keyboard path.'
		}
	];
</script>

<div style="max-width: 40rem; margin: 0 auto; padding: 2rem 1rem;">
	<h1>Exercises</h1>
	<ul style="list-style: none; padding: 0; margin: 1.5rem 0 0; display: grid; gap: 1rem;">
		{#each exercises as exercise (exercise.slug)}
			<li>
				<a href={resolve(`/exercises/${exercise.slug}`)}>{exercise.title}</a>
				<p style="margin: 0.25rem 0 0; color: var(--cinder-text-muted, currentColor);">
					{exercise.description}
				</p>
			</li>
		{/each}
	</ul>
</div>
