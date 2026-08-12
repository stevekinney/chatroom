<script lang="ts">
	import {
		addComment,
		deleteComment,
		deleteThread,
		generateId,
		getVisibleComments,
		timestamp,
		updateComment,
		type Comment,
		type Thread
	} from '@lostgradient/editor/comments';
	import { ReviewEditor } from '@lostgradient/editor/review-editor';

	// The COMMENT LIFECYCLE surface: reply, edit, soft-delete, clear. Everything
	// here reads from one deliberately rich seeded fixture — mixed authorship, a
	// comment that is already soft-deleted, and a "ghost" thread whose only
	// comment is soft-deleted. `review-comment-creation` cannot share this
	// fixture (an existing anchor decoration swallows the drag that route needs
	// to start a thread), so the split is forced by the fixture, not the topic.
	//
	// The other half of the route is the CONSUMER side. Every mutation callback
	// on ReviewEditor is notification-only: the component tells you what the
	// user asked for and changes nothing. The page owns a reducer over the pure
	// helpers exported from `@lostgradient/editor/comments`, which is the only
	// thing that actually moves `threads`.

	// ---------------------------------------------------------------------------
	// Document + anchor coordinates
	// ---------------------------------------------------------------------------

	// Headings and paragraphs only — no lists. ProseMirror positions for a list
	// depend on how tightly the markdown parser nests `list_item > paragraph`,
	// and this fixture's whole point is that the seeded `from`/`to` are exact.
	const HEADING = 'Release Plan';
	const PARAGRAPH_ONE =
		'The first release includes a dashboard, export actions, and inline review.';
	const PARAGRAPH_TWO =
		'Reviewers should verify that the export dialog copy matches the product brief before we ship.';
	const PARAGRAPH_THREE = 'Timeline risk: the migration script is untested.';

	let value = $state(`# ${HEADING}\n\n${PARAGRAPH_ONE}\n\n${PARAGRAPH_TWO}\n\n${PARAGRAPH_THREE}`);

	// `anchor.from`/`anchor.to` are PROSEMIRROR POSITIONS. `anchor.lastKnownOffset`
	// is a `doc.textBetween()` offset. Two coordinate spaces, side by side in the
	// same object, and nothing warns when you mix them up.
	//
	// ProseMirror positions here (each block node costs 1 on each side):
	//   heading  node 0..14   content  1..13   ("# " is markup, not text)
	//   para 1   node 14..90  content 15..89
	//   para 2   node 90..185 content 91..184
	//   para 3   node 185..235 content 186..234
	//
	// textBetween offsets (blocks joined by a single "\n"):
	//   heading 0..12   para 1 13..87   para 2 88..181   para 3 182..230
	//
	// Getting these wrong is no longer harmless: as of the fix in cinder PR
	// #1266, an anchor whose quote is not literally at its stated range fails
	// `anchorMatchesDocument` and triggers re-anchoring instead of painting a
	// bogus highlight — so a wrong `from`/`to` silently rewrites itself and the
	// "Seeded anchors" readout below stops matching the fixture.
	const LONG_QUOTE =
		'Reviewers should verify that the export dialog copy matches the product brief';
	const GHOST_QUOTE = 'Timeline risk';

	// A comment body over 80 characters, so the sidebar preview truncation is
	// observable; the thread it lives on is authored entirely by `maya`, so the
	// per-comment action buttons are absent for `steve`.
	const LONG_BODY =
		'This paragraph is the sentence legal asked us to re-read line by line before the release notes go out to customers.';

	let threads = $state<Thread[]>([
		// A document-level thread. It sorts FIRST in the sidebar regardless of
		// position, renders `Document comment` instead of a quote, and paints no
		// anchor decoration (from === to, so `computeDecorations` skips it).
		{
			id: 't-doc',
			createdAt: '2026-08-01T09:00:00.000Z',
			anchor: {
				type: 'document',
				from: 0,
				to: 0,
				quote: '',
				prefix: '',
				suffix: '',
				status: 'anchored'
			},
			comments: [
				{
					id: 'c-doc-1',
					threadId: 't-doc',
					authorId: 'steve',
					body: 'Overall this reads well. One pass for tone and it ships.',
					createdAt: '2026-08-01T09:00:00.000Z'
				}
			]
		},
		// The mixed-authorship thread: one comment by the current user, one by
		// someone else, and one already soft-deleted. Anchored to the heading, so
		// it sorts first among the text-anchored threads.
		{
			id: 't-text',
			createdAt: '2026-08-02T09:00:00.000Z',
			anchor: {
				from: 1,
				to: 13,
				quote: HEADING,
				prefix: '',
				suffix: '\nThe first release includes a dashboard, export ac',
				status: 'anchored',
				originalQuote: HEADING,
				lastKnownOffset: 0
			},
			comments: [
				{
					id: 'c-text-steve',
					threadId: 't-text',
					authorId: 'steve',
					body: 'Should this say "Launch Plan" instead?',
					createdAt: '2026-08-02T09:00:00.000Z'
				},
				{
					id: 'c-text-maya',
					threadId: 't-text',
					authorId: 'maya',
					body: 'Marketing signed off on "Release Plan" last week.',
					createdAt: '2026-08-02T10:00:00.000Z'
				},
				// Seeded already-soft-deleted: never renders, never counted, but it
				// is still here in `threads`. Soft delete is an audit trail, not an
				// erasure.
				{
					id: 'c-text-deleted',
					threadId: 't-text',
					authorId: 'steve',
					body: 'Ignore me, wrong thread.',
					createdAt: '2026-08-02T11:00:00.000Z',
					deletedAt: '2026-08-10T00:00:00.000Z'
				}
			]
		},
		// A long quote (77 chars) so BOTH truncations are observable at once: the
		// sidebar clips the quote at 60 with an ellipsis character, the popover
		// title clips it at 30 with three literal dots.
		{
			id: 't-long',
			createdAt: '2026-08-03T09:00:00.000Z',
			anchor: {
				from: 91,
				to: 168,
				quote: LONG_QUOTE,
				prefix: 's a dashboard, export actions, and inline review.\n',
				suffix: ' before we ship.\nTimeline risk: the migration scri',
				status: 'anchored',
				originalQuote: LONG_QUOTE,
				lastKnownOffset: 88
			},
			comments: [
				{
					id: 'c-long-maya',
					threadId: 't-long',
					authorId: 'maya',
					body: LONG_BODY,
					createdAt: '2026-08-03T09:00:00.000Z'
				}
			]
		},
		// The GHOST: every comment on it is soft-deleted. The sidebar hides it and
		// the toolbar badge ignores it, but it is still a live thread — still in
		// `threads`, still decorating its quote, still openable by clicking that
		// decoration, and still delete-able.
		{
			id: 't-empty',
			createdAt: '2026-08-04T09:00:00.000Z',
			anchor: {
				from: 186,
				to: 199,
				quote: GHOST_QUOTE,
				prefix: 'og copy matches the product brief before we ship.\n',
				suffix: ': the migration script is untested.',
				status: 'anchored',
				originalQuote: GHOST_QUOTE,
				lastKnownOffset: 182
			},
			comments: [
				{
					id: 'c-empty-maya',
					threadId: 't-empty',
					authorId: 'maya',
					body: 'Superseded by the risk register.',
					createdAt: '2026-08-04T09:00:00.000Z',
					deletedAt: '2026-08-09T00:00:00.000Z'
				}
			]
		}
	]);

	const CURRENT_USER = 'steve';

	// ---------------------------------------------------------------------------
	// Event log
	// ---------------------------------------------------------------------------

	// Full JSON, not a formatted summary: the payload SHAPE is what the spec
	// asserts on (`soft: true` on every delete, no `editedAt` on any update, a
	// `requestId` only on creates).
	let events = $state<string[]>([]);

	// Snapshot of the counts AT EVENT TIME, taken before the reducer runs. This
	// is how "notification-only" becomes observable on a page whose reducer
	// applies every event synchronously: when the callback fires, `threads` is
	// still exactly what it was, and the live readouts below only move because
	// the reducer moved them.
	let countsAtLastEvent = $state('—');

	const record = (name: string, payload: unknown) => {
		events = [...events, `${name} ${JSON.stringify(payload)}`];
		countsAtLastEvent = `threads:${threads.length} visible:${visibleCommentTotal} stored:${storedCommentTotal}`;
	};

	// ---------------------------------------------------------------------------
	// The consumer-side reducer
	// ---------------------------------------------------------------------------

	// Every helper below is pure and returns `{ threads, changed }`. `changed`
	// is the only signal that the operation did anything, and the API is full of
	// silent no-ops — so the page renders the last `changed` flag rather than
	// trusting that a call did what it looked like it did.
	let lastChanged = $state<string>('—');

	function applyCommentCreate(event: {
		requestId: string;
		threadId: string;
		body: string;
		authorId: string;
		mentions?: string[];
	}) {
		// The component generated `requestId` for correlating with a backend; the
		// page still has to mint the comment id and timestamp itself, because the
		// pure helpers deliberately generate neither.
		const comment: Comment = {
			id: generateId(),
			threadId: event.threadId,
			authorId: event.authorId,
			body: event.body,
			createdAt: timestamp()
		};
		if (event.mentions) comment.mentions = event.mentions;
		const result = addComment(threads, event.threadId, comment);
		threads = result.threads;
		lastChanged = String(result.changed);
	}

	function applyCommentUpdate(event: {
		threadId: string;
		commentId: string;
		body: string;
		mentions?: string[];
	}) {
		// `editedAt` is REQUIRED by `updateComment` and is NOT on the event — the
		// component has no clock of its own here, so the consumer supplies it.
		// This is what makes `(edited)` appear.
		const result = updateComment(threads, event.threadId, event.commentId, {
			body: event.body,
			...(event.mentions ? { mentions: event.mentions } : {}),
			editedAt: timestamp()
		});
		threads = result.threads;
		lastChanged = String(result.changed);
	}

	function applyCommentDelete(event: { threadId: string; commentId: string; soft: boolean }) {
		const result = deleteComment(threads, event.threadId, event.commentId, {
			soft: event.soft,
			deletedAt: timestamp()
		});
		threads = result.threads;
		lastChanged = String(result.changed);
	}

	function applyThreadDelete(event: { threadId: string }) {
		const result = deleteThread(threads, event.threadId);
		threads = result.threads;
		lastChanged = String(result.changed);
	}

	// The deliberate negative case, and the most likely consumer mistake in the
	// whole API: a soft delete WITHOUT `deletedAt` is not an error and does not
	// throw — it returns `{ changed: false }` and hands back the identical array.
	// The comment stays visible and nothing anywhere says why.
	function softDeleteWithoutTimestamp() {
		const result = deleteComment(threads, 't-doc', 'c-doc-1', { soft: true });
		threads = result.threads;
		lastChanged = String(result.changed);
	}

	// ---------------------------------------------------------------------------
	// Observed state (derived exactly the way the component derives it)
	// ---------------------------------------------------------------------------

	const visibleThreads = $derived(
		threads.filter((thread) => getVisibleComments(thread).length > 0)
	);
	const visibleCommentTotal = $derived(
		threads.reduce((total, thread) => total + getVisibleComments(thread).length, 0)
	);
	const storedCommentTotal = $derived(
		threads.reduce((total, thread) => total + thread.comments.length, 0)
	);
	const softDeleted = $derived(
		threads.flatMap((thread) =>
			thread.comments.filter((comment) => comment.deletedAt).map((comment) => comment.id)
		)
	);
	// Proves the seeded ProseMirror ranges were accepted verbatim: if any of them
	// were wrong, re-anchoring would have rewritten `from`/`to` by now and this
	// readout would disagree with the fixture above.
	const anchorReadout = $derived(
		threads.map((thread) => `${thread.id}:${thread.anchor.from}-${thread.anchor.to}`).join(' ')
	);
</script>

<div style="max-width: 76rem; margin: 0 auto; padding: 1rem; display: grid; gap: 1.5rem;">
	<section style="display: grid; gap: 0.5rem;">
		<h2 style="margin: 0; font-size: 1rem;">Comment lifecycle</h2>
		<div style="height: 30rem;">
			<ReviewEditor
				id="lifecycle-editor"
				bind:value
				bind:threads
				mode="edit"
				currentUserId={CURRENT_USER}
				oncommentcreate={(event) => {
					record('commentcreate', event);
					applyCommentCreate(event);
				}}
				oncommentupdate={(event) => {
					record('commentupdate', event);
					applyCommentUpdate(event);
				}}
				oncommentdelete={(event) => {
					record('commentdelete', event);
					applyCommentDelete(event);
				}}
				onthreaddelete={(event) => {
					record('threaddelete', event);
					applyThreadDelete(event);
				}}
			/>
		</div>
	</section>

	<section style="display: grid; gap: 0.5rem;">
		<h2 style="margin: 0; font-size: 1rem;">Observed state</h2>
		<p data-testid="thread-count" style="margin: 0;">threads: {threads.length}</p>
		<p data-testid="visible-thread-count" style="margin: 0;">
			visible threads: {visibleThreads.length}
		</p>
		<p data-testid="visible-comment-count" style="margin: 0;">
			visible comments: {visibleCommentTotal}
		</p>
		<p data-testid="stored-comment-count" style="margin: 0;">
			stored comments: {storedCommentTotal}
		</p>
		<p data-testid="soft-deleted-ids" style="margin: 0;">soft-deleted: {softDeleted.join(',')}</p>
		<p data-testid="thread-ids" style="margin: 0;">
			thread ids: {threads.map((thread) => thread.id).join(',')}
		</p>
		<p data-testid="seeded-anchors" style="margin: 0;">anchors: {anchorReadout}</p>
		<p data-testid="last-changed" style="margin: 0;">last reducer changed: {lastChanged}</p>
		<p data-testid="counts-at-last-event" style="margin: 0;">at event time: {countsAtLastEvent}</p>
		<button
			type="button"
			data-testid="delete-without-deletedat"
			onclick={softDeleteWithoutTimestamp}
		>
			Soft-delete c-doc-1 without deletedAt
		</button>
		<ul data-testid="event-log" style="margin: 0; padding-left: 1.25rem;">
			{#each events as entry, index (`${index}-${entry}`)}
				<li>{entry}</li>
			{/each}
		</ul>
	</section>
</div>
