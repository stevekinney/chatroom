#!/usr/bin/env bun
/**
 * Pulls ../cinder's main branch, re-establishes the bun link, and re-verifies
 * chatroom. Intended to run after a cinder PR (filed from this project) merges.
 */
import { existsSync } from 'node:fs';
import { $ } from 'bun';

const cinderPath = process.argv[2] ?? '../cinder';
const componentsPath = `${cinderPath}/packages/components`;
const chatPath = `${cinderPath}/packages/chat`;
const full = process.argv.includes('--full');

function fail(message: string): never {
	console.error(`\n✗ ${message}`);
	process.exit(1);
}

if (!existsSync(cinderPath)) {
	fail(`${cinderPath} does not exist. Pass the cinder checkout path as the first argument.`);
}

console.log(`Syncing against ${cinderPath}\n`);

const status = await $`git -C ${cinderPath} status --porcelain`.text();
if (status.trim() !== '') {
	fail(`${cinderPath} has uncommitted changes — commit or stash them before syncing.`);
}

const branch = (await $`git -C ${cinderPath} rev-parse --abbrev-ref HEAD`.text()).trim();
if (branch !== 'main') {
	fail(`${cinderPath} is on branch '${branch}', not 'main' — check out main before syncing.`);
}

const before = (await $`git -C ${cinderPath} rev-parse HEAD`.text()).trim();

await $`git -C ${cinderPath} fetch origin`;

const pull = await $`git -C ${cinderPath} pull --ff-only origin main`.nothrow();
if (pull.exitCode !== 0) {
	fail(
		`git pull --ff-only failed in ${cinderPath} — it has likely diverged from origin/main. Resolve manually.`
	);
}

const after = (await $`git -C ${cinderPath} rev-parse HEAD`.text()).trim();

if (before === after) {
	console.log('Already up to date — no new commits.\n');
} else {
	console.log('New commits pulled:\n');
	console.log(await $`git -C ${cinderPath} log --oneline ${before}..${after}`.text());
}

// Chat lives in its own package as of Cinder 0.16 and its `/styles` subpath
// resolves only from dist — rebuild that CSS before verifying.
console.log('Rebuilding @lostgradient/chat (for its dist CSS)...');
const chatBuild = await $`bun run --filter=@lostgradient/chat build`.cwd(cinderPath).nothrow();
if (chatBuild.exitCode !== 0) {
	fail('Building @lostgradient/chat failed — its /styles CSS will not resolve. Investigate.');
}

// Register both packages, then link them in a SINGLE call: linking one at a
// time flips the previously-linked package back to its registry version.
console.log('Re-linking @lostgradient/cinder and @lostgradient/chat...');
await $`bun link`.cwd(componentsPath).quiet();
await $`bun link`.cwd(chatPath).quiet();
await $`bun link @lostgradient/cinder @lostgradient/chat`.quiet();

if (
	!existsSync('node_modules/@lostgradient/cinder/src') ||
	!existsSync('node_modules/@lostgradient/chat/src')
) {
	fail(
		'A link reverted to its registry version (no src/ in node_modules) — re-link both in one call.'
	);
}
console.log('Link OK.\n');

console.log('Running chatroom verification...\n');

const checks: { name: string; run: () => Promise<{ exitCode: number }> }[] = [
	{ name: 'lint', run: () => $`bun run lint`.nothrow() },
	{ name: 'check', run: () => $`bun run check`.nothrow() }
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
		'One or more checks failed after syncing. Do not report this sync as clean — investigate before continuing.'
	);
}

console.log('\n✓ Sync complete — cinder is up to date and chatroom verifies clean.');
