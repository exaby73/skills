# Piece: Agent Skills

Each repository pins its own agent skills: `skills-lock.json` is the committed record, and a `setup` task installs the latest version of each into `.agents/skills/`, linked into `.claude/skills/`. Git ignores both folders.

## Catalog

Install the **core** group always, and each other group the owner picks in step 2. A skill already in `skills-lock.json` stays; this run never removes one.

| Group | Recommend | Source | Skills |
| --- | --- | --- | --- |
| core | always | `hexsis-llc/skills` | `docs-governance`, `gwt-tester`, `pair-review`, `git-committer` |
| core | always | `mattpocock/skills` | `writing-for-agents`, `code-review`, `wayfinder`, `research`, `prototype`, `tdd`, `diagnosing-bugs`, `grilling`, `grill-with-docs`, `domain-modeling`, `triage`, `to-spec`, `to-tickets`, `handoff` |
| core | always | `t3dotgg/tstack` | `leaving-pr-comments` |
| core | always | `exaby73/skills` | `orchestrate` |
| design | when `frontend=yes` | `pbakaus/impeccable` | `impeccable` |
| Glass Page integration (optional) | when the session has Glass Page tools | `hexsis-llc/skills` | `wayfinder-pane` |
| more thinking tools | no | `mattpocock/skills` | `ask-matt`, `codebase-design`, `improve-codebase-architecture`, `grill-me`, `teach`, `to-questionnaire`, `wait-what`, `retro`, `wizard` |
| automated reviewers | when `ci=github-actions` | `exaby73/skills`, `hexsis-llc/skills` | `code-reviewer`, `scope-reviewer`, `ui-ux-reviewer`; `claude-pr-review` |

Leave out `setup-matt-pocock-skills`, whose docs this run writes, and, when `cadre` is on, `implement` and `implement-spec`, since Cadre implements.

## Write

1. **Ignore the install folders.** Add `.agents/skills/` and `.claude/skills/` to `.gitignore`. When `tracked_skill_files` is above 0, the repository commits skills of its own there: ignore only `.agents/skills/`, and put the conflict in the plan for the owner to decide (move their skills, or ignore each installed name).
2. **Add the install script** from [templates/scripts/install-skills.sh](../templates/scripts/install-skills.sh), into the repository's scripts folder (`scripts/` when it has none), executable. Pin `SKILLS_VERSION` to the newest `skills` release at least two weeks old (`npm view skills time --json`).
3. **Add the `setup` task** to the runner `detect.sh` names, running the install script first, then the project's own install steps, such as its package install. With no runner, create a `Taskfile.yml` holding only `setup` when `task` is installed; otherwise the setup command is the install script itself. In each runner:

   | Runner | `setup` |
   | --- | --- |
   | Task | `setup:` with `desc` and `cmds: [./scripts/install-skills.sh, ...]` |
   | npm, pnpm, yarn, bun | `"setup": "./scripts/install-skills.sh && <install>"` in `package.json` |
   | make | a `.PHONY` `setup:` target |
   | just | a `setup:` recipe |
   | mise | `[tasks.setup]` with `run` |

4. **Install each source's skills**, which creates or extends `skills-lock.json`, one source per command:

   ```sh
   npx --yes skills@<version> add <source> --skill <name> <name> ... --agent claude-code codex --yes
   ```

5. **Add the doc** [templates/docs/development/manage-agent-skills.md](../templates/docs/development/manage-agent-skills.md), the AGENTS.md section "Keep skills current", and the register entry "Keep agent skills up to date in every pull request".

The installer needs Node.js for `npx`. When the machine lacks it, say so in the plan, and leave the lock and the task written for the owner to run.

## Done

`skills-lock.json` lists every chosen skill, the `setup` task installs them all from a clean checkout, and `git status --short` lists neither install folder.
