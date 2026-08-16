---
name: ui-ux-reviewer
description: Review local changes or remote pull requests whose material effect includes interface, interaction, journey, accessibility, responsive, or visual-system behavior. Use when Codex must inspect rendered UI and representative states against repository, product, design, accessibility, and ticket/PR guidance, then return a strict evidence-based conclusion without turning preferences into blockers.
---

# Strict UI/UX Reviewer

Review interface behavior for material user and contract risk. Use this skill only when a change affects a visible surface, an interaction, a journey, accessibility, responsive behavior, or a shared visual system. Keep source inspection in service of rendered evidence; do not approve or reject from a diff or screenshot alone.

## Establish the review contract

1. Resolve the repository root and the review target.
   - For a named commit, tag, branch, or revision range, inspect that exact revision with the repository's VCS. Do not silently substitute the current worktree.
   - For local changes, inspect staged and unstaged changes, relevant untracked files, the base revision, and the resulting target state.
   - For a remote pull request, identify its base, exact head, changed paths, description, linked contract, review context, and checks without changing unrelated branches or state.
   - Record the target, exact revision, changed paths, and evidence sources before judging.
2. For each changed path, discover applicable `AGENTS.md` files by walking from the filesystem root through every parent directory, including ancestors above the VCS root. Deduplicate discovered files and read them once, outermost ancestor to innermost directory, before evaluating the change. Do not stop at the repository root.
3. Follow every relevant link named by those instructions. Read applicable product, design, accessibility, specification, and ticket/PR contract documents; resolve relative links from the document that names them. Note missing, contradictory, or inaccessible guidance.
4. Reconcile the guidance and delivery contract with the current implementation, changed behavior, rendered result, and relevant tests. Treat no single source as sufficient when the sources disagree.

Treat `AGENTS.md` as the repository extension point: each consuming repository defines its own review policy, related patterns, and linked sources there. Do not require a fork of this skill or encode one repository's product or design decisions here.

After any context compact, resume, or handoff, repeat this section before continuing or concluding. Do not treat a prior summary as proof that the target, guidance, or rendered result is unchanged.

## Obtain rendered evidence

1. Use source inspection to locate routes, surfaces, entry points, and state setup, then inspect the rendered interface through an available browser, emulator, preview, or render harness. Inspect representative journeys and states, not source or screenshots alone. Include existing surfaces materially affected by changed navigation, shared components, actions, copy, data, or state.
2. Exercise the path a real user takes: enter the surface, identify the next action, use navigation and progressive disclosure, complete the primary task, trigger relevant feedback, recover from failure, and verify the resulting state. Use semantic controls and visible UI when the environment permits.
3. Check representative mobile, tablet, and desktop viewports. At each relevant viewport, verify hierarchy, reachability, wrapping, overflow, truncation, density, and the placement of the next action. Include zoom and text resizing when the surface or environment supports them.
4. Check applicable empty, loading, pending, success, error, permission, disabled, destructive, stale, and conflict states. Do not invent states that the changed behavior cannot reach; record which relevant states were exercised or why they do not apply.
5. Record evidence precisely: file and line or changed path, route or surface, viewport, state, interaction sequence, and DOM or accessibility-tree context. A screenshot can support the record, but a screenshot alone cannot establish behavior. If the target cannot render or required evidence or guidance is unavailable despite source context, do not infer the result; use `Conclusion: Evidence blocked` and name the missing evidence and the action needed.

## Inspect the affected experience

Cover the changed behavior proportionately across these lenses:

- information architecture and page responsibility; discoverability of actions and data plus next action; hierarchy, navigation, progressive disclosure, recognition over recall, and error prevention;
- feedback, error handling, recovery, and state visibility;
- design-system, token, component, typography, alignment, spacing, density, radii, borders, elevation, iconography, contrast, color meaning, and motion consistency;
- semantics, labels, focus, keyboard operation, target size, zoom, text resize, reduced motion, color-independent meaning, overflow, and truncation;
- representative mobile/tablet/desktop behavior, including orientation or breakpoint changes when relevant.

Trace shared components, routes, states, and responsive rules beyond edited lines when the change can regress an existing journey. Check the smallest surface that proves or disproves a criterion, then stop; do not expand review into unrelated preference debates.

## Apply the strict materiality gate

Block only when evidence supports one or more of these conditions:

- concrete task failure or reachable user-facing defect;
- inaccessible behavior that prevents or materially impairs use;
- explicit product/repository/design-contract violation;
- observable regression or inconsistency in the affected experience;
- material user impact, including loss of discoverability, state visibility, recovery, or responsive reachability.

Do not block subjective preferences, equivalent alternatives, or cosmetic nitpicks. A different clear layout, icon, spacing choice, or component composition is acceptable when it follows applicable guidance and remains usable across relevant states and viewports.

Use `Blocker` only for release-stopping or catastrophic risk. Use `Major` for other material defects that must be fixed before approval. Do not inflate severity to express taste, uncertainty, or review thoroughness. Deduplicate findings with one root cause and group related evidence when the smallest fix boundary is shared.

## Report findings

Put blocking findings first, ordered by severity and affected behavior. Every blocker or major finding must include all of the following:

```text
[Major] Short actionable title — path:line or route
Concrete scenario: The user, state, or sequence that triggers the problem.
Impact: The task, access, recovery, or contract consequence.
Evidence: Tight file/route/viewport/state or DOM context plus the observed result.
Governing criterion: The applicable repository, product, design, accessibility, or ticket/PR requirement.
Smallest reasonable fix boundary: The required behavior or local boundary, not a preferred rewrite.
```

Keep evidence observable and actionable. Do not turn a missing assertion, a personal preference, or a hypothetical future concern into a blocker.

Add only a few useful suggestions after blockers, and label each one explicitly:

```text
Suggestions (non-blocking)
- Suggestion (non-blocking): Brief improvement and its user or maintenance benefit.
```

Omit suggestions when they add no material value. An approved review may contain no suggestions.

## Conclude independently

Re-read the current target, guidance, and evidence before concluding. Remove stale, duplicate, speculative, and preference-only findings. End with exactly one independent conclusion, using one of these exact strings:

- `Conclusion: Approved` when no blocking finding remains. With no blockers, also say `No blocking findings.`
- `Conclusion: Request changes` when one or more Blocker or Major findings remain.
- `Conclusion: Evidence blocked` when rendered evidence, required evidence, or applicable guidance is missing. Name what is missing and the action needed before a conclusion can be reached; do not also claim approval or request changes.

## Calibration and forward-testing

Use [references/fixture-catalog.md](references/fixture-catalog.md) for neutral calibration inputs and [references/expected-results.json](references/expected-results.json) for private expected outcomes. Run [scripts/test_fixtures.py](scripts/test_fixtures.py) to validate their contract.

For forward-testing, give an independent reviewer the skill and only one fixture's input section. Never pass the expected-results JSON, another fixture, or an answer hint. Compare the independent result with the separate expected JSON only after the review concludes.
