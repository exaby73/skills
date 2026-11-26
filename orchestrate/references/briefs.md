# Briefs

A delegate knows nothing but its brief and the repository. Write each brief so a fresh agent could do the work with no other context: link sources instead of summarising them, and say what is settled so it doesn't reopen it.

## Every Brief

```markdown
Goal: <the outcome, in one sentence, and the issue it closes>

Settled: <owner decisions and register entries that bind this work, by title and link; what not to reopen>

Read first: AGENTS.md, <docs it routes to for this area>, <the issue>, <files>

Process: <the Cadre command: track or quick>; branch from <base> in your own worktree; open the pull request <as a draft into the open train | into the default branch>; run the checks AGENTS.md lists before every push.

Guardrails:
- Stage named paths only; never push to the default branch; never merge.
- <the machine rules from machine.md that apply>
- <the secrets rules from secrets.md, when a secret is involved>

Memory: keep working notes in `.scratch/` in your worktree; write what must last into the doc it belongs to, through docs-governance; save nothing about this project to your own persistent memory.

Report: <the report line below for this role>, as the last line.
```

## Builder

Add the acceptance criteria, or link the Cadre track that holds them. Report line: `PR <url>, head <SHA>`.

## Reviewer

A reviewer is never the agent that built the change. Add:

- the pull request, the head SHA to review, and the round;
- the fixed point: `origin/<base>` for the first round and a final full round, or the last reviewed head for a later round, which reviews only the fix commits;
- when the change touches sign-in, access control, money, or deleting data, that it gets one more full round after the others come back clean;
- COMMENT-only: one review, no approval or request for changes;
- the grading: High, Medium, or Low, each with its file and line, a failure scenario, and a fix.

Report line: `Review <url> of <SHA>: <n> high, <n> medium, <n> low`, then one line per finding.

## Fixer

The builder, when it's still running, or a fresh agent. Add each finding to fix, as the reviewer wrote it, with the review's link, and the Lows to fix in the same push. Report line: `PR <url>, head <SHA>`, with one line per finding saying how it was fixed or why it stays.
