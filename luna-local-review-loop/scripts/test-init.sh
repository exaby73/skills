#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly INIT_SCRIPT="$SCRIPT_DIR/init.sh"
readonly REGISTRY_SCRIPT="$SCRIPT_DIR/registry.sh"
readonly RUNNER_SCRIPT="$SCRIPT_DIR/run-worker.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

TEST_ROOT="$(mktemp -d)"
readonly TEST_ROOT
trap 'rm -rf "$TEST_ROOT"' EXIT
readonly REPO_ROOT="$TEST_ROOT/repo"
readonly STATE_ROOT="$TEST_ROOT/state"
readonly BIN_DIR="$TEST_ROOT/bin"
readonly CODEX_STATE="$TEST_ROOT/codex-home"
readonly PROMPT_FILE="$TEST_ROOT/task.txt"
readonly CONTINUE_FILE="$TEST_ROOT/continue.txt"
readonly CODEX_CALLS="$TEST_ROOT/codex-calls.log"
readonly CODEX_COUNTER="$TEST_ROOT/codex-counter"
readonly CODEX_CHILD_PID_FILE="$TEST_ROOT/codex-child.pid"

mkdir -p "$REPO_ROOT/.agents/skills/code-reviewer" "$REPO_ROOT/.agents/skills/caveman" "$BIN_DIR" "$CODEX_STATE"
printf '%s\n' '# code reviewer' >"$REPO_ROOT/.agents/skills/code-reviewer/SKILL.md"
printf '%s\n' '# caveman' >"$REPO_ROOT/.agents/skills/caveman/SKILL.md"
printf '%s\n' 'task prompt' >"$PROMPT_FILE"
printf '%s\n' 'continue and complete' >"$CONTINUE_FILE"
git -C "$REPO_ROOT" init -q
git -C "$REPO_ROOT" config user.email test@example.com
git -C "$REPO_ROOT" config user.name Test
git -C "$REPO_ROOT" add .agents
git -C "$REPO_ROOT" commit -qm init

cat >"$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CODEX_CALLS"
if [[ " $* " == *' exec resume '* ]]; then
  result_path=''
  previous=''
  for argument in "$@"; do
    if [[ "$previous" == '--output-last-message' ]]; then result_path="$argument"; fi
    previous="$argument"
  done
  prompt="$(cat)"
  if [[ "${FAKE_BLOCK_RESUME:-0}" == '1' ]]; then
    printf '%s\n' "$$" > "$CODEX_CHILD_PID_FILE"
    trap 'exit 143' TERM
    trap 'exit 130' INT
    while :; do sleep 1; done
  fi
  if [[ "$prompt" == *'needs parent'* ]]; then
    outcome='needs_parent_action'
    if [[ "${FAKE_INVALID_PARENT_ACTION:-0}" == '1' ]]; then
      parent_action='null'
    else
      parent_action='"run approved validator"'
    fi
  else
    outcome='completed'
    parent_action='null'
  fi
  printf '{"outcome":"%s","summary":"worker concise result","changedFiles":[],"validators":[],"unresolved":[],"parentAction":%s}\n' "$outcome" "$parent_action" > "$result_path"
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"large stream stays in log"}}'
else
	printf '%s\n' 'irrelevant connector warning' >&2
  if [[ "${FAKE_FAIL_HANDSHAKE:-0}" == '1' ]]; then exit 23; fi
  count=0
  [[ ! -f "$CODEX_COUNTER" ]] || count="$(cat "$CODEX_COUNTER")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$CODEX_COUNTER"
  printf '{"type":"thread.started","thread_id":"01fake-session-%s"}\n' "$count"
  printf '%s\n' '{"type":"turn.completed"}'
fi
EOF
chmod +x "$BIN_DIR/codex"
export PATH="$BIN_DIR:$PATH"
export CODEX_CALLS
export CODEX_COUNTER
export CODEX_CHILD_PID_FILE
export CODEX_HOME="$CODEX_STATE"

before_status="$(git -C "$REPO_ROOT" status --short)"
mkdir -p "$REPO_ROOT/.agents/agent-registry"
cat >"$REPO_ROOT/.agents/agent-registry/registry.json" <<EOF
{"schema_version":1,"registry":"luna-local-review-loop","workers":[{"task_id":"legacy-live","status":"active"}]}
EOF
if "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/legacy-live.out" 2>&1; then
	fail 'init abandoned a live legacy project registry'
fi
rg -F 'legacy project registry contains 1 live worker' "$TEST_ROOT/legacy-live.out" >/dev/null || fail 'legacy registry refusal lacked recovery evidence'
[[ ! -e "$STATE_ROOT" ]] || fail 'legacy registry refusal created external state'
rm -rf "$REPO_ROOT/.agents/agent-registry"
registry_path="$($INIT_SCRIPT --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --print-path)"
state_root_real="$(cd "$STATE_ROOT" && pwd -P)"
[[ "$registry_path" == "$state_root_real/"*/registry.json ]] || fail "registry was not created below the external state root: $registry_path"
[[ ! -e "$REPO_ROOT/.agents/agent-registry" ]] || fail 'init created project-local registry state'
[[ ! -e "$REPO_ROOT/.gitignore" ]] || fail 'init modified repository ignore rules'
[[ "$(git -C "$REPO_ROOT" status --short)" == "$before_status" ]] || fail 'init modified repository files'
jq -e '.schema_version == 2 and .workers == [] and .identity_ledger == []' "$registry_path" >/dev/null || fail 'new registry schema is invalid'

if CODEX_BIN="$TEST_ROOT/missing-codex" "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/missing-codex.out" 2>&1; then
	fail 'normal init accepted a missing Codex CLI'
fi
rg -F 'Codex CLI not found' "$TEST_ROOT/missing-codex.out" >/dev/null || fail 'normal init did not report the missing Codex CLI'
CODEX_BIN="$TEST_ROOT/missing-codex" "$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'recovery-only init unexpectedly required Codex'

if "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$REPO_ROOT/.runtime/luna" >"$TEST_ROOT/project-state.out" 2>&1; then
	fail 'init accepted a state root inside the repository'
fi
[[ ! -e "$REPO_ROOT/.runtime" ]] || fail 'init mutated the repository before rejecting an in-project state root'

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-launch --scope 'exact retry scope' >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-launch --status failed --evidence 'pre-bind launch failed' >/dev/null
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-retry --scope 'exact retry scope' >/dev/null 2>&1; then
	fail 'duplicate scope was accepted without retry-of'
fi
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id retry-launch --scope 'exact retry scope' --retry-of failed-launch >/dev/null
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id duplicate-retry --scope 'exact retry scope' --retry-of failed-launch >/dev/null 2>&1; then
	fail 'one failed attempt accepted multiple retry children'
fi
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id retry-launch --status interrupted --evidence 'retry test complete' >/dev/null
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id duplicate-retired-retry --scope 'exact retry scope' --retry-of failed-launch >/dev/null 2>&1; then
	fail 'retired failed attempt accepted a second retry child'
fi
jq -e 'any(.identity_ledger[]; .task_id == "retry-launch" and .retry_of == "failed-launch" and .scope == "exact retry scope")' "$registry_path" >/dev/null || fail 'retry linkage was not recorded'

readonly INVALID_CODEX_STATE="$TEST_ROOT/codex-home-file"
printf '%s\n' 'not a directory' >"$INVALID_CODEX_STATE"
if CODEX_HOME="$INVALID_CODEX_STATE" CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id denied-runtime --scope 'runtime permission probe' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/denied-runtime.out" 2>&1; then
	fail 'runner accepted an invalid Codex runtime state path'
fi
jq -e 'all(.identity_ledger[]; .task_id != "denied-runtime")' "$registry_path" >/dev/null || fail 'runtime permission failure burned a task reservation'

if FAKE_FAIL_HANDSHAKE=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-runner --scope 'runner retry scope' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/failed-runner.out" 2>&1; then
	fail 'failed handshake unexpectedly succeeded'
fi
jq -e 'any(.identity_ledger[]; .task_id == "failed-runner" and .session_id == null and .status == "retired" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'failed pre-bind launch was not atomically retired'
retry_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-runner-retry --scope 'runner retry scope' --retry-of failed-runner --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/retry.err")"
jq -e '.outcome == "completed"' <<<"$retry_output" >/dev/null || fail 'runner retry did not complete'

runner_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id fast-worker --scope 'one fast task' --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/runner.err")"
jq -e '.outcome == "completed" and .summary == "worker concise result"' <<<"$runner_output" >/dev/null || fail 'runner did not return concise structured output'
"$REGISTRY_SCRIPT" assert-no-active --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'completed worker was not atomically retired'
jq -e 'any(.identity_ledger[]; .task_id == "fast-worker" and (.session_id | startswith("01fake-session-")) and .status == "retired" and .terminal_status == "completed")' "$registry_path" >/dev/null || fail 'fast worker identity/result was not retained'

printf '%s\n' 'needs parent' >"$PROMPT_FILE"
needs_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --scope 'one continued task' --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/needs.err")"
jq -e '.outcome == "needs_parent_action"' <<<"$needs_output" >/dev/null || fail 'parent-action result was not returned'
jq -e 'any(.workers[]; .task_id == "continued-worker" and .status == "active" and (.session_id | startswith("01fake-session-")))' "$registry_path" >/dev/null || fail 'parent-action worker was not retained as active'

sleep 0.01 &
stale_owner_pid=$!
wait "$stale_owner_pid"
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --pid "$stale_owner_pid" --token stale-owner >/dev/null
sleep 30 &
claim_owner_a=$!
sleep 30 &
claim_owner_b=$!
claim_status_a=0
claim_status_b=0
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --pid "$claim_owner_a" --token contender-a >"$TEST_ROOT/claim-a.out" 2>&1 &
claim_command_a=$!
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --pid "$claim_owner_b" --token contender-b >"$TEST_ROOT/claim-b.out" 2>&1 &
claim_command_b=$!
wait "$claim_command_a" || claim_status_a=$?
wait "$claim_command_b" || claim_status_b=$?
if [[ "$claim_status_a" -eq 0 && "$claim_status_b" -eq 0 ]]; then
	fail 'two contenders reclaimed the same stale invocation claim'
fi
if [[ "$claim_status_a" -ne 0 && "$claim_status_b" -ne 0 ]]; then
	fail 'no contender reclaimed the stale invocation claim'
fi
if [[ "$claim_status_a" -eq 0 ]]; then
	winning_claim_token='contender-a'
else
	winning_claim_token='contender-b'
fi
jq -e --arg token "$winning_claim_token" 'any(.workers[]; .task_id == "continued-worker" and .invocation_token == $token)' "$registry_path" >/dev/null || fail 'atomic stale claim winner was not recorded'
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --prompt-file "$CONTINUE_FILE" >"$TEST_ROOT/concurrent.out" 2>&1; then
	fail 'concurrent continuation bypassed the registry-backed invocation claim'
fi
if ! jq -e 'any(.workers[]; .task_id == "continued-worker" and .status == "active")' "$registry_path" >/dev/null; then
	fail 'rejected concurrent continuation retired the live worker'
fi
"$REGISTRY_SCRIPT" release-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --token "$winning_claim_token" >/dev/null
kill "$claim_owner_a" "$claim_owner_b" 2>/dev/null || true
wait "$claim_owner_a" 2>/dev/null || true
wait "$claim_owner_b" 2>/dev/null || true
continue_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --prompt-file "$CONTINUE_FILE" 2>"$TEST_ROOT/continue.err")"
jq -e '.outcome == "completed"' <<<"$continue_output" >/dev/null || fail 'exact-session continuation did not complete'
"$REGISTRY_SCRIPT" assert-empty --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'continued worker was not retired'

printf '%s\n' 'needs parent' >"$PROMPT_FILE"
if FAKE_INVALID_PARENT_ACTION=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-parent-action --scope 'invalid parent action contract' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-parent.out" 2>&1; then
	fail 'runner accepted needs_parent_action with a null parentAction'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-parent-action" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'invalid structured result was not retired as failed'

if "$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing --session-id nope --handle process-123 >/dev/null 2>&1; then
	fail 'ambiguous process handle argument was accepted'
fi
if rg -- '--ephemeral' "$CODEX_CALLS" >/dev/null; then fail 'runner used --ephemeral'; fi
if rg -- '-maxdepth' "$RUNNER_SCRIPT" >/dev/null; then fail 'runner used GNU-only find arguments'; fi
resume_count="$(rg -c 'exec resume .*01fake-session-[0-9]+ -' "$CODEX_CALLS")"
[[ "$resume_count" -eq 5 ]] || fail "expected five exact-session resumes, got $resume_count"
ignore_count="$(rg -c -- '--ignore-user-config' "$CODEX_CALLS")"
[[ "$ignore_count" -eq 10 ]] || fail "expected unrelated user MCP config disabled on every Codex call, got $ignore_count"
if rg -F 'irrelevant connector warning' "$(dirname "$registry_path")/artifacts/fast-worker/launch.jsonl" >/dev/null; then
	fail 'handshake stderr corrupted the JSONL event stream'
fi
rg -F 'irrelevant connector warning' "$(dirname "$registry_path")/artifacts/fast-worker/launch.stderr.log" >/dev/null || fail 'handshake stderr was not preserved separately'
[[ "$(git -C "$REPO_ROOT" status --short)" == "$before_status" ]] || fail 'worker lifecycle modified repository tooling state'

printf '%s\n' 'terminate child safely' >"$PROMPT_FILE"
rm -f "$CODEX_CHILD_PID_FILE"
FAKE_BLOCK_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id terminated-worker --scope 'terminate child before retirement' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/terminated.out" 2>"$TEST_ROOT/terminated.err" &
terminating_runner_pid=$!
poll_attempt=0
while [[ ! -s "$CODEX_CHILD_PID_FILE" && "$poll_attempt" -lt 100 ]]; do
	sleep 0.05
	poll_attempt=$((poll_attempt + 1))
done
[[ -s "$CODEX_CHILD_PID_FILE" ]] || fail 'blocking Codex child did not start'
codex_child_pid="$(cat "$CODEX_CHILD_PID_FILE")"
kill -TERM "$terminating_runner_pid"
terminated_status=0
wait "$terminating_runner_pid" || terminated_status=$?
[[ "$terminated_status" -ne 0 ]] || fail 'terminated runner exited successfully'
poll_attempt=0
while kill -0 "$codex_child_pid" 2>/dev/null && [[ "$poll_attempt" -lt 100 ]]; do
	sleep 0.05
	poll_attempt=$((poll_attempt + 1))
done
if kill -0 "$codex_child_pid" 2>/dev/null; then
	fail 'Codex child survived runner termination and registry retirement'
fi
jq -e 'any(.identity_ledger[]; .task_id == "terminated-worker" and .status == "retired" and .terminal_status == "failed") and all(.workers[]; .task_id != "terminated-worker")' "$registry_path" >/dev/null || fail 'terminated runner retired registry state before child cleanup completed'

missing_repo="$TEST_ROOT/missing-skills"
git init -q "$missing_repo"
if "$INIT_SCRIPT" --repo "$missing_repo" --state-root "$STATE_ROOT" >"$TEST_ROOT/missing.out" 2>&1; then
	fail 'init accepted missing project skills'
fi
rg -F -- '-a universal' "$TEST_ROOT/missing.out" >/dev/null || fail 'init did not explain universal-only installation'
[[ ! -e "$missing_repo/.agents" ]] || fail 'init installed missing skills instead of remaining non-mutating'

symlink_repo="$TEST_ROOT/symlink-skills"
symlink_target="$TEST_ROOT/symlink-target"
git init -q "$symlink_repo"
mkdir -p "$symlink_target/skills/code-reviewer" "$symlink_target/skills/caveman"
printf '%s\n' '# code reviewer' >"$symlink_target/skills/code-reviewer/SKILL.md"
printf '%s\n' '# caveman' >"$symlink_target/skills/caveman/SKILL.md"
ln -s "$symlink_target" "$symlink_repo/.agents"
if "$INIT_SCRIPT" --repo "$symlink_repo" --state-root "$STATE_ROOT" >"$TEST_ROOT/symlink.out" 2>&1; then
	fail 'init accepted a symlinked project skill ancestor'
fi

mv "$REPO_ROOT/.agents/skills" "$REPO_ROOT/.agents/skills.off"
"$REGISTRY_SCRIPT" active --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'registry recovery required launch-only project skills'
mv "$REPO_ROOT/.agents/skills.off" "$REPO_ROOT/.agents/skills"

printf '%s\n' 'PASS: safe external registry, single-child retries, serialized resumes, recovery-only access, strict result contract, and atomic retirement'
