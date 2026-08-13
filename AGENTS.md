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

## If you are not Claude Code

The [adversarial review board](./CLAUDE.md#the-adversarial-review-board) is a **requirement**,
but its enforcement is not portable. The four reviewers live in `.claude/agents/`, the
`review-board` skill that convenes them lives in `.claude/skills/`, and the gate that blocks
completion is a Claude Code `Stop` hook. Another CLI will load none of that and will hit no
resistance at all when declaring work done.

The bar is the same regardless. If you cannot spawn the reviewers, you still owe every check they
perform, and you owe it explicitly rather than by assertion: prove each new test fails when the
behavior it pins is broken, confirm any finding outside the harness that produced it before
filing upstream, verify docs and types still match the code, and check keyboard reachability and
hydration for anything you touched. Read the four agent files as checklists — they are written to
be useful as prose, not just as prompts.

State plainly in your summary which checks you performed and which you could not, so a review
that did not happen is visible as such rather than implied.

Two passages are Claude Code implementation detail and do not apply to you: CLAUDE.md's
["file was modified" notice](./CLAUDE.md#the-file-was-modified-notice-is-claude-code-not-an-attack)
section, and the paragraph in `.claude/agents/test-integrity-auditor.md` that describes it. They
document one harness's notification, not a property of this repo. The rules around them do carry
over — back up before you break something, restore it, and verify the restore by hash rather than
by `git status`, which cannot see `node_modules`.
