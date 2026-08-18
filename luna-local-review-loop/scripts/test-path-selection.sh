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
    "model-selection",
    "reasoning-selection",
    "read-only-or-sandbox-control",
}
native = data["native"]
assert set(native["requiredCapabilities"]) == required
assert data["parent"]["modelRequirement"] is None
assert data["parent"]["reasoningRequirement"] is None
assert len(data["parent"]["selections"]) == 2
assert native["configuration"] == {
    "implementation": {
        "model": "gpt-5.6-luna",
        "reasoning": "max",
        "sandbox": "task-selected-read-only-or-workspace-write",
    },
    "review": {
        "model": "gpt-5.6-sol",
        "reasoning": "high",
        "mode": "read-only",
    },
}
assert native["implementationWorker"] == {
    "model": "gpt-5.6-luna",
    "reasoning": "max",
    "fresh": True,
    "readOnlyReview": False,
}

def select_path(case):
    """Derive the route/outcome from the pre-start and lifecycle inputs."""
    if case["startup"] == "started":
        if case["nativeLifecycle"] == "failed":
            return "native", "failed-no-fallback"
        if case["nativeLifecycle"] == "interrupted":
            return "native", "interrupted"
        if (
            case["capabilityResult"] != "complete"
            or case["configurationResult"] != "complete"
        ):
            return "native", "Evidence blocked"
        if case["reviewerAvailability"] != "native-sol-high":
            return "native", "Evidence blocked"
        return "native", case["nativeLifecycle"]
    if case["fallbackState"] == "active":
        return "cli-fallback", "fallback-active-pinned"
    if case["fallbackState"] not in {"clear", "not-initialized"}:
        return "parent-action", "preflight-blocked"
    native_ready = (
        case["capabilityResult"] == "complete"
        and case["configurationResult"] == "complete"
        and case["fallbackState"] in {"clear", "not-initialized"}
        and case["reviewerAvailability"] == "native-sol-high"
    )
    if native_ready:
        return "native", case["nativeLifecycle"]
    if case["reviewerAvailability"] == "cli-sol-high":
        return "cli-fallback", "fallback"
    return "cli-fallback", "Evidence blocked"

for case in native["cases"]:
    observed_path, observed_outcome = select_path(case)
    assert (observed_path, observed_outcome) == (
        case["expectedPath"],
        case["expectedOutcome"],
    ), case["id"]

fallback = data["fallback"]
assert fallback["ownershipPreflight"] == {
    "readOnly": True,
    "beforeNativeStartup": True,
    "activeTaskPinsScope": True,
    "ambiguousStateBlocksStartup": True,
    "missingRegistryState": "not-initialized-clear",
}
assert fallback["allowedOnlyBeforeNativeStartup"] is True
assert fallback["nativeMustNotReadOrWriteRegistry"] is True
assert fallback["solReviewRoute"] == {
    "script": "scripts/run-review.sh",
    "model": "gpt-5.6-sol",
    "reasoning": "high",
    "mode": "read-only",
    "unavailableOutcome": "Evidence blocked",
}
print("PASS: path-selection fixture")
PY

rg -q 'complete native capability set' "$SKILL_ROOT/SKILL.md"
rg -q 'exact model selection.*exact reasoning selection' "$SKILL_ROOT/SKILL.md"
rg -q 'read-only or sandbox control' "$SKILL_ROOT/SKILL.md"
rg -q 'fallback-ownership preflight' "$SKILL_ROOT/SKILL.md"
rg -q 'model .*gpt-5\.6-luna.*reasoning .*max' "$SKILL_ROOT/SKILL.md"
rg -q 'native startup has begun and then fails' "$SKILL_ROOT/SKILL.md"
rg -q 'CLI fallback only when the complete native capability set' "$SKILL_ROOT/SKILL.md"
rg -q 'worker-result\.schema\.json' "$SKILL_ROOT/SKILL.md"
rg -q 'Native work uses no project-local registry' "$SKILL_ROOT/README.md"
rg -q 'Before closing a parent goal for a CLI-fallback run' "$SKILL_ROOT/README.md"
rg -q 'run-review\.sh' "$SKILL_ROOT/README.md"

printf 'PASS: native-first path-selection contract\n'
