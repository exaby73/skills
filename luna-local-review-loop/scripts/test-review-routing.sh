#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly SKILL_ROOT
FIXTURE="$SKILL_ROOT/references/review-routing-fixtures.json"
readonly FIXTURE

python3 - "$FIXTURE" "$SKILL_ROOT" <<'PY'
import json
import re
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
skill_root = Path(sys.argv[2])
data = json.loads(fixture.read_text())

parent = data["parent"]
assert parent["modelRequirement"] is None
assert parent["reasoningRequirement"] is None
assert parent["finalDecisionOwner"] == "parent-controller"
assert len(parent["acceptedSelections"]) == 2

review = data["reviewer"]
for pass_name in ("pass", "rerun"):
    current = review[pass_name]
    assert current["fresh"] is True
    assert current["model"] == "gpt-5.6-sol"
    assert current["reasoning"] == "high"
    assert current["mode"] == "read-only"
assert review["rerun"]["differentIdentity"] is True
assert review["unavailable"] == {
    "solAvailable": False,
    "expectedOutcome": "Evidence blocked",
    "fallbackReviewer": None,
}

for path in (skill_root / "SKILL.md", skill_root / "README.md", skill_root / "agents" / "openai.yaml"):
    text = path.read_text()
    if "Parent performs validation and review" in text:
        raise AssertionError(f"direct parent review wording in {path}")
    if re.search(
        r"parent(?:/controller|-controller)?[^\n]*(?:gpt-5\.6|model_reasoning_effort|reasoning (?:max|high))",
        text,
        flags=re.IGNORECASE,
    ):
        raise AssertionError(f"concrete parent model/reasoning requirement in {path}")
print("PASS: review-routing fixture")
PY

rg -q 'Every .*code-reviewer.*pass and re-review uses a fresh read-only Sol-High' "$SKILL_ROOT/SKILL.md"
rg -q 'model .*gpt-5\.6-sol.*reasoning .*high' "$SKILL_ROOT/SKILL.md"
rg -q 'report .*Evidence blocked' "$SKILL_ROOT/SKILL.md"
rg -q 'Do not substitute a Luna worker' "$SKILL_ROOT/SKILL.md"
rg -q 'fresh read-only Sol-High reviewer' "$SKILL_ROOT/README.md"

printf 'PASS: Sol-High review-routing contract\n'
