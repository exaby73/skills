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
  if [[ "$prompt" == *'needs parent'* ]]; then
    outcome='needs_parent_action'
    parent_action='"run approved validator"'
  else
    outcome='completed'
    parent_action='null'
  fi
  printf '{"outcome":"%s","summary":"worker concise result","changedFiles":[],"validators":[],"unresolved":[],"parentAction":%s}\n' "$outcome" "$parent_action" > "$result_path"
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"large stream stays in log"}}'
else
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
export CODEX_HOME="$CODEX_STATE"

before_status="$(git -C "$REPO_ROOT" status --short)"
registry_path="$($INIT_SCRIPT --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --print-path)"
state_root_real="$(cd "$STATE_ROOT" && pwd -P)"
[[ "$registry_path" == "$state_root_real/"*/registry.json ]] || fail "registry was not created below the external state root: $registry_path"
[[ ! -e "$REPO_ROOT/.agents/agent-registry" ]] || fail 'init created project-local registry state'
[[ ! -e "$REPO_ROOT/.gitignore" ]] || fail 'init modified repository ignore rules'
[[ "$(git -C "$REPO_ROOT" status --short)" == "$before_status" ]] || fail 'init modified repository files'
jq -e '.schema_version == 2 and .workers == [] and .identity_ledger == []' "$registry_path" >/dev/null || fail 'new registry schema is invalid'

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-launch --scope 'exact retry scope' >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-launch --status failed --evidence 'pre-bind launch failed' >/dev/null
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-retry --scope 'exact retry scope' >/dev/null 2>&1; then
	fail 'duplicate scope was accepted without retry-of'
fi
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id retry-launch --scope 'exact retry scope' --retry-of failed-launch >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id retry-launch --status interrupted --evidence 'retry test complete' >/dev/null
jq -e 'any(.identity_ledger[]; .task_id == "retry-launch" and .retry_of == "failed-launch" and .scope == "exact retry scope")' "$registry_path" >/dev/null || fail 'retry linkage was not recorded'

readonly LOCKED_CODEX_STATE="$TEST_ROOT/locked-codex-home"
mkdir -p "$LOCKED_CODEX_STATE"
chmod 0500 "$LOCKED_CODEX_STATE"
if CODEX_HOME="$LOCKED_CODEX_STATE" CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id denied-runtime --scope 'runtime permission probe' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/denied-runtime.out" 2>&1; then
	fail 'runner accepted a non-writable Codex runtime directory'
fi
chmod 0700 "$LOCKED_CODEX_STATE"
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
continue_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --prompt-file "$CONTINUE_FILE" 2>"$TEST_ROOT/continue.err")"
jq -e '.outcome == "completed"' <<<"$continue_output" >/dev/null || fail 'exact-session continuation did not complete'
"$REGISTRY_SCRIPT" assert-empty --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'continued worker was not retired'

if "$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing --session-id nope --handle process-123 >/dev/null 2>&1; then
	fail 'ambiguous process handle argument was accepted'
fi
if rg -- '--ephemeral' "$CODEX_CALLS" >/dev/null; then fail 'runner used --ephemeral'; fi
resume_count="$(rg -c 'exec resume .*01fake-session-[0-9]+ -' "$CODEX_CALLS")"
[[ "$resume_count" -eq 4 ]] || fail "expected four exact-session resumes, got $resume_count"
ignore_count="$(rg -c -- '--ignore-user-config' "$CODEX_CALLS")"
[[ "$ignore_count" -eq 8 ]] || fail "expected unrelated user MCP config disabled on every Codex call, got $ignore_count"
[[ "$(git -C "$REPO_ROOT" status --short)" == "$before_status" ]] || fail 'worker lifecycle modified repository tooling state'

missing_repo="$TEST_ROOT/missing-skills"
git init -q "$missing_repo"
if "$INIT_SCRIPT" --repo "$missing_repo" --state-root "$STATE_ROOT" >"$TEST_ROOT/missing.out" 2>&1; then
	fail 'init accepted missing project skills'
fi
rg -F -- '-a universal' "$TEST_ROOT/missing.out" >/dev/null || fail 'init did not explain universal-only installation'
[[ ! -e "$missing_repo/.agents" ]] || fail 'init installed missing skills instead of remaining non-mutating'

printf '%s\n' 'PASS: external registry, non-mutating init, retry linkage, fast launch, exact-session continuation, structured output, and atomic retirement'
