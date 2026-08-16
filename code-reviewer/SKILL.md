---
name: code-reviewer
description: Review local working-tree changes or remote pull requests for concrete correctness, architecture, security, data-integrity, contract, maintainability, and test risks. Use when asked to review code, approve changes, inspect a pull request, evaluate a diff, or separate blocking defects from non-blocking implementation preferences.
---

# Pragmatic Code Reviewer

Review for material engineering risk without turning alternative preferences into blockers.

## Establish the review contract

1. Resolve the repository root and review target.
   - For local work, inspect staged and unstaged changes plus relevant untracked files.
   - For a remote pull request, inspect its title, body, issue links, comments, checks, changed files, and exact head. Avoid switching branches unless local inspection requires it and the user has authorized that mutation.
2. Discover every applicable `AGENTS.md` from the repository root through each changed file's directory. Read all of them before evaluating the diff.
3. Follow review policies, specifications, acceptance criteria, product or domain documents, and other sources named by applicable `AGENTS.md` files. Resolve relative links from the file that names them.
4. Reconcile those sources with the issue or pull-request contract, current implementation, tests, migrations, configuration, and changed behavior. Do not review the diff in isolation.
5. Record the target, exact revision when applicable, and sources used. If required evidence is unavailable, state the gap and do not invent a conclusion.

Treat `AGENTS.md` as the repository extension point. Repository-specific policy belongs there or in documents it links; do not require a fork of this skill.

After any context compact, resume, or handoff, repeat this section before continuing or concluding. Do not rely on a prior summary as proof that the sources or diff remain unchanged.

## Inspect proportionately

Review the areas affected by the change, including when applicable:

- correctness, edge cases, state transitions, and error handling;
- architecture, ownership boundaries, and API or domain contracts;
- security, privacy, authentication, authorization, and secret handling;
- data integrity, concurrency, idempotency, transactions, and migration safety;
- destructive operations, rollback and recovery behavior, and compatibility;
- maintainability where the change creates a credible future failure or operating cost;
- performance and resource use where the changed path can materially regress;
- observability, auditability, and actionable failure evidence;
- test quality, coverage of meaningful behavior, and validator strength.

Trace affected behavior beyond edited lines when callers, consumers, persisted data, shared contracts, or existing surfaces can regress. Keep review scoped to the change and its credible consequences.

## Apply the materiality gate

A finding blocks approval only when evidence supports at least one of these:

- a concrete defect or reachable failure scenario;
- a material security, privacy, authorization, data-integrity, availability, or operational risk;
- an explicit contract, acceptance-criteria, migration, or repository-policy violation;
- a maintainability problem with a credible cost, such as duplicated invariant logic likely to diverge or an ownership boundary that makes safe changes unreliable.

For every blocking finding, provide:

1. **Concrete scenario**: inputs, state, or sequence that triggers the problem.
2. **Impact**: user, system, data, security, or operating consequence.
3. **Evidence**: tight file and line location plus the governing contract or observed behavior.
4. **Smallest reasonable fix boundary**: required behavior, not a preferred rewrite.

Use `Blocker` for release-stopping or catastrophic risk and `Major` for other material defects that must be fixed before approval. Do not inflate severity to express confidence or taste.

Never relax security, privacy, authorization, data integrity, destructive migration safety, correctness, or explicit acceptance criteria under the pragmatic threshold.

## Accept good-enough code

Approve code that is safe, correct, clear enough, proportionately tested, and consistent with applicable repository conventions even when another implementation could be cleaner.

Do not block on:

- speculative refactors or hypothetical extensibility;
- personal naming, layout, abstraction, or style preferences outside an owned contract;
- micro-optimizations without a demonstrated material path;
- replacing a clear implementation with another equally valid pattern;
- wording polish outside a specified copy or documentation contract.

Include a non-blocking suggestion only when it offers useful, material value. Label it `Suggestion (non-blocking)`, explain the benefit briefly, and limit the list to the few items worth a maintainer's attention. Omit low-value nitpicks.

Do not repeat a resolved or evidence-based rejected concern without new evidence. Deduplicate findings that share one root cause and identify the smallest common fix boundary.

## Validate findings

Before concluding:

1. Re-read the complete current diff and applicable guidance.
2. Check each proposed finding against the current code rather than an earlier snapshot.
3. Confirm each blocking finding passes the materiality gate and is introduced by, exposed by, or necessary to safely deliver the changed behavior.
4. Confirm relevant tests and checks actually cover the claimed behavior; a green command is evidence only for what it exercises.
5. Remove stale, duplicate, speculative, and preference-only blockers.

Use [references/fixture-catalog.md](references/fixture-catalog.md) when calibrating or forward-testing this skill. Pass only fixture input to an independent reviewer; compare its result with `references/expected-results.json` afterward so expected answers do not leak into the review.

## Report

Return findings first, ordered by severity and then by affected behavior. Use this shape for every blocker or major finding:

```text
[Major] Short actionable title — path/to/file.ext:line
Concrete scenario: ...
Impact: ...
Evidence: ...
Smallest reasonable fix boundary: ...
```

Then include, only when useful:

```text
Suggestions (non-blocking)
- ...
```

End with one independent decision:

- `Conclusion: Approved` when no blocking finding remains.
- `Conclusion: Request changes` when one or more blocking findings remain.

When approved with no findings, say `No blocking findings.` Do not manufacture feedback to make the review appear thorough.
