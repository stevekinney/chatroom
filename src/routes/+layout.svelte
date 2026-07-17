<script lang="ts">
	// Base stylesheet must load first — it declares the cascade @layer order.
	// The guard warns in dev if a component's styles ever land before it.
	import '@lostgradient/cinder/styles';
	import '@lostgradient/cinder/styles/guard';

	import favicon from '$lib/assets/favicon.svg';

	let { children } = $props();
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

{@render children()}
