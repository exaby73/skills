---
name: gwt-testing
description: Write or refactor tests using clear Given/When/Then structure. Use when creating new tests, improving test readability, or standardizing test files with setup hooks, assertion-only Then blocks, and shallow suite nesting.
---

# GWT Testing

Use these instructions to write clean, readable tests with Given/When/Then semantics.

## Terminology Map
Use the agnostic terms below throughout this skill.

| Agnostic term | JS/TS example | Dart example |
| --- | --- | --- |
| Suite block | `describe` | `group` |
| Case block | `it` / `test` | `test` |
| Setup once (for a suite) | `before` | `setUpAll` |
| Setup each (per case) | `beforeEach` | `setUp` |
| Teardown once (for a suite) | `after` | `tearDownAll` |
| Teardown each (per case) | `afterEach` | `tearDown` |

When this skill says:
- "suite block", read `describe` (JS/TS) or `group` (Dart)
- "case block", read `it`/`test` (JS/TS) or `test` (Dart)
- "setup hook", read `before`/`beforeEach` (JS/TS) or `setUpAll`/`setUp` (Dart)
- "teardown hook", read `after`/`afterEach` (JS/TS) or `tearDownAll`/`tearDown` (Dart)

## Rules
1. Keep maximum nesting depth to 3 levels: `suite -> suite -> case`.
2. Never nest `Given` blocks inside another `Given` block.
3. Put setup and action code in setup hooks for the scenario.
4. Prefer assertion-only case blocks.
5. If a `When` has only one `Then`, use a single case title (`When ... then ...`); in this collapsed form, putting the `When` action inside the case body is acceptable.
6. Remove wrapper describes that do not add scenario context.
7. Write explicit scenario titles: `Given <subject> with <condition>`.

## Writing Workflow
1. Define scenarios as top-level `Given` suite blocks.
2. Add setup hooks per scenario to arrange and act.
3. Add case blocks for outcomes (`When ... then ...`) with assertions only.
4. Keep nesting shallow and remove redundant wrappers.
5. Run tests and formatter.

## Pseudocode Pattern
```pseudo
suite("Given <subject> with <state>", () => {
  setup_each(() => {
    // arrange
    // act
  })

  case("When <event> then <outcome>", () => {
    // assert only
  })
})
```

## Anti-Patterns
- Nesting `Given` inside `Given`.
- Calling the SUT inside a case block when it can be executed in setup hooks.
- Mixing setup/action/asserts in a single case block.
- Adding wrapper suite blocks with no new context.
- Depth greater than `suite -> suite -> case`.

## Review Checklist
- Are there any nested `Given` blocks?
- Does each case block contain assertions only?
- Is setup/action moved into setup hooks of the relevant scenario?
- Are single `When` + single `Then` cases collapsed into one case block?
- Is nesting depth <= 3?
