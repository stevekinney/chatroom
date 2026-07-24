<script lang="ts">
	import {
		Chat,
		createConversation,
		type ChatAdapter,
		type ConversationHistory
	} from '@lostgradient/chat';

	/**
	 * A scoped, opt-in fixture proving the `queueMicrotask` deferral used
	 * throughout the adapter-push demo is load-bearing rather than
	 * defensive-programming paranoia: this adapter's `subscribe` writes
	 * `$state` SYNCHRONOUSLY (no `queueMicrotask`/`tick`), which the
	 * `ChatAdapter.subscribe` docs say throws `effect_update_depth_exceeded`
	 * because `subscribe` runs from inside Chat's own still-settling mount
	 * `$effect`. Mounted only while its checkbox is enabled, and wrapped in
	 * its own `<svelte:boundary>` so the deliberate crash cannot take down
	 * the rest of the page.
	 */

	let enabled = $state(false);
	let subscribeLog = $state<string[]>([]);

	let conversation = $state<ConversationHistory>(
		createConversation({ id: 'adapter-push-hazard-demo' })
	);

	const adapter: ChatAdapter = {
		sendMessage: async () => {},
		subscribe: (conversationId) => {
			// Deliberately NOT deferred -- this is the bug this fixture exists to
			// reproduce.
			subscribeLog = [...subscribeLog, `subscribed to "${conversationId}"`];
			return () => {};
		}
	};

	function toggleEnabled(): void {
		enabled = !enabled;
	}

	function handleReset(boundaryReset: () => void): void {
		enabled = false;
		boundaryReset();
	}
</script>

<div style="padding: 0.75rem 1rem; border-top: 1px solid var(--cinder-border);">
	<h2 style="font-size: 0.875rem; margin: 0 0 0.5rem;">Subscribe-in-effect hazard fixture</h2>
	<button type="button" data-testid="toggle-hazard-fixture" onclick={toggleEnabled}>
		{enabled ? 'Disable' : 'Enable'} subscribe-in-effect hazard fixture
	</button>
	<ul
		data-testid="hazard-subscribe-log"
		style="font-size: 0.7rem; margin: 0.5rem 0 0; padding-left: 1.25rem;"
	>
		{#each subscribeLog as entry, index (index)}
			<li>{entry}</li>
		{/each}
	</ul>
	{#if enabled}
		<svelte:boundary>
			<div
				data-testid="hazard-fixture-chat"
				style="height: 220px; margin-top: 0.5rem; border: 1px dashed var(--cinder-danger);"
			>
				<Chat id="adapter-push-hazard-chat" {conversation} {adapter} />
			</div>
			{#snippet failed(caughtError, reset)}
				<p data-testid="hazard-fixture-error" role="alert" style="font-size: 0.75rem;">
					{caughtError instanceof Error ? caughtError.message : String(caughtError)}
				</p>
				<button type="button" data-testid="hazard-fixture-reset" onclick={() => handleReset(reset)}>
					Reset hazard fixture
				</button>
			{/snippet}
		</svelte:boundary>
	{/if}
</div>
