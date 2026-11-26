<!-- project-setup template: keep a section only when its piece is on, delete each
"piece:" marker line and this comment, and fill each double-angle placeholder. -->
# <<PROJECT_NAME>>

<<PROJECT_SUMMARY>>

Read these before changing anything:

- docs/README.md: the docs index
- docs/product-decisions.md: owner decisions; don't reverse one without asking
- GLOSSARY.md: the glossary; use its terms in code, issues, and docs

Load the docs-governance skill before you add, move, or remove a doc, write a note, plan, or spec, or record or rely on an owner decision.

## Who decides

- <<OWNER>> owns the product and decides it and the tech stack. Ask before you add a language, framework, hosting provider, or third-party service.
- Agents own engineering inside that stack: structure, libraries, interfaces, and tests. Record a choice that is hard to reverse as an ADR in `docs/adr/`.

<!-- piece: cadre -->
## Deliver through Cadre

Deliver every change through Cadre: read `.cadre/workflow.md`, then run Cadre's track, quick, or Wisp command ([decision](docs/product-decisions.md#deliver-work-through-cadre)). Change files in `.cadre/` only through Cadre's commands.

<!-- piece: skills -->
## Keep skills current

Before you start work, run `<<SETUP_COMMAND>>`. It installs the latest version of each agent skill in `skills-lock.json` into `.agents/skills/` and `.claude/skills/`, which Git ignores. If `skills-lock.json` changes, commit it in the pull request you're working on. Read `docs/development/manage-agent-skills.md` before you add or remove a skill, or when `skills-lock.json` conflicts.

<!-- piece: testing -->
## Tests

Structure every test as Given/When/Then with the `gwt-tester` skill. Before you write, change, or delete a test, read `docs/development/writing-tests.md`: each test asserts only what its name says.

## Check your work

Before you push, run <<CHECK_COMMANDS>>, and report their results when you report work as done.

<!-- piece: notices -->
## Notices

When your change affects what people can do, what they pay, or what data <<PROJECT_NAME>> keeps, in the privacy policy, the terms, or anything they describe, tell the owner a notice needs sending before the release, and draft it. Follow `docs/agents/notices.md`.

<!-- piece: review -->
## Review pull requests

When you review a pull request, or before you merge one, follow `docs/agents/review.md`.
<!-- piece: trains -->
Open and merge pull requests through merge trains, as `docs/agents/merge-trains.md` says.

<!-- When tracker is on, setup-matt-pocock-skills adds its "Agent skills" section here. -->
