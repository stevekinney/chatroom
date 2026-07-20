import adapter from '@sveltejs/adapter-auto';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},

			// adapter-auto only supports some environments, see https://svelte.dev/docs/kit/adapter-auto for a list.
			// If your environment is not supported, or you settled on a specific environment, switch out the adapter.
			// See https://svelte.dev/docs/kit/adapters for more information about adapters.
			adapter: adapter()
		})
	],

	// Both @lostgradient/chat and its @lostgradient/cinder peer are consumed via
	// `bun link` against live source in ../cinder. Left externalized, SSR would
	// resolve them through their `node` export condition into each package's
	// prebuilt dist/server bundle — defeating the live-source purpose and, worse,
	// pulling in server artifacts that aren't built in a plain source checkout.
	// noExternal alone isn't enough: export-map precedence is key order, and both
	// packages list `node` before `svelte`, so `node` wins into dist/server as long
	// as it's an active SSR condition. Dropping `node` (and never adding `browser`)
	// lets the `svelte` source condition win for SSR too. `@anthropic-ai/sdk` in the
	// API route keeps working via its `import` build.
	ssr: {
		noExternal: ['@lostgradient/chat', '@lostgradient/cinder'],
		resolve: {
			conditions: ['svelte', 'module', 'import', 'default']
		}
	}
});
