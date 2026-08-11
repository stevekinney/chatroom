#!/usr/bin/env bun
/**
 * Fails when a dependency chatroom declares directly has drifted out of step
 * with the range the owning upstream package declares for it.
 *
 * chatroom re-declares `conversationalist` because the API route imports
 * `conversationalist/adapters/anthropic` and `conversationalist/schemas`, which
 * `@lostgradient/chat` does not re-export. Chat also depends on
 * conversationalist itself, and both copies must resolve to the SAME instance:
 * transcripts built by chat's re-exported builders are handed to our own
 * conversationalist imports and back. Two ranges that no longer overlap means
 * two installed copies, and the mismatch is silent — the transcript types are
 * structural, so nothing fails to typecheck; it surfaces later as a schema
 * version warning or a builder quietly operating on a foreign shape.
 *
 * The failure mode this guards is drift, not any particular version: chat
 * bumps its conversationalist floor in a release, chatroom's range stays where
 * it was, and the two silently diverge. (agent-bureau#314 was the same class of
 * bug upstream — a pinned range nobody re-checked.)
 */
const CHECKS = [
	{
		dependency: 'conversationalist',
		owner: '@lostgradient/chat',
		why: 'the API route imports conversationalist subpaths chat does not re-export'
	}
] as const;

type Manifest = {
	dependencies?: Record<string, string>;
	devDependencies?: Record<string, string>;
	peerDependencies?: Record<string, string>;
};

async function readManifest(path: string): Promise<Manifest | null> {
	const file = Bun.file(path);
	return (await file.exists()) ? ((await file.json()) as Manifest) : null;
}

function declaredRange(manifest: Manifest, name: string): string | undefined {
	return (
		manifest.dependencies?.[name] ??
		manifest.devDependencies?.[name] ??
		manifest.peerDependencies?.[name]
	);
}

const ours = await readManifest('package.json');
if (!ours) {
	console.error('✗ could not read chatroom package.json');
	process.exit(1);
}

let failed = false;

console.log(
	`Checking ${CHECKS.length} direct dependency range(s) against their owning package...\n`
);

for (const check of CHECKS) {
	const ourRange = declaredRange(ours, check.dependency);
	if (!ourRange) {
		console.log(`- ${check.dependency}: not declared directly here, nothing to align`);
		continue;
	}

	const ownerManifest = await readManifest(`node_modules/${check.owner}/package.json`);
	if (!ownerManifest) {
		console.error(`✗ ${check.owner} is not installed — cannot verify ${check.dependency}`);
		failed = true;
		continue;
	}

	const ownerRange = declaredRange(ownerManifest, check.dependency);
	if (!ownerRange) {
		console.error(
			`✗ ${check.owner} no longer declares ${check.dependency}.\n` +
				`  chatroom still declares "${ourRange}" (${check.why}).\n` +
				`  Re-check whether we still need it, and whether it moved to a different owner.`
		);
		failed = true;
		continue;
	}

	// Compare the ranges as declared. Equality is the invariant worth enforcing:
	// chatroom's copy exists only to reach subpaths of the SAME conversationalist
	// chat resolves, so "compatible but different" is already drift.
	if (ourRange !== ownerRange) {
		console.error(
			`✗ ${check.dependency} range drifted from ${check.owner}.\n` +
				`  ${check.owner} declares: ${ownerRange}\n` +
				`  chatroom declares:       ${ourRange}\n` +
				`  Align chatroom's range with ${check.owner}'s (${check.why}).`
		);
		failed = true;
		continue;
	}

	const installed = await readManifest(`node_modules/${check.dependency}/package.json`);
	const installedVersion = (installed as { version?: string } | null)?.version ?? '(not installed)';
	console.log(
		`✓ ${check.dependency}: ${ourRange} matches ${check.owner} (installed ${installedVersion})`
	);
}

if (failed) {
	console.error('\n✗ Dependency ranges are out of step with their owning package.');
	process.exit(1);
}

console.log('\n✓ Direct dependency ranges match their owning packages.');
