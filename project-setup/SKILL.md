---
name: project-setup
description: Set up a repository, new or existing, with the owner-led agent workflow - docs governance, pinned agent skills with a setup task, Cadre delivery, GitHub triage labels, test and review conventions, optional merge trains and notices, and the orchestrator. Use when starting a project, onboarding an existing repository to this workflow, or re-checking what a repository's setup lacks.
---

# Project Setup

Bring a repository to the target state: one **owner** decides the product and the stack, agents build inside it, and every rule an agent needs is reachable from `AGENTS.md`. Detect what exists, settle only the real choices, show one plan, get **one approval**, write, run `setup`, and report what's next.

The run is **idempotent**: a piece already present is left as it is, a partial piece gets only what it lacks, and a second run on a set-up repository reports "nothing to change" and stops. Existing files gain sections; they never lose or have text rewritten. This skill writes nothing into `.cadre/`.

## Pieces

| Piece | Present when `detect.sh` reports | Default | Reference |
| --- | --- | --- | --- |
| `docs`: docs governance | `agents_md`, `claude_md=symlink-to-agents`, `docs_index`, `glossary`, `decision_register`, `adr_dir`, `scratch_ignored=yes`; `agent_docs` has domain | on | [docs-governance.md](references/docs-governance.md) |
| `skills`: pinned agent skills and `setup` | `skills_lock`, `setup_task`, `skills_dirs_ignored=yes`, `manage_skills_doc` | on | [agent-skills.md](references/agent-skills.md) |
| `cadre`: delivery through Cadre | an AGENTS.md "Deliver through Cadre" section; `cadre_project` picks the handoff | on when the session has Cadre | [cadre.md](references/cadre.md) |
| `tracker`: GitHub Issues and triage labels | `agent_docs` has issue-tracker, triage-labels; `triage_labels=present` | on when `github_repo` is set | [conventions.md](references/conventions.md#issue-tracker-and-triage-labels) |
| `testing`: Given/When/Then tests | `writing_tests_doc=present` | on | [conventions.md](references/conventions.md#testing) |
| `review`: the review protocol | `agent_docs` has review | on | [conventions.md](references/conventions.md#review) |
| `trains`: merge trains | `agent_docs` has merge-trains | ask; recommend off unless several agents ship in parallel and CI exists | [merge-trains.md](references/merge-trains.md) |
| `notices`: notices to users | `agent_docs` has notices | ask; recommend on when `notice_signals` names a page | [notices.md](references/notices.md) |
| `approvals`: the orchestrator's standing approvals | a register entry "Let the orchestrator approve routine changes" | ask; recommend all four | [the `orchestrate` skill](../orchestrate/SKILL.md#standing-approvals) |

Read a piece's reference only when the plan includes it.

## 1. Detect

1. Run the detector from this skill's folder against the repository root, and keep its output for the plan. Add `--offline` when `gh auth status` fails.

   ```sh
   <skill-dir>/scripts/detect.sh <repo-root>
   ```

2. Check this session's own tools: Cadre (the `cadre:create` skill or `cadre` MCP tools), Glass Page (`glass-page` MCP tools), and a question tool for asking the owner.
3. Read every file the plan could touch: `AGENTS.md`, `CLAUDE.md`, `README.md`, everything under `docs/`, `GLOSSARY.md`, `.gitignore`, the runner file `detect.sh` names, and `skills-lock.json`. This covers [docs-governance's BOOTSTRAP.md](https://github.com/hexsis-llc/skills/blob/main/skills/docs-governance/BOOTSTRAP.md) step 1, Explore.
4. Find the check commands an agent should run before pushing: the runner's lint, typecheck, and test tasks, or the stack's defaults. With no stack yet, they are "the lint, typecheck, and tests for what you changed", until a later run finds real ones.

The step is done when every piece in the table is marked present, partial (and what it lacks), or missing, and you can name a home for every existing doc.

## 2. Settle the Choices

Ask the owner only what detection can't answer, in **one batch** through the question tool, recommended option first, each question standing alone. At most:

1. **Optional skills** (multi-select): the groups in [agent-skills.md](references/agent-skills.md#catalog), recommending each group its row says to.
2. **Merge trains:** on or off.
3. **Notices:** on or off.
4. **Standing approvals** (multi-select): the four rules in the `orchestrate` skill.

Skip a question whose piece is already present. Everything else (owner, project name, summary, where each existing doc goes, CLAUDE.md handling) goes into the plan as a recommendation the owner approves with it. Take the owner's name from `git config user.name`, the project's name from `README.md` or the folder, and its one-line summary from `README.md` or the owner's request. When neither gives a summary, make it the batch's first question, and move the standing approvals into the plan as a recommendation.

## 3. Show the Plan

Write the plan to `.scratch/project-setup/plan.md` and show it to the owner in full. It holds:

- **Detected:** greenfield or brownfield, the stack, the runner, and each piece's state.
- **Choices:** each answer from step 2, and each recommendation from it.
- **Files:** one row per path: create, add sections, replace with a symlink, or skip (already present). Every template it uses, with its placeholders filled.
- **Diffs:** a unified diff for every existing file that changes.
- **Commands:** each `skills add`, `gh label create`, `ln -s`, and the `setup` run.
- **Conflicts:** existing text that contradicts the workflow, such as an `AGENTS.md` line that allows pushing to the default branch. Leave the text as it is and ask the owner which wins.
- **Delivery:** the branch (a new `chore/agent-workflow-setup`, or the current branch when the repository has no commits yet), and whether to push and open a pull request.

When every piece is present and nothing conflicts, report "nothing to change" with each piece's state, and stop.

## 4. Get One Approval

Ask once, through the question tool: "Apply this plan?", with "Apply" first. A change sends you back to step 3 to revise the plan and ask again. Write nothing outside `.scratch/` before the owner approves.

## 5. Write

In this order, following each piece's reference:

1. Create the delivery branch.
2. `docs`, then `tracker`, `testing`, `review`, `trains`, and `notices`.
3. `AGENTS.md`'s sections, `docs/README.md`'s entries, and the register's entries, for every piece written.
4. `skills`: the install script, the runner's `setup` task, then one `skills add` per source, which writes `skills-lock.json`.
5. Missing triage labels.

### Templates

The [templates](templates/) folder holds every file this skill writes, at the path it takes in the repository.

- Fill each `<<PLACEHOLDER>>` from the plan. A placeholder you can't fill goes back to the owner; it never ships.
- A `<!-- piece: <name> -->` line covers the block after it: the section, when a heading follows, otherwise the paragraph. Keep the block when that piece is on, drop it when off, and delete the marker line either way. Delete each template's leading comment too.
- Into an existing file, add only the sections whose heading it lacks, where the template places them.

## 6. Run Setup and Verify

Run the `setup` task. Then check:

- `readlink CLAUDE.md` prints `AGENTS.md` (or `CLAUDE.md` holds only `@AGENTS.md` where symlinks are off);
- every relative link in the files you wrote resolves, and `grep -rn '<<' ` over them finds no placeholder;
- `.agents/skills/` and `.claude/skills/` hold every skill in `skills-lock.json`, and `git status --short` lists neither;
- `gh label list` shows the five triage labels, when `tracker` is on;
- `detect.sh` now reports each planned piece present.

## 7. Commit and Report

Stage the paths the plan named, by name, and commit them as one `chore: Set up the agent workflow` commit. Push and open the pull request only when the plan said to.

Report to the owner in plain words: what was written, what was skipped and why, the conflicts still open, and what's next:

- **Cadre:** run `cadre:create`, greenfield or brownfield as detected, and give it [the delivery lessons](templates/cadre-guidelines-delivering.md) for `.cadre/guidelines.md`. On a project Cadre already set up, propose them through `cadre:refresh`.
- **The first map:** run `wayfinder` on the first piece of work, to turn it into a decision map of tickets.
- **The glossary:** run `grill-with-docs` or `domain-modeling` to fill `GLOSSARY.md` as terms settle.
- **The orchestrator:** start a long-running session with the `orchestrate` skill to coordinate delivery.
