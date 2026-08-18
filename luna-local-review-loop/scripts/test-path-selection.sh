#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly SKILL_ROOT
FIXTURE="$SKILL_ROOT/references/path-selection-fixtures.json"
readonly FIXTURE

python3 - "$FIXTURE" <<'PY'
import json
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
data = json.loads(fixture.read_text())

required = {
    "spawn",
    "unique-task-identity",
    "follow-up",
    "wait",
    "interrupt-or-close",
    "list-read-collect",
}
native = data["native"]
assert set(native["requiredCapabilities"]) == required
assert data["parent"]["modelRequirement"] is None
assert data["parent"]["reasoningRequirement"] is None
assert len(data["parent"]["selections"]) == 2
assert native["implementationWorker"] == {
    "model": "gpt-5.6-luna",
    "reasoning": "max",
    "fresh": True,
    "readOnlyReview": False,
}

expected = {
    "native-complete": ("native", "completed"),
    "native-interrupted": ("native", "interrupted"),
    "native-post-start-failure": ("native", "failed-no-fallback"),
    "capability-incomplete": ("cli-fallback", "fallback"),
}
observed = {
    case["id"]: (case["expectedPath"], case["expectedOutcome"])
    for case in native["cases"]
}
assert observed == expected
assert data["fallback"]["allowedOnlyBeforeNativeStartup"] is True
assert data["fallback"]["nativeMustNotReadOrWriteRegistry"] is True
print("PASS: path-selection fixture")
PY

rg -q 'complete native capability set' "$SKILL_ROOT/SKILL.md"
rg -q 'model .*gpt-5\.6-luna.*reasoning .*max' "$SKILL_ROOT/SKILL.md"
rg -q 'native startup has begun and then fails' "$SKILL_ROOT/SKILL.md"
rg -q 'CLI fallback only when the complete native capability set' "$SKILL_ROOT/SKILL.md"
rg -q 'Native work uses no project-local registry' "$SKILL_ROOT/README.md"

printf 'PASS: native-first path-selection contract\n'
