---
name: scope-reviewer
description: Review an exact repository target for complete issue or pull-request scope compliance. Use when a change needs an independent requirement matrix, explicit exclusion checks, exact diff and commit verification, source and validation evidence reconciliation, worker-handoff verification, and a read-only approval, changes-requested, or evidence-blocked conclusion before other reviews or delivery.
---

# Scope Reviewer

Run this review for every exact target head before a separate code review and any applicable UI/UX review. Review the target read-only. Decide whether the requested change is complete, stays inside its contract, and has enough evidence for a trustworthy conclusion. Keep scope review separate from code correctness and UI/UX review.

## Establish the review record

Resolve and record these inputs before judging behavior:

1. **Exact target identity.** Record the full current target head, not only a short label. For a named revision, inspect that revision's tree even when the checkout differs. For local work, record the head plus staged, unstaged, and relevant untracked changes that form the target. Record the base used for comparison when one exists.
2. **Complete change history.** Read the complete commit list in the target range and the full diff, including rename and deletion details. Do not infer the full diff from a summary, file list, or worker handoff. Include relevant untracked files in a working-tree review.
3. **Contract and boundaries.** Read the complete issue/PR contract, every amendment or clarification, and every explicit exclusion. Resolve disagreements by source authority; if authority is unavailable or cannot be established, stop at `Evidence blocked`.
4. **Repository guidance.** Resolve the applicable `AGENTS.md` hierarchy from the exact target tree or revision. Read filesystem-ancestor guidance from the filesystem root through the repository ancestors, then read repository guidance from outermost to innermost. Follow every linked product, engineering, specification, policy, and validation source; resolve relative links from the document that names them.
5. **Delivery evidence.** Inspect validation commands, results, artifacts, and the requirement each result actually exercises. A green command is evidence only for its covered behavior.
6. **Dependencies and relationships.** Perform explicit dependency/relationship discovery for every direct, transitive, and related dependency that can affect scope. For each dependency record its relationship, authority/source, exact revision or immutable identity, relevant evidence, and the reload/reconciliation performed before judgment. Reload every dependency at the exact target head; if discovery, authority, identity, evidence, or reconciliation is unavailable or contradictory, stop at `Evidence blocked`.
7. **Worker handoffs.** Collect structured handoffs from every contributing worker, including claimed files, requirement status, validation evidence, unresolved items, and the worker's target identity. Treat handoffs as claims and navigation aids only; reconcile every claim independently against the exact target, dependencies, and sources.

Keep an evidence ledger with the source, exact revision or path, relevant excerpt or observation, and the requirement or boundary it governs. Do not publish review state, alter files, stage or commit changes, switch branches, or start services.

After any context compact, resume, or handoff, discard prior source assumptions and perform a fresh reload of the exact target identity, full diff, commit list, contract and amendments, exclusions, applicable guidance, linked sources, validation evidence, and worker handoffs before continuing or concluding.

## Reconcile claims with the target

Use the exact diff and target tree as primary implementation evidence:

- Verify each claimed requirement in the changed behavior and its tests or validation artifacts. A claim that is absent from the diff does not prove implementation.
- Treat an omitted handoff claim as an omission in the handoff, not as Missing implementation. If the exact diff and governing source prove the requirement, record it as Implemented.
- Treat a handoff that says “complete” as unverified until the diff, target tree, and evidence support every part of the claim.
- Check that validation evidence belongs to the exact head under review and covers the stated requirement. Do not substitute results from another revision.
- Keep explicit exclusions active even when changed behavior appears useful or related. Do not silently amend scope, move work to another issue, or remove behavior.

If the contract, diff, target identity, applicable guidance, or governing source is missing, contradictory, inaccessible, or from an unverified revision, record the precise evidence gap and use `Conclusion: Evidence blocked`. Do not convert an evidence gap into a missing-code finding.

## Build the coverage matrix

Extract every in-scope requirement into a requirement-by-requirement coverage matrix. Include functional requirements, acceptance criteria, required validation, explicit source-backed constraints that the contract makes applicable, and an explicit dependency/relationship reconciliation row covering authority/source, exact revision or identity, relevant evidence, and reload before judgment. Give each row a stable identifier and concise citations to both contract/source evidence and repository/diff evidence.

Use exactly one status per row:

- **Implemented** — the exact target satisfies the whole requirement, with direct diff or target evidence and applicable validation evidence.
- **Partial** — some required behavior is present but a defined part, state, edge case, artifact, or validation obligation is absent or incorrect.
- **Missing** — the requirement is in scope and the exact target provides no sufficient implementation or evidence of it.
- **Unverifiable** — required target, contract, guidance, source, or validation evidence is unavailable or contradictory, so the status cannot be established.

Use `Partial` or `Missing` for actionable in-scope work when the target evidence is complete. Use `Unverifiable` only for an evidence problem; an Unverifiable row forces `Evidence blocked`. Do not omit a requirement because a worker handoff omitted it. Do not mark an excluded behavior as a coverage row; track it separately.

## Inventory out-of-scope behavior

Create a separate **Out-of-scope inventory** for every changed behavior not authorized by the contract or its amendments. For each entry record:

- the behavior and changed path or target evidence;
- the contract, exclusion, or source evidence showing why it is unauthorized;
- the user or parent disposition required;
- exactly these user choices, in this order: `Expand this task`, `Create a follow-up issue`, and `Explicitly defer/accept the risk`.

Do not choose on the user's behalf, remove behavior, or move work while reviewing. Any unresolved out-of-scope entry blocks approval and requires explicit user/parent disposition. In a mixed case, state that disposition is required before branch changes and keep the Missing or Partial in-scope work in the worker loop after that choice. Do not let a handoff, a useful change, or a passing test authorize behavior outside scope.

## Apply the evidence gate

Use this decision order:

1. If exact-head identity, full diff, commit list, contract/amendment authority, applicable guidance, linked governing sources, or required validation evidence cannot be established, return `Conclusion: Evidence blocked` and name the missing or contradictory evidence and the action needed.
2. If any requirement is `Partial` or `Missing`, create an actionable blocking scope finding and return `Conclusion: Request changes`.
3. If the Out-of-scope inventory is non-empty, create a blocking disposition finding and return `Conclusion: Request changes`; do not approve while the user/parent choice is pending.
4. Approve only when every in-scope row is `Implemented`, no row is `Unverifiable`, the out-of-scope inventory is empty, and exact-head identity and validation evidence are explicit.

An evidence block takes precedence over an uncertain implementation judgment. A complete diff can establish implementation even when a handoff is incomplete; a contradictory governing source cannot establish compliance until its precedence is resolved.

## Report

Keep the report concise and put blocking findings first. State the exact target head before the findings. Use this shape for every blocking scope finding:

```text
[Major] Short actionable scope title — path, requirement ID, or target evidence
Concrete scenario: The input, state, or sequence that exposes the scope gap.
Impact: The contract, user, release, or delivery consequence.
Failed guard/control (`failedGuard`): Explain why the existing guard or control failed; this must be a concrete analysis, not an empty placeholder.
Evidence: Tight contract/source and repository/diff/validation citations.
Governing criterion: The exact requirement, amendment, exclusion, or guidance rule.
Smallest reasonable fix boundary: The required local behavior or disposition, not a preferred rewrite.
```

Use `Major` for actionable Missing or Partial scope and unresolved out-of-scope behavior. Use `Blocker` only when the evidence or contract failure is release-stopping or prevents the review from safely proceeding. An out-of-scope finding must name the behavior, evidence, and exactly these pending user choices without selecting one: `Expand this task`, `Create a follow-up issue`, and `Explicitly defer/accept the risk`.

Then include, in order:

1. the requirement-by-requirement coverage matrix with exact statuses and citations;
2. the separate Out-of-scope inventory, including `None` when empty;
3. validation evidence and the reconciliation result for every worker handoff;
4. Missing or contradictory evidence and the action needed, when applicable.

End with exactly one of these lines:

- `Conclusion: Approved` — only after the approval gate passes; also write `No blocking findings.` immediately before it.
- `Conclusion: Request changes` — when actionable Partial or Missing scope, or unresolved out-of-scope behavior, remains.
- `Conclusion: Evidence blocked` — when required contract, target, guidance, source, or validation evidence is unavailable or contradictory.

Do not append another conclusion, approval caveat, or silent scope amendment after the final line.

## Calibration resources

Use [references/fixture-catalog.md](references/fixture-catalog.md) for neutral, deterministic input sections. Give an independent reviewer only one fixture input and this skill; never provide the private expected-results file or another fixture. Compare the independent report with [references/expected-results.json](references/expected-results.json) only after the report is complete. Run [scripts/test_fixtures.py](scripts/test_fixtures.py) to validate the skill's fixture contract.
