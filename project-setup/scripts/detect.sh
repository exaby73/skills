#!/usr/bin/env bash
# Report which pieces of the agent workflow a repository already has.
#
# Usage: detect.sh [--offline] [repo-dir]
#
# Prints one key=value line per fact, read-only. Values are single words or
# comma-separated lists; "none" means nothing was found. --offline skips the
# GitHub label lookup, which needs `gh` and the network.
set -eu

offline=false
repo_dir="."
while [ $# -gt 0 ]; do
  case "$1" in
    --offline) offline=true ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) repo_dir="$1" ;;
  esac
  shift
done

if ! root=$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null); then
  echo "error=not-a-git-repository"
  exit 2
fi
cd "$root"

emit() { printf '%s=%s\n' "$1" "${2:-none}"; }
join() { local IFS=,; printf '%s' "$*"; }

# Every file Git would commit: tracked plus untracked-but-not-ignored.
files=$(git ls-files --cached --others --exclude-standard | sort -u)
has_file() { printf '%s\n' "$files" | grep -qx -- "$1"; }
has_match() { printf '%s\n' "$files" | grep -qE -- "$1"; }

emit repo_root "$root"

if git rev-parse --verify -q HEAD >/dev/null; then
  emit commit_count "$(git rev-list --count HEAD)"
else
  emit commit_count 0
fi
emit branch "$(git symbolic-ref --short -q HEAD || echo detached)"

# Greenfield: nothing but docs, licences, dotfile config, and what this skill writes.
source_count=$(printf '%s\n' "$files" | grep -v '^$' \
  | grep -vE '(^|/)(README|LICENSE|LICENCE|CHANGELOG|CONTRIBUTING|CODE_OF_CONDUCT)[^/]*$' \
  | grep -vE '\.(md|txt)$' \
  | grep -vE '^(docs|\.github|\.cadre|\.agents|\.claude|\.scratch)/' \
  | grep -vE '^\.[^/]+$' \
  | grep -vE '^(skills-lock\.json|Taskfile\.ya?ml|justfile|Justfile|Makefile|mise\.toml|([^/]+/)?install-skills\.sh)$' \
  | wc -l | tr -d ' ')
emit source_files "$source_count"
if [ "$source_count" -eq 0 ]; then emit kind greenfield; else emit kind brownfield; fi

stacks=()
has_match '(^|/)package\.json$' && stacks+=(node)
has_match '(^|/)deno\.jsonc?$' && stacks+=(deno)
has_match '(^|/)go\.mod$' && stacks+=(go)
has_match '(^|/)Cargo\.toml$' && stacks+=(rust)
has_match '(^|/)(pyproject\.toml|requirements[^/]*\.txt|setup\.py)$' && stacks+=(python)
has_match '(^|/)pubspec\.yaml$' && stacks+=(dart)
has_match '(^|/)Gemfile$' && stacks+=(ruby)
has_match '(^|/)composer\.json$' && stacks+=(php)
has_match '\.(csproj|sln)$' && stacks+=(dotnet)
has_match '(^|/)(pom\.xml|build\.gradle(\.kts)?)$' && stacks+=(jvm)
has_match '(^|/)mix\.exs$' && stacks+=(elixir)
has_match '(^|/)Package\.swift$' && stacks+=(swift)
emit stacks "$(join ${stacks[@]+"${stacks[@]}"})"

# Task runners, most specific first. The first one is where `setup` goes.
runners=()
runner_file=""
for f in Taskfile.yml Taskfile.yaml; do
  if has_file "$f"; then runners+=(task); runner_file=${runner_file:-$f}; break; fi
done
for f in justfile Justfile; do
  if has_file "$f"; then runners+=(just); runner_file=${runner_file:-$f}; break; fi
done
if has_file Makefile; then runners+=(make); runner_file=${runner_file:-Makefile}; fi
if has_file mise.toml; then runners+=(mise); runner_file=${runner_file:-mise.toml}; fi
if has_file package.json && grep -q '"scripts"' package.json; then
  pm=npm
  has_file pnpm-lock.yaml && pm=pnpm
  has_file yarn.lock && pm=yarn
  { has_file bun.lockb || has_file bun.lock; } && pm=bun
  runners+=("$pm")
  runner_file=${runner_file:-package.json}
fi
emit runners "$(join ${runners[@]+"${runners[@]}"})"
emit runner_file "$runner_file"

setup_task=missing
case "$runner_file" in
  Taskfile.y*ml) grep -qE '^  setup:' "$runner_file" && setup_task=present ;;
  justfile|Justfile|Makefile) grep -qE '^setup:' "$runner_file" && setup_task=present ;;
  mise.toml) grep -qE '^\[tasks\.setup\]' "$runner_file" && setup_task=present ;;
  package.json) grep -qE '"setup"[[:space:]]*:' "$runner_file" && setup_task=present ;;
esac
emit setup_task "$setup_task"

# Docs governance markers.
if [ -L AGENTS.md ]; then emit agents_md symlink
elif [ -f AGENTS.md ]; then emit agents_md file
else emit agents_md missing; fi

if [ -L CLAUDE.md ]; then
  if [ "$(readlink CLAUDE.md)" = "AGENTS.md" ]; then emit claude_md symlink-to-agents
  else emit claude_md symlink-other; fi
elif [ -f CLAUDE.md ]; then
  if [ "$(grep -cv '^[[:space:]]*$' CLAUDE.md)" -le 1 ] && grep -qx '@AGENTS.md' CLAUDE.md; then
    emit claude_md import-agents
  else
    emit claude_md file
  fi
else
  emit claude_md missing
fi

[ -f docs/README.md ] && emit docs_index present || emit docs_index missing
[ -f docs/product-decisions.md ] && emit decision_register present || emit decision_register missing
[ -d docs/adr ] && emit adr_dir present || emit adr_dir missing

if [ -f GLOSSARY-MAP.md ]; then emit glossary GLOSSARY-MAP.md
elif [ -f GLOSSARY.md ]; then emit glossary GLOSSARY.md
elif [ -f CONTEXT-MAP.md ]; then emit glossary legacy:CONTEXT-MAP.md
elif [ -f CONTEXT.md ]; then emit glossary legacy:CONTEXT.md
elif [ -f docs/CONTEXT.md ]; then emit glossary legacy:docs/CONTEXT.md
else emit glossary missing; fi

doc_folders=()
for d in product operations design development agents adr qualification research; do
  [ -d "docs/$d" ] && doc_folders+=("$d")
done
emit doc_folders "$(join ${doc_folders[@]+"${doc_folders[@]}"})"

agent_docs=()
for f in review merge-trains notices issue-tracker triage-labels domain; do
  [ -f "docs/agents/$f.md" ] && agent_docs+=("$f")
done
emit agent_docs "$(join ${agent_docs[@]+"${agent_docs[@]}"})"
[ -f docs/development/writing-tests.md ] && emit writing_tests_doc present || emit writing_tests_doc missing
[ -f docs/development/manage-agent-skills.md ] && emit manage_skills_doc present || emit manage_skills_doc missing

ignored() { git check-ignore -q --no-index "$1"; }
ignored .scratch/x && emit scratch_ignored yes || emit scratch_ignored no

# Agent skills.
[ -f skills-lock.json ] && emit skills_lock present || emit skills_lock missing
if ignored .agents/skills/x && ignored .claude/skills/x; then emit skills_dirs_ignored yes
elif ignored .agents/skills/x || ignored .claude/skills/x; then emit skills_dirs_ignored partial
else emit skills_dirs_ignored no; fi
emit tracked_skill_files "$(git ls-files .agents/skills .claude/skills | wc -l | tr -d ' ')"

# Cadre.
if [ -f .cadre/project.json ]; then emit cadre_project initialized
elif [ -d .cadre ]; then emit cadre_project partial
else emit cadre_project missing; fi

# Issue tracker.
remote_url=$(git remote get-url origin 2>/dev/null || true)
github_repo=none
case "$remote_url" in
  *github.com[:/]*)
    github_repo=${remote_url#*github.com[:/]}
    github_repo=${github_repo%.git}
    ;;
esac
emit github_repo "$github_repo"

triage_labels="unchecked"
if [ "$offline" = false ] && [ "$github_repo" != none ] && command -v gh >/dev/null 2>&1; then
  if names=$(gh label list --repo "$github_repo" --limit 500 --json name --jq '.[].name' 2>/dev/null); then
    missing=()
    for l in needs-triage needs-info ready-for-agent ready-for-human wontfix; do
      printf '%s\n' "$names" | grep -qx "$l" || missing+=("$l")
    done
    if [ ${#missing[@]} -eq 0 ]; then triage_labels=present
    else triage_labels="missing:$(join "${missing[@]}")"; fi
  fi
fi
emit triage_labels "$triage_labels"

# CI, migrations, and merge trains.
has_match '^\.github/workflows/[^/]+\.ya?ml$' && emit ci github-actions || emit ci none
migration_dirs=$(printf '%s\n' "$files" | grep -oE '^(.*/)?(migrations|migrate|drizzle)/' | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')
emit migration_dirs "${migration_dirs:-none}"
emit train_branches "$(git for-each-ref --format='%(refname:short)' 'refs/heads/train/*' 'refs/remotes/*/train/*' | wc -l | tr -d ' ')"

# Notices: pages that describe what users may do, pay, or have kept.
notice_signals=$(printf '%s\n' "$files" | grep -iE '(^|/)[^/]*(privacy|terms|pricing|legal)[^/]*(/|$)' \
  | grep -vE '^(docs|\.github)/' | head -5 | tr '\n' ',' | sed 's/,$//')
emit notice_signals "${notice_signals:-none}"

# Frontend: a hint for offering the design skills.
has_match '\.(tsx|jsx|svelte|vue|astro|html|css|scss)$' && emit frontend yes || emit frontend no
