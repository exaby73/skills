# How to Manage Agent Skills

A skill is a set of instructions that a coding agent loads when a task calls for it. `skills-lock.json` lists every skill this repository uses and the source of each one. The skills are installed into `.agents/skills/` and linked into `.claude/skills/`. Git ignores both folders, so `skills-lock.json` is the record.

The commands below run the `skills` CLI with `npx`, at the version `<<INSTALL_SCRIPT>>` pins in `SKILLS_VERSION`, <<SKILLS_VERSION>> at the time of writing.

## Install and update the skills

`<<SETUP_COMMAND>>` installs the skills, by running `<<INSTALL_SCRIPT>>`. It runs one `skills add` for each source in `skills-lock.json`, so each source is cloned once. The lock pins no commit, so each `add` installs the latest version of its source: the same command installs and updates.

## Commit the lock file

When a skill changed at its source, the install writes the skill's new hash to `skills-lock.json`. When `skills-lock.json` changes on your branch, commit it in the same pull request, whatever the pull request is about.

When `skills-lock.json` conflicts in a merge or a rebase:

1. Keep every skill from both sides. Where both sides changed the same hash, keep either one.
2. Run `<<INSTALL_SCRIPT>>`. It writes the latest hash over the one you kept.
3. Stage `skills-lock.json` and finish the merge or the rebase.

## Add a skill

1. Search the registry: `npx skills@<<SKILLS_VERSION>> find <query>`.
2. Read the source of the skill before you install it. A skill runs with the full permissions of the agent. Skip a skill that recommends a tool that conflicts with this repository's stack, which is in the [decision register](../product-decisions.md).
3. Install it for Claude Code and Codex: `npx skills@<<SKILLS_VERSION>> add <owner>/<repo> --skill <name> --agent claude-code codex --yes`.
4. Commit `skills-lock.json`.

## Remove a skill

1. Remove it: `npx skills@<<SKILLS_VERSION>> remove <name> --yes`.
2. Commit `skills-lock.json`.
