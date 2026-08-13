---
name: review-board
description: "Convene the adversarial review board over the current body of work. Four reviewers with veto power must all PASS before anything is marked complete. Trigger on 'review board', 'convene the board', before declaring work done, or when the Stop gate blocks."
allowed-tools: Read, Bash, Grep, Glob, Agent, Edit, Write
---

No body of work in this repo is complete until four adversarial reviewers have each returned PASS on the work **as it currently stands**. You are convening them now.

They are adversaries by design. Their job is to find the reason this is not done, and a round that finds nothing should make you suspicious rather than relieved. This repo's whole purpose is finding real defects; a board that rubber-stamps is worse than no board, because it converts "unreviewed" into "approved".

## Convene

First, establish what is under review. The body of work is the unpushed commits on this branch plus everything uncommitted, scoped to `src`, `scripts`, `package.json`, `bun.lock`, and the config files. Summarize it in a couple of sentences so each reviewer knows what they are looking at.

Then spawn all four **in parallel**, in a single message with multiple tool calls. They are independent and reviewing serially wastes their independence:

- `test-integrity-auditor`
- `harness-skeptic`
- `contract-auditor`
- `a11y-ssr-auditor`

Give each the same brief: what changed, why, which ROADMAP item it serves if any, and how to run the suites. Do not tell them what you believe is correct, and do not pre-empt their findings — a reviewer primed with your conclusion is not an independent one.

## Resolve

A `VERDICT: FAIL` is resolved exactly two ways.

**Fix it.** Make the change, then re-run that reviewer against the updated work. Findings from one reviewer frequently invalidate another's PASS, so if you changed source or tests, re-run every reviewer whose area you touched.

**Refute it with evidence.** Reviewers are wrong sometimes, and three findings were correctly disputed in this repo's history — each time by running an experiment that showed the claim did not hold, not by arguing. If you refute, state the experiment and its output, and record the refutation in the sign-off so the reasoning survives.

What never resolves a finding: rewording it, narrowing the test until it passes, marking it out of scope because the diff is already large, or asserting that it is fine.

If a reviewer cannot be satisfied because of a genuine limitation — the harness cannot exercise the path, the fix needs a decision only the user can make — that is reportable, not skippable. Say which reviewer, which criterion, what you tried, and what would settle it, then ask the user how to proceed. Do not write a sign-off around it.

## Record the sign-off

Only once all four have returned PASS on the current state of the work. Compute the same hash the gate uses and write the file:

```bash
bash .claude/hooks/review-board-signoff.sh
```

That script recomputes the work hash, refuses to write if the tree has changed since you last looked, and prompts you for the four verdict lines. Do not hand-write the sign-off file to get past the gate — the gate exists to protect the work, and forging it is the one failure mode nobody else will catch.

If the work changes after a sign-off, the hash changes and the sign-off no longer applies. That is intended. Re-run the reviewers whose areas moved.

## Report to the user

State each reviewer's verdict, the findings that were fixed and how, the findings that were refuted and with what evidence, and anything left unresolved with the reason. If the board found nothing at all, say so plainly and note what they examined, so a thin review is visible as a thin review rather than a clean bill of health.
