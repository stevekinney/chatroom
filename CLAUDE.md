## Project Configuration

- **Language**: TypeScript
- **Package Manager**: bun
- **Add-ons**: prettier, eslint, playwright, mcp

## Purpose

This project exists to kick the tires on the `Chat` component from `@lostgradient/cinder`
(linked from `../cinder`) and drive it with the Anthropic SDK, working toward a best-in-class
chat experience. It is a testbed, not a product — expect the demo route and conversation wiring
to change often as we try things against the real component.

## Working across `chatroom` and `../cinder`

We routinely work in both repos in the same session — editing a Cinder component and its
consumer in `chatroom` side by side, or checking out a Cinder worktree to test an in-progress
change here. `.claude/settings.local.json` already grants access to `../cinder` as an additional
directory.

**The link is a `bun link`, not a registry dependency.** `@lostgradient/cinder` does not appear
in `package.json` — it's resolved via Bun's global link registry:

```bash
# One-time setup, or after checking out a different cinder worktree:
cd ../cinder/packages/components && bun link
cd ../../../chatroom && bun link @lostgradient/cinder
```

`bun link @lostgradient/cinder` re-points the symlink at whatever `bun link` was last run from
inside `cinder/packages/components` — so to test against a worktree instead of the main
checkout, re-run `bun link` from that worktree's `packages/components` and re-run
`bun link @lostgradient/cinder` here. A plain `bun install` does not remove this link.

**No build step required.** Cinder's package exports include a `svelte` condition pointing at
`src/**/*.ts` (not `dist/`), and Vite/SvelteKit respect that condition. Editing a `.svelte` or
`.ts` file under `../cinder/packages/components/src` is picked up immediately by `chatroom`'s
dev server — no `bun run build` in cinder, no watch process. Verified: `bun run dev` here SSRs
and hydrates `<Chat>` straight from Cinder's source with no `server.fs.allow` errors, even
though the symlink resolves outside this project's root.

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
   import { Chat } from '@lostgradient/cinder/chat';
   import '@lostgradient/cinder/chat/styles';
   ```

   Compound components (Chat's own conversation-header, conversation-list, composer-popover,
   etc.) ship their styles from the parent subpath, so importing `chat/styles` covers those too.

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
} from '@lostgradient/cinder/chat';
```

For anything beyond the plain `onsubmit`/`onretry`/`onedit` callback props — streaming,
real-time push, tool-call approval — wire a `ChatAdapter`
(`@lostgradient/cinder/chat` → `chat-adapter.ts`). It's an optional event/transport seam around
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
3. **Sync**, from `chatroom` — run `bun run sync:cinder` (or invoke the `sync-cinder` skill).
   It pulls `../cinder`'s `main` with `--ff-only`, re-establishes the `bun link`, and re-runs
   `lint` + `check` here (pass `--full` to also run `test:e2e`). It refuses to touch `../cinder`
   if that checkout has uncommitted changes or isn't on `main`, and it stops — rather than
   reporting success — if anything fails after the pull, since a red check right after a sync
   means a new cinder commit broke something here.

## Commands

```bash
# chatroom
bun run dev              # dev server (also picks up live cinder source changes)
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
