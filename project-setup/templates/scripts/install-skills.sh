#!/usr/bin/env bash
# Install the latest version of each agent skill in skills-lock.json for Claude
# Code and Codex, into .agents/skills/ linked into .claude/skills/, and record
# it in the lock. The project's `setup` task runs this.
set -euo pipefail

SKILLS_VERSION="${SKILLS_VERSION:-<<SKILLS_VERSION>>}"

cd "$(git rev-parse --show-toplevel)"
if [ ! -f skills-lock.json ]; then
  echo "skills-lock.json not found; add a skill first (docs/development/manage-agent-skills.md)" >&2
  exit 1
fi

# Both folders hold only installed copies, which Git ignores.
rm -rf .agents/skills
mkdir -p .claude/skills
find .claude/skills -maxdepth 1 -type l -delete

# One `add` for each source, so each source is cloned once. Each `add`
# rewrites skills-lock.json, so they run one after another.
node -e '
  const sources = {};
  for (const [name, entry] of Object.entries(require("./skills-lock.json").skills)) {
    (sources[entry.source] ??= []).push(name);
  }
  for (const [source, names] of Object.entries(sources)) console.log(source, ...names);
' | while read -r source names; do
  # shellcheck disable=SC2086 # one --skill flag takes every name
  npx --yes "skills@${SKILLS_VERSION}" add "$source" --skill $names --agent claude-code codex --yes < /dev/null
done
