# Calibration fixture catalog

Use these neutral, deterministic inputs to calibrate issue-contract writing. Give an independent reviewer exactly one `### Fixture input` section and the `issue-contract-writer` skill. Keep expected conclusions private until the review concludes. This corpus is frozen for the review cycle.

## Fixture: unbounded-natural-language

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Issue acceptance criteria must name finite validation evidence and a stopping condition.
```

Current implementation

- The repository has a browser-use guard for one known mutation path.
- No finite input domain, threat model, corpus, or semantic parser is part of the proposed change.

Related issue

- The issue is a new implementation issue with no dependencies.

Proposed contract

```md
## Acceptance criteria

- The validator must reject every equivalent way to request browser use.
```

Validation plan

- Keep adding reviewer-discovered paraphrases until no more can be found.

Owner decisions

- None supplied.

## Fixture: bounded-structural

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Skills must declare their canonical package path and validate their frozen fixtures with a repository script.
```

Current implementation

- The new skill directory does not yet exist.

Related issue

- The issue has no blocked-by dependency and is a child of the repository tooling parent.

Proposed contract

```md
## Outcome

Add one reusable issue-contract-writer skill.

## In scope

- `issue-contract-writer/SKILL.md`
- `issue-contract-writer/agents/openai.yaml`
- `issue-contract-writer/references/fixture-catalog.md`
- `issue-contract-writer/references/expected-results.json`
- `issue-contract-writer/scripts/test_fixtures.py`

## Explicit exclusions

- Do not mutate GitHub from the skill.
- Do not parse arbitrary natural language or expand fixtures during review.

## Acceptance criteria

- `R1`: The skill has front matter with name `issue-contract-writer`; validator: `python3 issue-contract-writer/scripts/test_fixtures.py`; completion: command passes at target head.
- `R2`: The catalog and expected-results file contain exactly five frozen fixture IDs; validator: the same script; completion: IDs and decisions match.
- `R3`: The skill states that production boundaries and fixture calibration have separate domains; validator: exact required phrase check in the script; completion: phrase is present.

## Validation evidence

- Run the named Python validator at the exact target head.

## Dependencies and relationships

- Reload repository guidance and the issue parent relationship at the target head before judgment.

## Stopping conditions

- Stop if the package path or fixture IDs become dynamic.

## Owner decisions

- Parent owns publication.
```

## Fixture: finite-universal

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Universal words are allowed when they quantify over a declared finite enum or testable property.
```

Current implementation

- The lifecycle schema declares exactly six states: `assembling`, `confirmed`, `live`, `completed`, `cancelled`, and `expired`.

Related issue

- The issue depends on the schema revision `schema@7777777`.

Proposed contract

```md
## Acceptance criteria

- For every value in the six-value lifecycle enum, the projection emits exactly one canonical state marker. Included cases are the six enum values; excluded cases are arbitrary prose and future states. Validator: `pnpm run check:lifecycle-enum`; completion: the command passes against `schema@7777777`.

## Validation evidence

- Record the command output and schema revision.

## Dependencies and relationships

- Reload `schema@7777777` and reconcile its enum with the full diff before judgment.

## Stopping conditions

- Stop if the schema adds a seventh state without an owner decision.
```

## Fixture: ambiguous-evidence

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Acceptance criteria require observable results and named validators or human decisions.
```

Current implementation

- A proposed issue says only that the implementation should be “reviewed carefully.”

Related issue

- A linked issue has an unresolved disagreement about whether the change is MVP or future scope.

Proposed contract

```md
## Outcome

Make the workflow better.

## Acceptance criteria

- Reviewers confirm the implementation is correct.
```

Validation evidence

- None named.

Owner decisions

- MVP scope and completion owner are unresolved.

## Fixture: fixture-boundary

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Security criteria protect the production endpoint. Calibration fixtures may cover only their declared finite inputs.
```

Current implementation

- `POST /teams/:id/invite` checks authorization.

Related issue

- No dependency is unresolved.

Proposed contract

```md
## Acceptance criteria

- `R1`: Every request to the declared endpoint fixture set `{POST /teams/:id/invite, POST /teams/:id/accept}` must enforce the authenticated-team authorization property. Included cases are those two routes and their documented actor roles; excluded cases are unrelated endpoints and arbitrary prose. Threat model is cross-team access. Validator: `tests/security-contract.test.ts`; completion: both route cases pass.
- `R2`: The calibration validator must report only the frozen two-route corpus and must not claim exhaustive semantic coverage. Validator: `python3 scripts/test_fixtures.py`; completion: the corpus hash and domain statement match.
```

## Validation evidence

- Run the security tests and the frozen-corpus validator separately.

## Stopping conditions

- Stop if a reviewer proposes adding an unlisted paraphrase without a current production entry path.

## Owner decisions

- Parent owns any production threat-model expansion.
```
