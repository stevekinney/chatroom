#!/usr/bin/env bun
/**
 * Finds `upstream: <owner>/<repo>#<issue>` markers left next to workarounds in
 * tracked AND untracked-but-not-ignored source files (`git grep --untracked`
 * respects .gitignore, so node_modules etc. stay out), checks each referenced
 * issue's state via `gh`, and flags any that have closed — those workarounds
 * are candidates to remove.
 *
 * Markers live in code comments (JSON files can't carry them, so dependency
 * entries aren't tagged — only the code that works around them).
 */
import { $ } from 'bun';

const MARKER_PATTERN = /upstream:\s*([\w.-]+\/[\w.-]+)#(\d+)/;

type Reference = { file: string; line: number; repo: string; issue: number };

function fail(message: string): never {
	console.error(`\n✗ ${message}`);
	process.exit(1);
}

const grep = await $`git grep -nP --untracked ${MARKER_PATTERN.source}`.nothrow().quiet();
if (grep.exitCode !== 0 && grep.stdout.toString().trim() === '') {
	console.log('No upstream markers found in tracked or untracked files.');
	process.exit(0);
}

const references: Reference[] = [];
for (const line of grep.stdout.toString().split('\n')) {
	if (!line) continue;
	const [file, lineNumber, ...rest] = line.split(':');
	const match = rest.join(':').match(MARKER_PATTERN);
	if (!match) continue;
	references.push({ file, line: Number(lineNumber), repo: match[1], issue: Number(match[2]) });
}

if (references.length === 0) {
	console.log('No upstream markers found in tracked or untracked files.');
	process.exit(0);
}

const byIssue = new Map<string, Reference[]>();
for (const reference of references) {
	const key = `${reference.repo}#${reference.issue}`;
	byIssue.set(key, [...(byIssue.get(key) ?? []), reference]);
}

console.log(`Checking ${byIssue.size} upstream issue(s)...\n`);

let hadError = false;
let hadClosed = false;

for (const [key, refs] of byIssue) {
	const { repo, issue } = refs[0];
	const result = await $`gh issue view ${issue} --repo ${repo} --json state,title,url`
		.nothrow()
		.quiet();

	if (result.exitCode !== 0) {
		hadError = true;
		console.error(`? ${key} — could not check (${result.stderr.toString().trim() || 'gh error'})`);
		continue;
	}

	const { state, title, url } = JSON.parse(result.stdout.toString()) as {
		state: string;
		title: string;
		url: string;
	};

	if (state === 'CLOSED') {
		hadClosed = true;
		console.log(`✗ ${key} is CLOSED — "${title}"\n  ${url}`);
		for (const ref of refs) {
			console.log(`  refactor: ${ref.file}:${ref.line}`);
		}
	} else {
		console.log(`✓ ${key} still open — "${title}"`);
	}
}

if (hadError) {
	fail('One or more issues could not be checked — see errors above.');
}

if (hadClosed) {
	fail('One or more upstream issues have closed. Remove the corresponding workarounds.');
}

console.log('\n✓ All referenced upstream issues are still open — no workarounds to remove yet.');
