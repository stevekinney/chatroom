#!/usr/bin/env bun
/**
 * Bumps the upstream packages chatroom consumes — the @lostgradient workspace
 * releases (cinder, chat, editor, markdown) plus armorer from agent-bureau — to
 * their latest published versions and re-verifies chatroom. Run after an
 * upstream release publishes.
 *
 * Keep this list in step with the `@lostgradient/*` entries in package.json.
 * `@lostgradient/editor` was missing here for the whole of its first release
 * cycle: the sync reported success while silently leaving editor on the
 * previous major-equivalent range, so the `review-*` exercises typechecked
 * against an older component than the one the sync claimed to have installed.
 * A package absent from this list is not "not synced" — it is worse, because
 * the sync still prints a clean bill of health.
 *
 * chatroom consumes the published npm packages (not a bun link against
 * ../cinder), so "sync" means "pull the newest release from the registry",
 * not "re-link the working tree".
 */
import { $ } from 'bun';

const packages = [
	'@lostgradient/cinder',
	'@lostgradient/chat',
	'@lostgradient/editor',
	'@lostgradient/markdown',
	'armorer'
];
const full = process.argv.includes('--full');

function fail(message: string): never {
	console.error(`\n✗ ${message}`);
	process.exit(1);
}

async function installedVersions(): Promise<Record<string, string>> {
	const versions: Record<string, string> = {};
	for (const name of packages) {
		const manifest = Bun.file(`node_modules/${name}/package.json`);
		versions[name] = (await manifest.exists())
			? ((await manifest.json()) as { version: string }).version
			: '(not installed)';
	}
	return versions;
}

const before = await installedVersions();

console.log(`Updating ${packages.join(' + ')} to latest published...`);
const update = await $`bun update ${packages} --latest`.nothrow();
if (update.exitCode !== 0) {
	fail('bun update failed — could not fetch the latest published packages.');
}

const after = await installedVersions();
console.log('');
for (const name of packages) {
	const line =
		before[name] === after[name]
			? `${after[name]} (unchanged)`
			: `${before[name]} → ${after[name]}`;
	console.log(`  ${name}: ${line}`);
}
console.log('');

console.log('Running chatroom verification...\n');

const checks: { name: string; run: () => Promise<{ exitCode: number }> }[] = [
	{ name: 'lint', run: () => $`bun run lint`.nothrow() },
	{ name: 'check', run: () => $`bun run check`.nothrow() },
	// A new release is exactly when `upstream:` workaround markers go stale —
	// fail the sync until each closed-issue workaround is removed (or its issue
	// reopened, if the problem still reproduces).
	{ name: 'check:upstream', run: () => $`bun run check:upstream`.nothrow() },
	// A new release is also exactly when a dependency we re-declare drifts from
	// the range its owning package moved to.
	{ name: 'check:peers', run: () => $`bun run check:peers`.nothrow() }
];

if (full) {
	checks.push({ name: 'test:e2e', run: () => $`bun run test:e2e`.nothrow() });
} else {
	console.log('(skipping test:e2e — pass --full to include it)\n');
}

let allPassed = true;
for (const check of checks) {
	console.log(`→ ${check.name}`);
	const result = await check.run();
	if (result.exitCode !== 0) {
		allPassed = false;
		console.error(`✗ ${check.name} failed`);
	} else {
		console.log(`✓ ${check.name} passed`);
	}
}

if (!allPassed) {
	fail(
		'One or more checks failed after syncing. Do not report this sync as clean — a new release broke something here; investigate before continuing.'
	);
}

console.log(
	'\n✓ Sync complete — @lostgradient packages are at their latest published versions and chatroom verifies clean.'
);
