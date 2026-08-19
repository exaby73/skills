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

def expect(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")

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
    "cross-path-claim",
}
native = data["native"]
expect(set(native["requiredCapabilities"]) == required, "native capability gate")
expect(data["parent"]["modelRequirement"] is None, "parent model remains task-selected")
expect(data["parent"]["reasoningRequirement"] is None, "parent reasoning remains task-selected")
expect(len(data["parent"]["selections"]) == 2, "parent selections")
expect(native["configuration"] == {
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
}, "native worker and reviewer configuration")
expect(native["implementationWorker"] == {
    "model": "gpt-5.6-luna",
    "reasoning": "max",
    "fresh": True,
    "readOnlyReview": False,
}, "native implementation worker configuration")
expect(native["workerBoundary"] == {
    "soleWorker": True,
    "maySpawnSubagents": False,
    "mayDelegate": False,
}, "native worker delegation boundary")
expect(native["crossPathClaim"] == {
    "authority": "host-owned",
    "scope": ["canonical-checkout-identity", "immutable-scope"],
    "acquireBefore": "native-spawn",
    "heldThrough": "native-lifecycle",
    "nonTerminalContinuation": "same-owner-reentry",
    "conflictOutcome": "parent-action",
}, "native cross-path claim contract")

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
    if case["crossPathClaim"] == "unavailable":
        return "parent-action", "cross-path-claim-blocked"
    if case["crossPathClaim"] == "conflict":
        return "parent-action", "cross-path-claim-conflict"
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
    expect((observed_path, observed_outcome) == (
        case["expectedPath"],
        case["expectedOutcome"],
    ), case["id"])

fallback = data["fallback"]
expect(fallback["ownershipPreflight"] == {
    "readOnly": True,
    "beforeNativeStartup": True,
    "activeTaskPinsScope": True,
    "ambiguousStateBlocksStartup": True,
    "missingRegistryState": "not-initialized-clear",
}, "fallback ownership preflight")
expect(fallback["allowedOnlyBeforeNativeStartup"] is True, "fallback startup boundary")
expect(fallback["nativeMustNotReadOrWriteRegistry"] is True, "native registry isolation")
expect(fallback["crossPathClaim"] == {
    "authority": "host-owned",
    "scope": ["canonical-checkout-identity", "immutable-scope"],
    "acquireBefore": "fallback-registry-reserve",
    "heldThrough": "fallback-lifecycle",
    "nonTerminalContinuation": "same-owner-reentry",
    "rejectsActiveNativeClaim": True,
    "unavailableOutcome": "parent-action",
}, "fallback cross-path claim contract")
expect(fallback["workerBoundary"] == {
    "soleWorker": True,
    "maySpawnSubagents": False,
    "mayDelegate": False,
    "injectedInto": ["initial-cli-worker-prompt", "continuation-cli-worker-prompt"],
}, "fallback worker delegation boundary")
expect(fallback["solReviewRoute"] == {
    "script": "scripts/run-review.sh",
    "model": "gpt-5.6-sol",
    "reasoning": "high",
    "mode": "read-only",
    "unavailableOutcome": "Evidence blocked",
}, "fallback Sol review route")
print("PASS: path-selection fixture")
PY

rg -q 'complete native capability set' "$SKILL_ROOT/SKILL.md"
rg -q 'exact model selection.*exact reasoning selection' "$SKILL_ROOT/SKILL.md"
rg -q 'read-only or sandbox control' "$SKILL_ROOT/SKILL.md"
rg -q 'sole worker.*must not spawn or delegate' "$SKILL_ROOT/SKILL.md"
rg -q 'never spawns, delegates to, or hands work' "$SKILL_ROOT/SKILL.md"
rg -q 'fallback-ownership preflight' "$SKILL_ROOT/SKILL.md"
rg -q 'atomic host-owned cross-path claim' "$SKILL_ROOT/SKILL.md"
rg -q 'bash scripts/cross-path-claim\.sh acquire' "$SKILL_ROOT/SKILL.md"
rg -q 'fallback launcher uses that same claim' "$SKILL_ROOT/SKILL.md"
rg -q 'held through the selected native or CLI lifecycle' "$SKILL_ROOT/SKILL.md"
rg -q 'fallback controller uses.*before `registry\.sh reserve`' "$SKILL_ROOT/SKILL.md"
rg -q 'sole worker for this immutable task' "$SKILL_ROOT/scripts/run-worker.sh"
rg -q 'never spawn, delegate to, or hand work to another subagent' "$SKILL_ROOT/scripts/run-worker.sh"
rg -q 'snapshot_prompt_file "\$PROMPT_FILE" "\$prompt_staging" 1' "$SKILL_ROOT/scripts/run-worker.sh"
rg -q 'snapshot_prompt_file "\$resume_prompt_source" "\$continuation_prompt" 1' "$SKILL_ROOT/scripts/run-worker.sh"
rg -q 'model .*gpt-5\.6-luna.*reasoning .*max' "$SKILL_ROOT/SKILL.md"
rg -q 'native startup has begun and then fails' "$SKILL_ROOT/SKILL.md"
rg -q 'CLI fallback only when the complete native capability set' "$SKILL_ROOT/SKILL.md"
rg -q 'worker-result\.schema\.json' "$SKILL_ROOT/SKILL.md"
rg -q 'Native work uses no project-local registry' "$SKILL_ROOT/README.md"
rg -q 'host-owned cross-path claim' "$SKILL_ROOT/README.md"
rg -q 'Before closing a parent goal for a CLI-fallback run' "$SKILL_ROOT/README.md"
rg -q 'run-review\.sh' "$SKILL_ROOT/README.md"

for contract_doc in "$SKILL_ROOT/README.md" "$SKILL_ROOT/SKILL.md"; do
  rg -q 'Registry-owned fallback artifacts' "$contract_doc"
  rg -q 'host-owned coordination artifacts' "$contract_doc"
  rg -q '\.luna-checkout-identity.*physical Git administration directory' "$contract_doc"
  rg -q '\.luna-cross-path-claims.*Git common metadata' "$contract_doc"
  rg -q 'No other skill-owned durable artifact uses Git administration/common metadata' "$contract_doc"
  rg -q 'not fallback registry state, registry authority' "$contract_doc"
done

printf 'PASS: native-first path-selection contract\n'
