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
		| 'utilities';

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
