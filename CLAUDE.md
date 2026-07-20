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

Two required steps, both easy to get wrong silently — see the two upstream issues below before
assuming either is optional:

1. **Base styles load once, at the app entry** (`src/routes/+layout.svelte`), before any
   component styles:

   ```ts
   import '@lostgradient/cinder/styles';
   import '@lostgradient/cinder/styles/guard'; // dev-only: warns if the base didn't load first
   ```

   `styles/guard` checks for a `--cinder-base-loaded` custom property on `:root` in dev and
   warns if it's missing — it's a no-op in production. Getting the order wrong (component CSS
   before base CSS) creates the cascade `@layer`s in the wrong order and produces no error, just
   quietly-wrong styling.

2. **Each component's styles are imported alongside the component**, currently required per
   component:

   ```ts
   import { Chat } from '@lostgradient/chat';
   import '@lostgradient/chat/styles';
   ```

   Compound components (Chat's own conversation-header, conversation-list, composer-popover,
   etc.) ship their styles from the parent subpath, so importing `@lostgradient/chat/styles`
   covers those too.

Conversation data flows through **`conversationalist`**, which Chat re-exports type-wise but
which we currently must also install directly (`conversationalist`, `zod`) per Cinder's own
docs — see [Known upstream friction](#known-upstream-friction). Build transcripts with the
re-exported builders rather than hand-rolling `ConversationHistory` objects:

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

Two Cinder architecture complaints have standing GitHub issues — don't re-litigate or re-file
these, check status instead:

- [stevekinney/cinder#753](https://github.com/stevekinney/cinder/issues/753) — Chat currently
  requires host apps to separately install `conversationalist` and `zod`, which is a
  peer-dependency-in-disguise. The ask is for Cinder to fully own that dependency and re-export
  what's needed.
- [stevekinney/cinder#754](https://github.com/stevekinney/cinder/issues/754) — components
  require a separate, order-sensitive `@lostgradient/cinder/<component>/styles` import per
  component, which silently misbehaves if forgotten or misordered. The ask is for components to
  bring their own CSS automatically.

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
   (`bun update … --latest`) and re-runs `lint` + `check` here (pass `--full` to also run
   `test:e2e`). It stops — rather than reporting success — if anything fails after the bump,
   since a red check right after a sync means a new release broke something here.

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
