# Pieces: Tracker, Testing, and Review

Three pieces that each write docs from a template and route to them from `AGENTS.md`.

## Issue Tracker and Triage Labels

Issues live in GitHub Issues, managed with `gh`. The skills speak of five triage roles, and the repository has one label for each.

1. Write [issue-tracker.md](../templates/docs/agents/issue-tracker.md) and [triage-labels.md](../templates/docs/agents/triage-labels.md) into `docs/agents/`, and the tracker subsections of the AGENTS.md section "Agent skills".
2. Check the target before the first write: `gh repo view --json nameWithOwner` must print the `github_repo` from the plan. In a fork, `gh` can default to the upstream parent.
3. Create each label `detect.sh` reports missing, and only those:

   ```sh
   gh label create needs-triage    --color d4c5f9 --description "Maintainer needs to evaluate this issue"
   gh label create needs-info      --color fbca04 --description "Waiting on reporter for more information"
   gh label create ready-for-agent --color 0e8a16 --description "Fully specified, ready for an AFK agent"
   gh label create ready-for-human --color 1d76db --description "Requires human implementation"
   gh label create wontfix         --color ffffff --description "Will not be actioned"
   ```

   When the repository already uses other names for these roles, keep its labels and write its names into `triage-labels.md`'s second column instead.

With no GitHub remote, keep this piece off, and name `gh repo create` and a second run of this skill in the report.

## Testing

Every test is Given/When/Then, through the `gwt-tester` skill, and **each test asserts only what its name says**, so adding a feature fails only that feature's tests.

Write [writing-tests.md](../templates/docs/development/writing-tests.md) into `docs/development/`, with its examples rewritten in the project's own test framework and domain once it has either, and the AGENTS.md section "Tests". A repository with a testing doc of its own gains the template's sections it lacks.

## Review

A separate agent reviews every pull request, COMMENT-only, in rounds; whoever merges acts on the findings.

Write [review.md](../templates/docs/agents/review.md) into `docs/agents/`, the AGENTS.md section "Review pull requests", and the register entry "Review every pull request with a separate agent". When `trains` is on, its line in that AGENTS.md section stays.

## Done

The docs each piece names exist and `docs/README.md` lists them, `AGENTS.md` routes to each, and `gh label list` shows the five roles when `tracker` is on.
