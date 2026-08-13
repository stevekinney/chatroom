# AGENTS.md

See [CLAUDE.md](./CLAUDE.md) for project guidance — purpose, the `../cinder` link and workflow,
the Chat component's style/adapter/conversation-model contracts, the ReviewEditor component's
peer set and anchor coordinate spaces, the Anthropic SDK server-side seam, known upstream issues
(Cinder and agent-bureau), and commands. It applies equally regardless of which agent CLI is
driving.

The rule most likely to change what you do: **a bug in an upstream package we own is the next
task, not an obstacle to route around.** File it, then immediately switch into that repo, fix it,
drive it to merge, cut a release, sync the dependency here, and only then resume. See
[Filing and resolving upstream issues](./CLAUDE.md#filing-and-resolving-upstream-issues) for the
full loop and for what to do when it cannot finish.

See also [ROADMAP.md](./ROADMAP.md) for what still needs coverage, with acceptance criteria per
item.
