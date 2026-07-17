# chatroom

A testbed for the `Chat` component from [`@lostgradient/cinder`](https://github.com/stevekinney/cinder), driven by the Anthropic SDK. It's not a product — the demo route and conversation wiring change often as we try things against the real component. See [CLAUDE.md](./CLAUDE.md) for the full picture: the `../cinder` link workflow, the Chat component's style/adapter/conversation-model contracts, the Anthropic SDK streaming seam, and the upstream-issue-filing convention.

## Getting started

```sh
bun install
```

You'll also need:

- An `.env` file with `ANTHROPIC_API_KEY` set (used server-side only, in `src/routes/api/chat/+server.ts`).
- `@lostgradient/cinder` linked from a local `../cinder` checkout, and `conversationalist`/`armorer` linked from a local `../agent-bureau` checkout — see [CLAUDE.md](./CLAUDE.md#working-across-chatroom-and-cinder) for the `bun link` setup.

Then:

```sh
bun run dev
```

## Scripts

| Script                   | What it does                                                                                                                                                                     |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bun run dev`            | Starts the dev server. Picks up live edits from a linked `../cinder` checkout with no build step.                                                                                |
| `bun run build`          | Production build.                                                                                                                                                                |
| `bun run preview`        | Serves the production build locally.                                                                                                                                             |
| `bun run check`          | `svelte-kit sync` + `svelte-check` (typechecking).                                                                                                                               |
| `bun run check:watch`    | Same as `check`, in watch mode.                                                                                                                                                  |
| `bun run check:upstream` | Checks every `upstream: <owner>/<repo>#<issue>` marker in the codebase against `gh` and flags any issue that's closed — those workarounds are candidates to remove.              |
| `bun run lint`           | `prettier --check` + `eslint`.                                                                                                                                                   |
| `bun run format`         | `prettier --write`.                                                                                                                                                              |
| `bun run test:e2e`       | Installs Playwright browsers and runs the e2e suite (builds + previews the app first).                                                                                           |
| `bun run test`           | Alias for `test:e2e`.                                                                                                                                                            |
| `bun run sync:cinder`    | Pulls `../cinder`'s `main`, re-links `@lostgradient/cinder`, and re-verifies (`lint` + `check`; pass `-- --full` to also run `test:e2e`). Run after a filed cinder issue merges. |

`prepare` (`svelte-kit sync`) runs automatically after install and doesn't need to be invoked directly.

## Skills

- **`sync-cinder`** (`.claude/skills/sync-cinder/`) — wraps `bun run sync:cinder`. Trigger with "sync cinder," "update cinder," "pull cinder main," or after confirming a filed cinder issue/PR merged.

## Known upstream friction

Tracked upstream issues against Cinder and agent-bureau — see [CLAUDE.md](./CLAUDE.md#known-upstream-friction) for the current list and the filing convention (`gh issue create`, routed by package: `@lostgradient/cinder` → `stevekinney/cinder`; `conversationalist`/`armorer` → `stevekinney/agent-bureau`). Run `bun run check:upstream` to see whether any referenced issue has since closed.
