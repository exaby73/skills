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

def expect(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")

parent = data["parent"]
expect(parent["modelRequirement"] is None, "parent model remains task-selected")
expect(parent["reasoningRequirement"] is None, "parent reasoning remains task-selected")
expect(parent["finalDecisionOwner"] == "parent-controller", "parent owns final decision")
expect(len(parent["acceptedSelections"]) == 2, "parent selections")

review = data["reviewer"]
for pass_name in ("pass", "rerun"):
    current = review[pass_name]
    expect(current["fresh"] is True, f"{pass_name} reviewer is fresh")
    expect(current["model"] == "gpt-5.6-sol", f"{pass_name} uses Sol-High model")
    expect(current["reasoning"] == "high", f"{pass_name} uses high reasoning")
    expect(current["mode"] == "read-only", f"{pass_name} is read-only")
    expect(current["requiredContext"] == review["pass"]["requiredContext"], f"{pass_name} carries full context")
    expect(current["finalDecisionOwner"] == review["pass"]["finalDecisionOwner"], f"{pass_name} preserves decision owner")
expect(review["rerun"]["differentIdentity"] is True, "rerun uses a fresh identity")
expect(review["unavailable"] == {
    "solAvailable": False,
    "expectedOutcome": "Evidence blocked",
    "fallbackReviewer": None,
}, "Sol unavailable outcome")

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
rg -q 'same complete contract, guidance, target revisions, full diff, and validation evidence' "$SKILL_ROOT/SKILL.md"
rg -q 'fresh read-only Sol-High reviewer' "$SKILL_ROOT/README.md"
rg -q 'run-review\.sh' "$SKILL_ROOT/README.md"

review_script="$SKILL_ROOT/scripts/run-review.sh"
rg -q 'exec 8<' "$review_script"
rg -q 'exec 9<' "$review_script"
rg -q '<&8' "$review_script"
rg -q '<&9' "$review_script"
rg -q 'mktemp -d' "$review_script"
rg -q 'chmod 400' "$review_script"
rg -q 'LC_ALL=C stat' "$review_script"
if rg -q 'exec "\$CODEX_BIN"' "$review_script"; then
	echo 'review launcher still replaces its shell before EXIT cleanup' >&2
	exit 1
fi
rg -q 'prompt descriptor is not a regular file' "$review_script"
rg -q 'gpt-5\.6-sol' "$review_script"
rg -q 'model_reasoning_effort=high' "$review_script"
rg -q -- '-s read-only' "$review_script"
if rg -q 'gpt-5\.6-luna|workspace-write|registry\.sh|run-worker\.sh' "$review_script"; then
    echo 'CLI review route is not Sol-only/read-only' >&2
    exit 1
fi

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/luna-review-routing.XXXXXX")"
trap 'rm -rf -- "$probe_dir"' EXIT
printf 'review prompt\n' >"$probe_dir/prompt"
regular_output="$(CODEX_BIN=/bin/echo "$review_script" --repo "$SKILL_ROOT/.." --prompt-file "$probe_dir/prompt")"
rg -q -- '-s read-only' <<<"$regular_output"

cat >"$probe_dir/codex-snapshot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 0.1
cat
EOF
chmod 700 "$probe_dir/codex-snapshot"
printf '%s\n' 'original review prompt' >"$probe_dir/snapshot-prompt"
mkdir "$probe_dir/tmp"
TMPDIR="$probe_dir/tmp" CODEX_BIN="$probe_dir/codex-snapshot" "$review_script" --repo "$SKILL_ROOT/.." --prompt-file "$probe_dir/snapshot-prompt" >"$probe_dir/snapshot.out" &
snapshot_pid=$!
sleep 0.05
printf '%s\n' 'replacement review prompt' >"$probe_dir/snapshot-prompt"
wait "$snapshot_pid"
rg -q 'original review prompt' "$probe_dir/snapshot.out"
if rg -q 'replacement review prompt' "$probe_dir/snapshot.out"; then
	echo 'review launched with mutable source prompt instead of private snapshot' >&2
	exit 1
fi
if [[ -n "$(find "$probe_dir/tmp" -mindepth 1 -maxdepth 1 -name 'luna-review.*' -print -quit)" ]]; then
	echo 'successful review left a private prompt snapshot behind' >&2
	exit 1
fi

cat >"$probe_dir/codex-fail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
exit 37
EOF
chmod 700 "$probe_dir/codex-fail"
set +e
TMPDIR="$probe_dir/tmp" CODEX_BIN="$probe_dir/codex-fail" "$review_script" --repo "$SKILL_ROOT/.." --prompt-file "$probe_dir/snapshot-prompt" >"$probe_dir/failure.out" 2>"$probe_dir/failure.err"
failure_status=$?
set -e
if [[ "$failure_status" -ne 37 ]]; then
	echo "failed review returned $failure_status instead of 37" >&2
	exit 1
fi
if [[ -n "$(find "$probe_dir/tmp" -mindepth 1 -maxdepth 1 -name 'luna-review.*' -print -quit)" ]]; then
	echo 'failed review left a private prompt snapshot behind' >&2
	exit 1
fi

ln "$probe_dir/prompt" "$probe_dir/hardlink"
if CODEX_BIN=/bin/echo "$review_script" --repo "$SKILL_ROOT/.." --prompt-file "$probe_dir/hardlink" >"$probe_dir/hardlink.out" 2>"$probe_dir/hardlink.err"; then
    echo 'hard-linked review prompt was accepted' >&2
    exit 1
fi
rg -q 'multiply linked' "$probe_dir/hardlink.err"

printf 'PASS: Sol-High review-routing contract\n'
