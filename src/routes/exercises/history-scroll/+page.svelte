<script lang="ts">
	import {
		Chat,
		DEFAULT_SCROLL_CONFIGURATION,
		appendMessages,
		createConversation,
		type ChatAdapter,
		type ChatScrollStateChangeEvent,
		type ChatUnreadIndicatorChangeEvent,
		type ConversationHistory,
		type Message,
		type MessageRole
	} from '@lostgradient/chat';

	// Minimal local stand-in for `MessageInput` — the exercise only ever
	// prepends plain text messages, so there is no need to pull in the wider
	// (multi-modal) content union just to satisfy a type.
	type ArchivedMessageInput = { role: MessageRole; content: string };

	// Deliberately large and verbose: the scroll-state assertions depend on
	// the transcript overflowing the viewport (`isAtBottom` treats a
	// non-overflowing transcript as always "at bottom", regardless of
	// scrollTop), so a short seed would make `scrollToTop` a no-op.
	const SEED_COUNT = 60;
	const PAGE_SIZE = 4;
	const TOTAL_PAGES = 3;

	type HistoryMode = 'adapter' | 'callback';

	/**
	 * Builds `TOTAL_PAGES` batches of older messages, oldest page last. Each
	 * page's messages are already in oldest-to-newest order, so prepending a
	 * page's array directly onto the front of `conversation.ids` preserves
	 * chronological order.
	 */
	function buildHistoryPages(label: string): ArchivedMessageInput[][] {
		const pages: ArchivedMessageInput[][] = [];
		for (let page = 0; page < TOTAL_PAGES; page += 1) {
			const messages: ArchivedMessageInput[] = [];
			for (let index = 0; index < PAGE_SIZE; index += 1) {
				const globalIndex = page * PAGE_SIZE + index;
				messages.push({
					role: globalIndex % 2 === 0 ? 'user' : 'assistant',
					content: `${label} archived message ${globalIndex + 1}`
				});
			}
			pages.push(messages);
		}
		return pages;
	}

	function seedConversation(): ConversationHistory {
		const seedInputs: ArchivedMessageInput[] = [];
		for (let index = 0; index < SEED_COUNT; index += 1) {
			seedInputs.push({
				role: index % 2 === 0 ? 'user' : 'assistant',
				content: `Live message ${index + 1} — enough padding text to give each row real height so the transcript reliably overflows the viewport and scrolling has somewhere to go.`
			});
		}
		return appendMessages(createConversation({ id: 'history-scroll-demo' }), ...seedInputs);
	}

	// `conversationalist`'s builders only ever append; there is no exported
	// `prependMessages` mirroring `appendMessages`, even though Chat's own
	// `onloadhistory` docs say "the consumer prepends compatible messages into
	// `conversation`". History pagination is therefore hand-rolled here by
	// constructing `Message` objects directly and renumbering `position` to
	// match the new `ids` order.
	// upstream: stevekinney/agent-bureau#244
	function prependMessages(
		conversation: ConversationHistory,
		inputs: ArchivedMessageInput[]
	): ConversationHistory {
		const timestamp = new Date().toISOString();
		const prepended: Message[] = inputs.map((input) => ({
			id: crypto.randomUUID(),
			role: input.role,
			content: input.content,
			position: 0,
			createdAt: timestamp,
			metadata: {},
			hidden: false
		}));

		const ids = [...prepended.map((message) => message.id), ...conversation.ids];
		const messages: Record<string, Message> = { ...conversation.messages };
		for (const message of prepended) messages[message.id] = message;
		ids.forEach((id, index) => {
			const existing = messages[id];
			if (existing) messages[id] = { ...existing, position: index };
		});

		return { ...conversation, ids, messages, updatedAt: timestamp };
	}

	let chat: ReturnType<typeof Chat> | undefined;

	let mode = $state<HistoryMode>('adapter');
	let pagesQueue = $state<ArchivedMessageInput[][]>(buildHistoryPages('Adapter'));
	let moreHistoryAvailable = $state(true);
	let conversation = $state<ConversationHistory>(seedConversation());
	let eventLog = $state<string[]>([]);

	let atBottom = $state(true);
	let unreadCount = $state(0);
	let newMessageIndicatorVisible = $state(false);

	let bottomThreshold = $state(DEFAULT_SCROLL_CONFIGURATION.bottomThreshold);
	let jumpThreshold = $state(DEFAULT_SCROLL_CONFIGURATION.jumpThreshold);

	function pushLog(entry: string): void {
		eventLog = [...eventLog, entry].slice(-6);
	}

	function resetMode(next: HistoryMode): void {
		mode = next;
		pagesQueue = buildHistoryPages(next === 'adapter' ? 'Adapter' : 'Callback');
		moreHistoryAvailable = true;
		conversation = seedConversation();
		atBottom = true;
		lastLoggedAtBottom = true;
		unreadCount = 0;
		newMessageIndicatorVisible = false;
		eventLog = [];
	}

	function simulateIncomingMessage(): void {
		conversation = appendMessages(conversation, {
			role: 'assistant',
			content: `Incoming update #${conversation.ids.length + 1}`
		});
	}

	async function loadNextPage(source: 'adapter' | 'callback'): Promise<{ hasMore: boolean }> {
		const nextPage = pagesQueue.at(0);
		if (!nextPage) {
			pushLog(`${source}: no pages remain`);
			return { hasMore: false };
		}

		conversation = prependMessages(conversation, nextPage);
		pagesQueue = pagesQueue.slice(1);
		const hasMore = pagesQueue.length > 0;
		moreHistoryAvailable = hasMore;
		pushLog(`${source}: loaded a page, hasMore=${hasMore}`);
		return { hasMore };
	}

	// Only consulted by Chat when `mode === 'adapter'` — see the conditional
	// spread below, which omits `loadOlderMessages` entirely in callback mode
	// so `onloadhistory` (not the adapter) drives the history trigger.
	const adapter = $derived<ChatAdapter>({
		sendMessage: async (message) => {
			conversation = appendMessages(conversation, message);
			const text = typeof message.content === 'string' ? message.content : 'attachment received';
			conversation = appendMessages(conversation, { role: 'assistant', content: `Echo: ${text}` });
		},
		...(mode === 'adapter' ? { loadOlderMessages: async () => loadNextPage('adapter') } : {})
	});

	async function handleLoadHistory(): Promise<void> {
		await loadNextPage('callback');
	}

	// `atBottom`/`unreadCount`/`newMessageIndicatorVisible` are documented as
	// bindable on `Chat`, but the shipped type declarations don't mark them
	// bindable (svelte-check rejects `bind:atBottom` etc. even though the
	// component implements `$bindable()` internally).
	// upstream: stevekinney/cinder#786
	// Chat fires these change events at the same sites it mutates the
	// bindable props, so mirroring them into local state here reproduces the
	// same two-way sync without `bind:`.
	//
	// `onscrollstatechange` fires once per native `scroll` tick, not once per
	// meaningful transition — a single smooth scroll across this exercise's
	// long transcript produces well over a hundred events, nearly all
	// reporting the same unchanged `atBottom` value. Logging every one of
	// them would blow the event log's fixed window out with duplicates
	// before anything else gets a chance to show up in it, so only log on an
	// actual value change (the live `atBottom` status above still reflects
	// every event, unconditionally).
	// Matches `atBottom`'s own initial value above rather than reading
	// `atBottom` directly here — both are plain non-reactive bookkeeping, so
	// this avoids Svelte's "state referenced locally" warning for what would
	// otherwise look like a one-time capture of reactive state.
	let lastLoggedAtBottom = true;

	function handleScrollStateChange(event: ChatScrollStateChangeEvent): void {
		atBottom = event.atBottom;
		if (event.atBottom === lastLoggedAtBottom) return;

		lastLoggedAtBottom = event.atBottom;
		pushLog(`scrollstatechange: atBottom=${event.atBottom}`);
	}

	function handleUnreadIndicatorChange(event: ChatUnreadIndicatorChangeEvent): void {
		unreadCount = event.unreadCount;
		newMessageIndicatorVisible = event.newMessageIndicatorVisible;
		pushLog(
			`unreadindicatorchange: unreadCount=${event.unreadCount} visible=${event.newMessageIndicatorVisible}`
		);
	}

	function handleJumpToLatest(): void {
		pushLog('jumptolatest');
	}
</script>

<div style="height: 100dvh; display: flex; flex-direction: column; gap: 0.5rem;">
	<div
		style="padding: 0.5rem 1rem; display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: center; border-bottom: 1px solid var(--cinder-border);"
	>
		<fieldset style="display: flex; gap: 0.5rem; align-items: center;">
			<legend>History loading mode</legend>
			<label>
				<input
					type="radio"
					name="history-mode"
					checked={mode === 'adapter'}
					onchange={() => resetMode('adapter')}
					data-testid="history-scroll-mode-adapter"
				/>
				adapter.loadOlderMessages
			</label>
			<label>
				<input
					type="radio"
					name="history-mode"
					checked={mode === 'callback'}
					onchange={() => resetMode('callback')}
					data-testid="history-scroll-mode-callback"
				/>
				onloadhistory
			</label>
		</fieldset>

		<label>
			bottomThreshold
			<input
				type="number"
				bind:value={bottomThreshold}
				data-testid="history-scroll-bottom-threshold"
			/>
		</label>
		<label>
			jumpThreshold
			<input type="number" bind:value={jumpThreshold} data-testid="history-scroll-jump-threshold" />
		</label>

		<button
			type="button"
			onclick={() => chat?.scrollToTop()}
			data-testid="history-scroll-scroll-top"
		>
			Scroll to top
		</button>
		<button
			type="button"
			onclick={() => chat?.scrollToBottom()}
			data-testid="history-scroll-scroll-bottom"
		>
			Scroll to bottom
		</button>
		<button
			type="button"
			onclick={simulateIncomingMessage}
			data-testid="history-scroll-simulate-incoming"
		>
			Simulate incoming message
		</button>
	</div>

	<dl
		style="display: flex; flex-wrap: wrap; gap: 0.5rem 1.5rem; padding: 0 1rem; margin: 0;"
		data-testid="history-scroll-status"
	>
		<div>
			<dt style="display:inline;">atBottom:</dt>
			<dd style="display:inline; margin:0;" data-testid="history-scroll-at-bottom">{atBottom}</dd>
		</div>
		<div>
			<dt style="display:inline;">unreadCount:</dt>
			<dd style="display:inline; margin:0;" data-testid="history-scroll-unread-count">
				{unreadCount}
			</dd>
		</div>
		<div>
			<dt style="display:inline;">newMessageIndicatorVisible:</dt>
			<dd style="display:inline; margin:0;" data-testid="history-scroll-indicator-visible">
				{newMessageIndicatorVisible}
			</dd>
		</div>
		<div>
			<dt style="display:inline;">moreHistoryAvailable:</dt>
			<dd style="display:inline; margin:0;" data-testid="history-scroll-more-history">
				{moreHistoryAvailable}
			</dd>
		</div>
		<div>
			<dt style="display:inline;">pagesRemaining:</dt>
			<dd style="display:inline; margin:0;" data-testid="history-scroll-pages-remaining">
				{pagesQueue.length}
			</dd>
		</div>
		<div>
			<dt style="display:inline;">messageCount:</dt>
			<dd style="display:inline; margin:0;" data-testid="history-scroll-message-count">
				{conversation.ids.length}
			</dd>
		</div>
	</dl>

	<ul
		style="margin: 0; padding: 0 1rem; list-style: none; font-size: 0.8rem; color: var(--cinder-text-muted, gray);"
		data-testid="history-scroll-event-log"
	>
		{#each eventLog as entry, index (index)}
			<li data-testid="history-scroll-event-log-item">{entry}</li>
		{/each}
	</ul>

	<div style="flex: 1; min-height: 0;">
		<Chat
			bind:this={chat}
			id="history-scroll-chat"
			{conversation}
			{adapter}
			{atBottom}
			{unreadCount}
			{newMessageIndicatorVisible}
			{bottomThreshold}
			{jumpThreshold}
			{moreHistoryAvailable}
			loadEarlierLabel="Load earlier messages (custom)"
			loadingEarlierLabel="Loading earlier messages (custom)"
			onloadhistory={handleLoadHistory}
			onscrollstatechange={handleScrollStateChange}
			onunreadindicatorchange={handleUnreadIndicatorChange}
			onjumptolatest={handleJumpToLatest}
		/>
	</div>
</div>
