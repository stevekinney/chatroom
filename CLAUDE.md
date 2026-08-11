## Project Configuration

- **Language**: TypeScript
- **Package Manager**: bun
- **Add-ons**: prettier, eslint, playwright, mcp

## Purpose

This project exists to kick the tires on the `Chat` component from `@lostgradient/chat`
(installed from npm) and drive it with the Anthropic SDK, working toward a best-in-class chat
experience. It is a testbed, not a product — expect the demo route and conversation wiring to
change often as we try things against the real component.

As of Cinder 0.16, `Chat` lives in its own package, `@lostgradient/chat`, which peer-depends on
`@lostgradient/cinder` (the design primitives), `conversationalist`, `zod`, and `svelte`.
chatroom installs both `@lostgradient/*` packages from npm and provides those peers;
`@lostgradient/cinder` still supplies the base styles, it's just no longer where `Chat` itself
comes from.

## Working across `chatroom` and `../cinder`

We routinely work in both repos in the same session — `../cinder` is where Cinder/Chat fixes get
made (the `ralph-pipeline` skill drives that), and `chatroom` is where we exercise the result.
`.claude/settings.local.json` already grants access to `../cinder` as an additional directory.

**chatroom consumes the _published_ npm packages, not a `bun link`.** `@lostgradient/chat` and
`@lostgradient/cinder` are ordinary `dependencies` in `package.json`, pinned to their published
versions; `conversationalist` and `zod` sit alongside them as the peers Chat requires. This is
deliberate: consuming the real published tarballs — a complete `dist` + `dist/server`, the same
artifacts any downstream app gets — is the point. A live-source `bun link` silently _masks_
packaging and SSR/hydration edge cases (it was hiding the cinder#756 hydration mismatch, which
only surfaced once we switched to the published packages). No `bun link`, no per-package CSS
build, and no `vite.config.ts` SSR-condition workaround: published packages ship complete
`dist`/`dist/server`, so the default export conditions resolve cleanly for both client and SSR.

To move to a newer Cinder/Chat release after it publishes, bump both and re-verify — either
directly or via `bun run sync:cinder` (see [the resolve loop below](#filing-and-resolving-upstream-issues)):

```bash
bun update @lostgradient/cinder @lostgradient/chat --latest
bun run lint && bun run check
```

## Using the Chat component

One required step, easy to get wrong silently: **base styles load once, at the app entry**
(`src/routes/+layout.svelte`), before any component module:

```ts
import '@lostgradient/cinder/styles';
import '@lostgradient/cinder/styles/guard'; // dev-only: warns if the base didn't load first
```

`styles/guard` checks for a `--cinder-base-loaded` custom property on `:root` in dev and
warns if it's missing — it's a no-op in production. Getting the order wrong (component CSS
before base CSS) creates the cascade `@layer`s in the wrong order and produces no error, just
quietly-wrong styling.

Component styles ship with the components themselves: as of `@lostgradient/chat@0.1.1`, each
component's own module imports its CSS (preserved by the package's `sideEffects`), so
`import { Chat } from '@lostgradient/chat'` — or any compound subpath like
`@lostgradient/chat/conversation-list` — brings its styles along. Do **not** add explicit
`@lostgradient/chat/styles` imports; that was the cinder#754 workaround, removed once the fix
shipped.

Conversation data flows through **`conversationalist`**, which chat now owns as a regular
dependency and re-exports (types, builders, and helpers like `isJSONValue`) — client code
should import those through `@lostgradient/chat`, not conversationalist directly. chatroom
ALSO declares `conversationalist` as its own dependency (re-added 2026-08 after the cinder#753
cleanup removed it): the API route imports `conversationalist/adapters/anthropic` and
`conversationalist/schemas`, which chat does not re-export, and per chat's own guidance an app
using conversationalist beyond the re-export surface keeps its own dependency rather than
leaning on hoisting. Its range must stay **identical** to the range chat declares, so both resolve
the same instance — `bun run check:peers` enforces that, and the sync runs it, so a release that
moves chat's floor fails here until our range follows. `zod` remains a
direct dependency only because our armorer tool schemas use it, not for Chat. Build
transcripts with the re-exported builders rather than hand-rolling `ConversationHistory`
objects:

```ts
import {
	Chat,
	appendAssistantMessage,
	appendUserMessage,
	createConversation
} from '@lostgradient/chat';
```

For anything beyond the plain `onsubmit`/`onretry`/`onedit` callback props — streaming,
real-time push, tool-call approval — wire a `ChatAdapter`
(`@lostgradient/chat` → `chat-adapter.ts`). It's an optional event/transport seam around
the same `conversation` prop, not a second conversation model; only `sendMessage` is required.

## Driving Chat with the Anthropic SDK

`ANTHROPIC_API_KEY` lives in `.env` and **must stay server-side**. The Anthropic SDK belongs in
a SvelteKit `+server.ts` route (or a `ChatAdapter`'s `sendMessage`/`subscribe` calling out to
one) that streams tokens back to the client — never import `@anthropic-ai/sdk` from a
`.svelte` file or anything that ships to the browser. Route the response through Chat's
streaming API (`beginStreaming`/`pushToken`/`endStreaming`, or the adapter's
`onStreamBegin`/`onTokenPush`/`onStreamEnd` push handlers) rather than waiting for the full
completion before rendering.

## Known upstream friction

These complaints have standing GitHub issues — don't re-litigate or re-file them, check status
instead:

- [stevekinney/cinder#863](https://github.com/stevekinney/cinder/issues/863) — **fixed and
  verified** in `@lostgradient/chat@0.4.0`: chat ships conversationalist `^0.5.0` and
  re-exports `prependMessages`/`buildMessage` (while keeping `createConversation`); the
  `$state.snapshot` double-casts and the hand-rolled prepend are gone.
- [stevekinney/cinder#753](https://github.com/stevekinney/cinder/issues/753) — **fixed and
  verified** in `@lostgradient/chat@0.2.0`: conversationalist/zod moved to chat's own
  dependencies and `isJSONValue` is re-exported; chatroom dropped its direct
  `conversationalist` install.
- [stevekinney/cinder#754](https://github.com/stevekinney/cinder/issues/754) — **fixed and
  verified** in `@lostgradient/chat@0.1.1`: components self-import their CSS. Listed here only
  so it doesn't get re-filed; the explicit `/styles` imports it used to require are gone.
- The `/exercises` routes (one per Chat surface area) exist to smoke out this kind of friction;
  building them filed cinder#778–786, cinder#863–864, and agent-bureau#244–245 — all since
  resolved.

## Filing and resolving upstream issues

When something in an upstream dependency gets in the way, file it — `gh issue create` against
the repo that owns it, with a clear repro and the requested fix (see #753/#754 above for the
shape). Don't work around it locally or patch-monkey it here. Route by package:

- `@lostgradient/cinder` → `stevekinney/cinder`
- `conversationalist` or `armorer` → `stevekinney/agent-bureau` (both packages live in that
  monorepo, under `packages/conversationalist` and `packages/armorer`)

The full loop from filed issue to updated `chatroom` (described here for Cinder; the
agent-bureau loop is the same shape, just without a `sync:*` script yet — sync manually):

1. **File** the issue against the owning repo.
2. **Fix and merge**, driven from inside `../cinder` (not here) — the `ralph-pipeline` skill runs
   the worktree → work agent → PR → CI/review-stabilization → merge loop against a task file
   derived from the open issues.
3. **Publish** the fix (`@lostgradient/cinder` and/or `@lostgradient/chat`) to npm — chatroom
   consumes the registry, not `../cinder`'s working tree, so a merged-but-unpublished fix does
   not reach here.
4. **Sync**, from `chatroom` — run `bun run sync:cinder` (or invoke the `sync-cinder` skill).
   It bumps both `@lostgradient/*` packages to their latest published versions
   (`bun update … --latest`) and re-runs `lint` + `check` + `check:upstream` + `check:peers` here
   (pass `--full` to also run `test:e2e`). It stops — rather than reporting success — if anything
   fails after the bump, since a red check right after a sync means a new release broke
   something here.
5. **Clean up**, in the same session the sync happens. `check:upstream` failing means a
   workaround's referenced issue has closed: remove the workaround (marker comment, extra
   import, cast, whatever it guarded), re-verify, and commit the cleanup — or, if the problem
   still reproduces despite the closed issue, reopen the issue instead and leave the marker in
   place. Never leave a stale workaround with a closed-issue marker in the tree.

**Every local workaround carries an `upstream:` marker.** When a workaround genuinely can't be
avoided while waiting on a fix, tag it where it lives with a code comment of the form
`upstream: <owner>/<repo>#<issue>`. That marker is what `bun run check:upstream` scans for — an
untagged workaround is invisible to the cleanup loop and will outlive its fix. (Don't write a
concrete `upstream: owner/repo#N` reference in prose or docs unless it marks a real, live
workaround — the scanner treats every match as one.)

**Verify state after filing or commenting — don't assume a comment means "tracked."** A GitHub
issue can be closed by something else (a bulk sweep tied to an unrelated release, another
session, a maintainer skimming) immediately after your comment lands, even when that comment
says the bug is still present. After `gh issue create` or `gh issue comment`, check the actual
state with `gh issue view <number> --repo <owner/repo> --json state`. If your comment describes
something that still reproduces and the issue shows closed, reopen it (`gh issue reopen <number>
--repo <owner/repo> --comment '...'`) with a short note — a closed issue is not a valid record of
an unresolved bug, no matter what the last comment on it says.

## Commands

```bash
# chatroom
bun run dev              # dev server
bun run sync:cinder      # bump @lostgradient/cinder + @lostgradient/chat to latest, re-verify
bun run check             # svelte-kit sync + svelte-check
bun run check:upstream    # every `upstream:` marker's issue is still open
bun run check:peers       # re-declared deps still match their owning package's range
bun run lint              # prettier --check + eslint
bun run format             # prettier --write
bun run test:e2e           # playwright

# ../cinder (packages/components is the published @lostgradient/cinder package)
bun run --filter=@lostgradient/cinder test
bun run --filter=@lostgradient/cinder typecheck
bun run --filter=@lostgradient/cinder components:generate   # after changing component metadata/examples/exports
```

---

You are able to use the Svelte MCP server, where you have access to comprehensive Svelte 5 and SvelteKit documentation. Here's how to use the available tools effectively:

## Available Svelte MCP Tools:

### 1. list-sections

Use this FIRST to discover all available documentation sections. Returns a structured list with titles, use_cases, and paths.
When asked about Svelte or SvelteKit topics, ALWAYS use this tool at the start of the chat to find relevant sections.

### 2. get-documentation

Retrieves full documentation content for specific sections. Accepts single or multiple sections.
After calling the list-sections tool, you MUST analyze the returned documentation sections (especially the use_cases field) and then use the get-documentation tool to fetch ALL documentation sections that are relevant for the user's task.

### 3. svelte-autofixer

Analyzes Svelte code and returns issues and suggestions.
You MUST use this tool whenever writing Svelte code before sending it to the user. Keep calling it until no issues or suggestions are returned.

### 4. playground-link

Generates a Svelte Playground link with the provided code.
After completing the code, ask the user if they want a playground link. Only call this tool after user confirmation and NEVER if code was written to files in their project.
