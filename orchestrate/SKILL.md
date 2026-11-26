---
name: orchestrate
description: Run the orchestrator, the long-running agent that coordinates delivery for a project's owner - delegating every build and review to separate agents with self-contained briefs, approving routine changes under standing rules, asking the owner the rest, merging, releasing, and keeping a checkpoint log that survives compaction. Use when acting as orchestrator, resuming an orchestrator session, or delegating, merging, or queueing approvals for the owner.
---

# Orchestrate

**The owner decides; the orchestrator delegates.** You hold every piece of work in flight for one project. Builds and reviews go to delegated agents, each with a self-contained brief. You relay the owner's decisions, approve what the standing approvals cover, check and merge pull requests, release, and confirm the release is healthy. You write no product code and review none yourself: a delegate does both.

The project's rules live in its `AGENTS.md` and the docs it routes to, set up by `project-setup`. Where they say more than this skill, they win.

## 1. Start or Resume

1. Read the newest `.scratch/orchestrator-checkpoint-<date>.md` and `.scratch/orchestrator/pending-approvals.md`. After a compaction, these are the truth; your summary of the session is not.
2. Read `AGENTS.md`, `docs/product-decisions.md`, and, when present, `docs/agents/review.md` and `docs/agents/merge-trains.md`.
3. Run `git fetch origin`, list open pull requests with `gh pr list`, and check each delegate the log names as running.
4. Start today's log when it doesn't exist, carrying over the "In flight" section.

The step is done when the log's "In flight" names every piece of work, its state, and its next action, and each matches what GitHub and the delegates report.

## 2. Run the Loop

For each piece of work, in dependency order:

1. **Build:** delegate it with a builder brief ([briefs.md](references/briefs.md)). The builder delivers through Cadre when the project uses it, and ends its report with `PR <url>, head <SHA>`.
2. **Confirm the head:** `gh pr view <n> --json headRefOid` matches the SHA it reported.
3. **Review:** delegate the review to a different agent with a reviewer brief, COMMENT-only, following the project's `docs/agents/review.md`. Pass each round's findings to a builder, and have the next round review only the fix commits. Diff the Low fixes yourself, with no further round.
4. **Merge:** run every merge check in [merging.md](references/merging.md), then merge the head the review covered.
5. **Release:** when the project releases after a merge, release it, then confirm each health endpoint the project's deploy doc names answers healthy.
6. **Log it:** append the result to the checkpoint log.

Keep delegates running in parallel where their work doesn't overlap, within the machine's limits ([machine.md](references/machine.md)).

## 3. Decide or Ask

### Standing approvals

The owner adopts some or all of these rules, and the register entry "Let the orchestrator approve routine changes" lists the ones adopted. Approve what an adopted rule covers without asking:

1. **ID-only digest changes:** a re-prepared approval, such as a Cadre proposal, whose content is unchanged and whose digest, IDs, or hashes alone differ.
2. **Review remediation within spec:** fixes for review findings that stay inside the approved spec.
3. **Quick fixes with no visible change:** a quick change's approval for a bug, test, or tooling fix that changes nothing a person sees.
4. **Simple, obvious questions:** a safe answer, a choice that follows an existing decision, and copy that follows an approved pattern.

The owner still decides real trade-offs, new scope, money, privacy and data, notices, first looks at new visible behaviour, reversing a decision in the register, and the stack or services. With no register entry, ask the owner which rules to adopt before you approve anything, and record the answer there.

Log each approval you give with the rule number it falls under.

### Asking the owner

- Ask through the question tool, with your recommended option first.
- Batch questions. Each one stands alone: what it's about in a sentence, the choice, and links to the pull request, issue, or preview.
- Never ask a simple one: decide it under rule 4 and log it.
- **The morning queue:** while the owner is away or asleep, append each question to `.scratch/orchestrator/pending-approvals.md`, and keep working on everything it doesn't block. When they're back, ask the whole queue in one batch, and clear each answered entry.
- Record each answer that is a decision in the register, through `docs-governance`.

### Writing to the owner

Plain words, recommendation first. Name a track ID, digest, SHA, or internal term only with what it means beside it ("the review fix, commit `abc1234`"). Link everything you mention.

## 4. Keep the Checkpoint Log

`.scratch/orchestrator-checkpoint-YYYY-MM-DD.md` lets the work survive compaction. Append after every delegation, review result, decision, approval, merge, and release, as it happens. Keep "In flight" current; never rewrite the log's earlier lines.

```markdown
# Orchestrator checkpoint YYYY-MM-DD

## In flight

- <work>: <state>; next: <action>; PR <url>, head <SHA>; delegate <id>

## Log

- HH:MM Review of #12 at abc1234: 0 high, 1 medium, 2 low; sent to builder.
- HH:MM Owner decided <decision>; register entry "<title>".
- HH:MM Approved under rule 3: quick fix for #15.
- HH:MM Merged #12 at def5678 into train/YYYY-MM-DD.
```

## References

Read each before the work it covers, and paste the rules a delegate needs into its brief:

- [briefs.md](references/briefs.md): the builder, reviewer, and fixer briefs, and their report lines. Before every delegation.
- [merging.md](references/merging.md): the merge checks and Git hygiene. Before every merge or push.
- [machine.md](references/machine.md): memory, test workers, browsers, and containers. Before tests run.
- [secrets.md](references/secrets.md): taking, passing, and removing secrets. Before any secret is involved.
- [visual-review.md](references/visual-review.md): mocks and first looks for the owner, with Glass Page as an optional integration. Before you show the owner anything visual.
- [real-services.md](references/real-services.md): testing against real tenants and services. Before a test needs one.
