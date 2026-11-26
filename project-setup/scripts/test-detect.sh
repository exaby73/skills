#!/usr/bin/env bash
# Dry-run detect.sh against throwaway repositories in each starting state.
# Usage: test-detect.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
detect="$here/detect.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/project-setup-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
failures=0

new_repo() {
  local dir="$work/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name test
  printf '%s' "$dir"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m init
}

# expect <scenario> <output> <key> <value>
expect() {
  local got
  got=$(printf '%s\n' "$2" | sed -n "s/^$3=//p")
  if [ "$got" = "$4" ]; then
    printf 'ok   %s: %s=%s\n' "$1" "$3" "$4"
  else
    printf 'FAIL %s: %s expected %s, got %s\n' "$1" "$3" "$4" "${got:-<absent>}"
    failures=$((failures + 1))
  fi
}

# Given an empty repository, when detect runs, then everything is missing.
repo=$(new_repo empty)
out=$("$detect" --offline "$repo")
expect empty "$out" kind greenfield
expect empty "$out" commit_count 0
expect empty "$out" agents_md missing
expect empty "$out" claude_md missing
expect empty "$out" runners none
expect empty "$out" skills_lock missing
expect empty "$out" scratch_ignored no
expect empty "$out" cadre_project missing
expect empty "$out" github_repo none
expect empty "$out" notice_signals none

# Given a scaffold with only docs and config, then it is still greenfield.
repo=$(new_repo scaffold)
printf '# Thing\n' > "$repo/README.md"
printf 'node_modules/\n' > "$repo/.gitignore"
commit_all "$repo"
out=$("$detect" --offline "$repo")
expect scaffold "$out" kind greenfield
expect scaffold "$out" commit_count 1

# Given a greenfield repository after project-setup wrote its files, then it
# is still greenfield, so a second run reports the same kind.
mkdir -p "$repo/scripts" "$repo/docs/agents"
printf '#!/bin/sh\n' > "$repo/scripts/install-skills.sh"
printf "version: '3'\n" > "$repo/Taskfile.yml"
printf '{"version":1,"skills":{}}\n' > "$repo/skills-lock.json"
printf '# Review\n' > "$repo/docs/agents/review.md"
printf '# App\n' > "$repo/AGENTS.md"
ln -s AGENTS.md "$repo/CLAUDE.md"
out=$("$detect" --offline "$repo")
expect scaffold-after-setup "$out" kind greenfield

# Given an app with its own AGENTS.md and a CLAUDE.md with content,
# then it is brownfield and both instruction files are reported as files.
repo=$(new_repo existing-agents)
printf '# Rules\n\nUse pnpm.\n' > "$repo/AGENTS.md"
printf '# Claude rules\n\nRun tests.\n' > "$repo/CLAUDE.md"
printf '{"name":"app","scripts":{"test":"vitest"}}\n' > "$repo/package.json"
: > "$repo/pnpm-lock.yaml"
printf 'test:\n\tpnpm test\n' > "$repo/Makefile"
mkdir -p "$repo/src/routes/privacy"
printf 'export {}\n' > "$repo/src/index.ts"
printf '<h1>Privacy</h1>\n' > "$repo/src/routes/privacy/page.svelte"
mkdir -p "$repo/db/migrations"
printf 'create table t();\n' > "$repo/db/migrations/0001_init.sql"
git -C "$repo" remote add origin git@github.com:example/app.git
commit_all "$repo"
out=$("$detect" --offline "$repo")
expect existing-agents "$out" kind brownfield
expect existing-agents "$out" agents_md file
expect existing-agents "$out" claude_md file
expect existing-agents "$out" stacks node
expect existing-agents "$out" runners make,pnpm
expect existing-agents "$out" runner_file Makefile
expect existing-agents "$out" setup_task missing
expect existing-agents "$out" github_repo example/app
expect existing-agents "$out" triage_labels unchecked
expect existing-agents "$out" migration_dirs db/migrations/
expect existing-agents "$out" notice_signals src/routes/privacy/page.svelte
expect existing-agents "$out" frontend yes

# Given a CLAUDE.md whose only line imports AGENTS.md, then it is an import.
repo=$(new_repo import)
printf '# Rules\n' > "$repo/AGENTS.md"
printf '@AGENTS.md\n' > "$repo/CLAUDE.md"
out=$("$detect" --offline "$repo")
expect import "$out" claude_md import-agents

# Given a repository already set up, then every piece reads as present,
# so a second run of project-setup has nothing to write.
repo=$(new_repo set-up)
printf '# App\n' > "$repo/AGENTS.md"
ln -s AGENTS.md "$repo/CLAUDE.md"
mkdir -p "$repo/docs/adr" "$repo/docs/agents" "$repo/docs/development" "$repo/.cadre"
printf '# Docs\n' > "$repo/docs/README.md"
printf '# Product Decisions\n' > "$repo/docs/product-decisions.md"
printf '# ADRs\n' > "$repo/docs/adr/README.md"
printf '# App\n' > "$repo/GLOSSARY.md"
for f in review issue-tracker triage-labels domain; do printf '# %s\n' "$f" > "$repo/docs/agents/$f.md"; done
printf '# Tests\n' > "$repo/docs/development/writing-tests.md"
printf '# Skills\n' > "$repo/docs/development/manage-agent-skills.md"
printf '.scratch/\n.agents/skills/\n.claude/skills/\n' > "$repo/.gitignore"
printf '{"version":1,"skills":{}}\n' > "$repo/skills-lock.json"
printf "version: '3'\ntasks:\n  setup:\n    cmds:\n      - ./scripts/install-skills.sh\n" > "$repo/Taskfile.yml"
printf '{"schemaVersion":2}\n' > "$repo/.cadre/project.json"
printf 'package main\n' > "$repo/main.go"
printf 'module app\n' > "$repo/go.mod"
commit_all "$repo"
out=$("$detect" --offline "$repo")
expect set-up "$out" kind brownfield
expect set-up "$out" agents_md file
expect set-up "$out" claude_md symlink-to-agents
expect set-up "$out" docs_index present
expect set-up "$out" decision_register present
expect set-up "$out" adr_dir present
expect set-up "$out" glossary GLOSSARY.md
expect set-up "$out" agent_docs review,issue-tracker,triage-labels,domain
expect set-up "$out" writing_tests_doc present
expect set-up "$out" manage_skills_doc present
expect set-up "$out" scratch_ignored yes
expect set-up "$out" skills_lock present
expect set-up "$out" skills_dirs_ignored yes
expect set-up "$out" stacks go
expect set-up "$out" runners task
expect set-up "$out" setup_task present
expect set-up "$out" cadre_project initialized

# Given committed skills under .claude/skills, then they are counted, so the
# plan does not ignore a folder that holds the project's own skills.
repo=$(new_repo tracked-skills)
mkdir -p "$repo/.claude/skills/own"
printf -- '---\nname: own\n---\n' > "$repo/.claude/skills/own/SKILL.md"
printf '.agents/skills/\n' > "$repo/.gitignore"
commit_all "$repo"
out=$("$detect" --offline "$repo")
expect tracked-skills "$out" tracked_skill_files 1
expect tracked-skills "$out" skills_dirs_ignored partial

# Given a legacy CONTEXT.md glossary, then it is reported for the rename.
repo=$(new_repo legacy-glossary)
printf '# Terms\n' > "$repo/CONTEXT.md"
out=$("$detect" --offline "$repo")
expect legacy-glossary "$out" glossary legacy:CONTEXT.md

# Given a folder outside Git, then detect refuses with exit code 2.
mkdir -p "$work/plain"
set +e
out=$("$detect" --offline "$work/plain")
code=$?
set -e
expect not-a-repo "$out" error not-a-git-repository
if [ "$code" -eq 2 ]; then echo "ok   not-a-repo: exit 2"; else echo "FAIL not-a-repo: exit $code"; failures=$((failures + 1)); fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
