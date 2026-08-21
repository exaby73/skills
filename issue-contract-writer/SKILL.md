---
name: issue-contract-writer
description: Draft and validate bounded GitHub issue delivery contracts by reconciling repository sources, implementation, dependencies, evidence, and stopping conditions before a parent publishes or materially amends an issue.
---

# Issue Contract Writer

Draft and validate an implementation issue before its parent/controller publishes or materially amends it. This skill produces contract text and evidence; it never creates, edits, labels, assigns, links, or closes a GitHub issue.

## Establish the source record

Read and record the sources that can govern the proposed work:

1. Resolve the repository root and every applicable `AGENTS.md` in its filesystem and repository hierarchy.
2. Read the product, engineering, architecture, policy, validation, and operational documents named by that guidance. Resolve relative links from the document that names them.
3. Inspect current implementation and tests for the behavior the issue would change. Record the exact revision or working-tree state inspected.
4. Read related issues, pull requests, comments, native parent/sub-issue links, blocked-by and blocking relationships, and other dependencies that can change scope or sequencing.
5. Record source authority, exact revision or immutable identity, relevant evidence, and the reconciliation performed before drafting each material requirement.

If a required source, dependency, relationship, or exact target cannot be inspected, return `Conclusion: Evidence blocked` with the missing evidence and action needed. If sources materially conflict and no authority resolves the conflict, stop for an owner decision; do not choose a requirement silently.

## Draft a finite delivery contract

The issue must contain these sections, even when a section says `None`:

- **Outcome** — the observable result and who owns it.
- **In scope** — bounded files, behavior, systems, or decisions.
- **Explicit exclusions** — behavior, surfaces, integrations, and future work not authorized by this issue.
- **Acceptance criteria** — stable IDs, each with one observable result, its domain, its named validator or human decision, and the evidence that proves completion.
- **Validation evidence** — exact commands, fixtures, checks, artifacts, or reviewer decisions, with the target revision they cover.
- **Dependencies and relationships** — authority, exact identity, sequencing, blocked-by/blocking effects, and the reload required before judgment.
- **Stopping conditions** — the evidence gap, failure, recurrence, contradiction, or user decision that stops work.
- **Owner decisions** — resolved product, security, scope, architecture, or risk decisions; unresolved decisions remain explicit blockers.

Every acceptance criterion must map to a finite observable result and a named validator or human decision. A criterion is not complete when it only says to implement a mechanism, cover “edge cases,” or make a reviewer satisfied. Give each criterion a bounded domain, included cases, excluded cases, completion condition, and residual risk when the domain is not universal.

Do not turn worker handoffs, reviewer severity, or a green command into authorization for work outside the contract. Keep parent/controller publication and final scope decisions separate from drafting and validation.

## Screen universal and open-ended language

Treat `all`, `any`, `every`, `never`, `equivalent`, `ordinary variants`, `mechanically reject`, and `all edge cases` as risk indicators, not forbidden words. A universal term may be valid when it quantifies over a defined finite domain or a testable property.

When such a term is necessary, state all of the following:

- the finite domain or precise testable property;
- included and excluded cases;
- the threat model or failure model, when security or robustness is involved;
- the frozen corpus or property-based completion rule;
- residual risk outside the domain; and
- the condition that ends validation.

Return `Conclusion: Needs clarification` when a criterion uses a universal or open-ended term without those bounds. Return `Conclusion: Reject as unbounded` when success requires exhaustive recognition of arbitrary natural-language paraphrases, unknowable future inputs, or an indefinitely expanding reviewer-generated corpus. Do not replace that obligation with a growing synonym list or semantic classifier.

An explicit security or production boundary remains strict inside its stated domain. A repository calibration fixture is only evidence about its frozen fixture input; it is not a hostile-input parser and cannot be presented as exhaustive production protection.

## Publication gate

The parent/controller may publish only when:

1. the source record is complete and reconciled;
2. each acceptance criterion has a finite domain, observable result, named validator or human decision, and completion condition;
3. exclusions, dependencies, stopping conditions, residual risks, and owner decisions are explicit;
4. no unresolved contradiction or material ambiguity remains; and
5. validation uses a finite frozen fixture set or a named structural/property validator.

The skill drafts and validates the proposed contract. It does not independently mutate GitHub state, start a review loop, expand the issue from new reviewer vocabulary, or approve unrestricted natural-language coverage.

## Report

Return:

1. the exact source and dependency record;
2. the acceptance-criterion matrix with criterion ID, bounded domain, observable result, validator or human decision, and completion evidence;
3. explicit exclusions, stopping conditions, residual risks, and unresolved owner decisions; and
4. the publication conclusion.

Use exactly one conclusion:

- `Conclusion: Ready to publish`
- `Conclusion: Needs clarification`
- `Conclusion: Reject as unbounded`
- `Conclusion: Evidence blocked`

Do not claim that a passing fixture validator proves unrestricted semantic or natural-language coverage.

## Calibration resources

Use [references/fixture-catalog.md](references/fixture-catalog.md) for the finite, frozen calibration inputs. Give an independent reviewer only one `### Fixture input` section and this skill; do not provide `references/expected-results.json` until the reviewer concludes. Compare against the private expected results afterward and run [scripts/test_fixtures.py](scripts/test_fixtures.py) to validate the fixture contract.

The calibration corpus is declared before a review cycle and must not grow from reviewer-generated paraphrases during that cycle. Add a fixture only through a deliberate bounded skill change with updated expected results and validator checks.
