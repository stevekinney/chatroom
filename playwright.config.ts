import { defineConfig } from '@playwright/test';

export default defineConfig({
	// With a SINGLE webServer Playwright infers `baseURL` from its port; with an
	// array it does not, and every relative `page.goto('/…')` in the suite would
	// fail. Set it explicitly to the production preview, which is what all but
	// `hydration.e2e.ts` exercise.
	use: { baseURL: 'http://localhost:4173' },
	webServer: [
		{ command: 'npm run build && npm run preview', port: 4173 },
		// A dev server alongside the production preview, purely so hydration
		// mismatches are observable: Svelte strips `hydration_mismatch` from
		// production builds, so `hydration.e2e.ts` has to drive a dev build to see
		// them at all (cinder#756 hid here for exactly that reason).
		{ command: 'npm run dev -- --port 5175 --strictPort', port: 5175 }
	],
	testMatch: '**/*.e2e.{ts,js}'
});
