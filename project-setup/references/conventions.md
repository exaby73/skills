# Pieces: Tracker, Testing, and Review

Three pieces that each write docs and route to them from `AGENTS.md`.

## Issue Tracker, Triage Labels, and Domain Docs

The engineering skills (`triage`, `to-tickets`, `to-spec`, `wayfinder`, and the rest) read three docs in `docs/agents/`: where issues live, the label for each of the five triage roles, and where the glossary and ADRs are. The `setup-matt-pocock-skills` skill writes them, creates missing labels, and adds the "Agent skills" block to `AGENTS.md`. The `skills` piece installs it first.

Its own instructions ask the owner one section at a time. Settle each section in this run's plan instead, and follow the installed `.agents/skills/setup-matt-pocock-skills/SKILL.md` with those answers, asking the owner nothing more:

| Its section | Recommend in the plan |
| --- | --- |
| A. Issue tracker | GitHub when `github_repo` is set; GitLab when the remote is GitLab; local markdown under `.scratch/` when there is no remote, with `gh repo create` and a second run named in the report. |
| B. Triage labels | The five defaults, `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`, unless the tracker already uses other names for those roles. |
| C. Domain docs | Single-context, unless it finds monorepo signals. |

Two of its rules meet this run's:

- **The file it edits:** it edits `CLAUDE.md` when that exists. After the `docs` piece, `CLAUDE.md` is a symlink, so edit `AGENTS.md` itself and check that `readlink CLAUDE.md` still prints `AGENTS.md`.
- **A Cadre project:** when `cadre` is on, add the Cadre paragraph from [cadre.md](cadre.md#write) to the `issue-tracker.md` it writes.

## Testing

Every test is Given/When/Then, through the `gwt-tester` skill, and **each test asserts only what its name says**, so adding a feature fails only that feature's tests.

Write [writing-tests.md](../templates/docs/development/writing-tests.md) into `docs/development/`, with its examples rewritten in the project's own test framework and domain once it has either, and the AGENTS.md section "Tests". A repository with a testing doc of its own gains the template's sections it lacks.

## Review

A separate agent reviews every pull request, COMMENT-only, in rounds; whoever merges acts on the findings.

Write [review.md](../templates/docs/agents/review.md) into `docs/agents/`, the AGENTS.md section "Review pull requests", and the register entry "Review every pull request with a separate agent". When `trains` is on, its line in that AGENTS.md section stays.

## Done

The docs each piece names exist and `docs/README.md` lists them, `AGENTS.md` routes to each, and a GitHub or GitLab tracker has a label for each of the five roles.
