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

process_is_live_non_zombie() {
	local pid="$1"
	local process_state=''
	process_state="$(ps -p "$pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"
	case "$process_state" in
	Z* | '') return 1 ;;
	*) return 0 ;;
	esac
}

process_group_has_live_non_zombie() {
	local pgid="$1"
	ps -ax -o pgid=,stat= 2>/dev/null | awk -v target="$pgid" '$1 == target && $2 !~ /^Z/ {found=1} END {exit(found ? 0 : 1)}'
}

TEST_ROOT="$(mktemp -d)"
readonly TEST_ROOT
cleanup_test_root() {
	local fixture_pid
	local runner_pid
	for runner_pid in "${terminating_runner_pid:-}" "${hard_killed_runner_pid:-}" "${unproven_runner_pid:-}" "${cadence_runner_pid:-}" "${prompt_race_runner_pid:-}"; do
		[[ -n "$runner_pid" ]] || continue
		kill -TERM "$runner_pid" 2>/dev/null || true
		wait "$runner_pid" 2>/dev/null || true
	done
	for fixture_pid in "${bind_owner_pid:-}" "${dead_bind_owner_pid:-}" "${stale_owner_pid:-}" "${claim_owner_a:-}" "${claim_owner_b:-}" "${unproven_lease_writer_pid:-}"; do
		[[ -n "$fixture_pid" ]] || continue
		kill -TERM "$fixture_pid" 2>/dev/null || true
		wait "$fixture_pid" 2>/dev/null || true
	done
	if [[ -n "${hard_killed_child_pgid:-}" ]]; then
		kill -TERM -- "-$hard_killed_child_pgid" 2>/dev/null || true
	fi
	if [[ "${KEEP_TEST_ROOT:-0}" == '1' ]]; then
		printf 'Preserved test root: %s\n' "$TEST_ROOT" >&2
	else
		rm -rf "$TEST_ROOT"
	fi
}
trap cleanup_test_root EXIT

wait_for_blocking_fixture() {
	local runner_pid="$1"
	local child_pid_file="$2"
	local descendant_pid_file="$3"
	local label="$4"
	while process_is_live_non_zombie "$runner_pid" && [[ ! -s "$child_pid_file" || ! -s "$descendant_pid_file" ]]; do
		sleep 0.05
	done
	if [[ ! -s "$child_pid_file" || ! -s "$descendant_pid_file" ]]; then
		kill -TERM "$runner_pid" 2>/dev/null || true
		wait "$runner_pid" 2>/dev/null || true
		fail "$label"
	fi
}
readonly REPO_ROOT="$TEST_ROOT/repo"
readonly STATE_ROOT="$TEST_ROOT/state"
readonly AUTHORITY_ROOT="$TEST_ROOT/authority"
readonly BIN_DIR="$TEST_ROOT/bin"
readonly SLOW_BIN_DIR="$TEST_ROOT/slow-bin"
readonly CODEX_STATE="$TEST_ROOT/codex-home"
readonly PROMPT_FILE="$TEST_ROOT/task.txt"
readonly CONTINUE_FILE="$TEST_ROOT/continue.txt"
readonly CODEX_CALLS="$TEST_ROOT/codex-calls.log"
readonly CODEX_COUNTER="$TEST_ROOT/codex-counter"
readonly CODEX_CHILD_PID_FILE="$TEST_ROOT/codex-child.pid"
readonly CODEX_DESCENDANT_PID_FILE="$TEST_ROOT/codex-descendant.pid"
readonly CODEX_DETACHED_PID_FILE="$TEST_ROOT/codex-detached.pid"
readonly CODEX_DETACHED_OBSERVED_FILE="$TEST_ROOT/codex-detached-observed"
readonly CODEX_FAST_REPARENT_PID_FILE="$TEST_ROOT/codex-fast-reparent.pid"
readonly CODEX_PROMPT_CAPTURE="$TEST_ROOT/codex-prompt-capture"
readonly PROMPT_RACE_MARKER="$TEST_ROOT/prompt-race-handshake"
readonly PROMPT_RACE_RELEASE="$TEST_ROOT/prompt-race-release"
readonly TRACKER_PS_COUNT_FILE="$TEST_ROOT/tracker-ps-count"
readonly TRACKER_HANDSHAKE_COMPLETED_MARKER="$TEST_ROOT/tracker-handshake-completed"
readonly TRACKER_LEASE_WRITER_READY_MARKER="$TEST_ROOT/tracker-lease-writer-ready"
readonly TRACKER_LEASE_RELEASE_MARKER="$TEST_ROOT/tracker-lease-release"
export TRACKER_HANDSHAKE_COMPLETED_MARKER TRACKER_LEASE_WRITER_READY_MARKER TRACKER_LEASE_RELEASE_MARKER

mkdir -p "$REPO_ROOT/.agents/skills/code-reviewer" "$REPO_ROOT/.agents/skills/caveman" "$BIN_DIR" "$SLOW_BIN_DIR" "$CODEX_STATE"
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
printf 'cwd=%s codex_home=%s args=%s\n' "$PWD" "$CODEX_HOME" "$*" >> "$CODEX_CALLS"
if [[ " $* " == *' exec resume '* ]]; then
  if [[ "${FAKE_REQUIRE_WORKSPACE_WRITE_RESUME:-0}" == '1' && " $* " != *'sandbox_mode="workspace-write"'* ]]; then exit 92; fi
  result_path=''
  previous=''
  for argument in "$@"; do
    if [[ "$previous" == '--output-last-message' ]]; then result_path="$argument"; fi
    previous="$argument"
  done
  prompt="$(cat)"
  if [[ -n "${CODEX_PROMPT_CAPTURE:-}" ]]; then
    printf '%s' "$prompt" >"$CODEX_PROMPT_CAPTURE"
  fi
  if [[ "${FAKE_FAST_REPARENT_RESUME:-0}" == '1' ]]; then
    (
      nohup sleep 300 >/dev/null 2>&1 &
      fast_reparent_pid=$!
      printf '%s\n' "$fast_reparent_pid" > "$CODEX_FAST_REPARENT_PID_FILE"
      disown "$fast_reparent_pid"
    ) &
    fast_intermediate_pid=$!
    wait "$fast_intermediate_pid"
  fi
  if [[ "${FAKE_DETACH_RESUME:-0}" == '1' ]]; then
    fixture_process_is_live_non_zombie() {
      local process_state=''
      process_state="$(ps -p "$1" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"
      case "$process_state" in
      Z* | '') return 1 ;;
      *) return 0 ;;
      esac
    }
    set -m
    (
      set -m
      released=0
      trap 'released=1' TERM
      while [[ "$released" -eq 0 ]]; do sleep 0.01; done
      nohup sleep 300 >/dev/null 2>&1 &
      detached_pid=$!
      disown "$detached_pid"
      printf '%s\n' "$detached_pid" > "$CODEX_DETACHED_PID_FILE"
      observed=0
      while [[ "$observed" -eq 0 ]]; do
        for tracker in "$CODEX_DETACHED_TRACKER_DIR"/.descendants-*.json; do
          [[ -f "$tracker" ]] || continue
          if jq -e --argjson pid "$detached_pid" 'any(.processes[]; .pid == $pid)' "$tracker" >/dev/null 2>&1; then
            observed=1
            break
          fi
        done
        [[ "$observed" -eq 0 ]] || break
        fixture_process_is_live_non_zombie "$detached_pid" || exit 91
        sleep 0.01
      done
      [[ "$observed" -eq 0 ]] || printf '%s\n' observed > "$CODEX_DETACHED_OBSERVED_FILE"
    ) &
    detacher_pid=$!
    disown "$detacher_pid"
    observed=0
    while [[ "$observed" -eq 0 ]]; do
      for tracker in "$CODEX_DETACHED_TRACKER_DIR"/.descendants-*.json; do
        [[ -f "$tracker" ]] || continue
        if jq -e --argjson pid "$detacher_pid" 'any(.processes[]; .pid == $pid)' "$tracker" >/dev/null 2>&1; then
          observed=1
          break
        fi
      done
      [[ "$observed" -eq 0 ]] || break
      fixture_process_is_live_non_zombie "$detacher_pid" || exit 90
      sleep 0.01
    done
    set +m
  fi
  if [[ "${FAKE_BLOCK_RESUME:-0}" == '1' ]]; then
    printf '%s\n' "$$" > "$CODEX_CHILD_PID_FILE"
		sleep 300 &
		descendant_pid=$!
		printf '%s\n' "$descendant_pid" > "$CODEX_DESCENDANT_PID_FILE"
    trap 'exit 143' TERM
    trap 'exit 130' INT
		wait "$descendant_pid"
  fi
  if [[ "$prompt" == *'needs parent'* ]]; then
    outcome='needs_parent_action'
    if [[ "${FAKE_INVALID_PARENT_ACTION:-0}" == '1' ]]; then
      parent_action='null'
    else
      parent_action='"run approved validator"'
    fi
  elif [[ "${FAKE_BLOCKED_RESUME:-0}" == '1' ]]; then
    outcome='blocked'
    parent_action='null'
  else
    outcome='completed'
    parent_action='null'
  fi
	validators='[]'
	if [[ "$outcome" == 'completed' ]]; then
		validators='[{"command":"validator","status":"passed","evidence":"passed evidence"}]'
		if [[ "${FAKE_EMPTY_COMPLETED_VALIDATORS:-0}" == '1' ]]; then
			validators='[]'
		elif [[ "${FAKE_BLANK_COMPLETED_COMMAND:-0}" == '1' ]]; then
			validators='[{"command":"","status":"passed","evidence":"passed evidence"}]'
		elif [[ "${FAKE_BLANK_COMPLETED_EVIDENCE:-0}" == '1' ]]; then
			validators='[{"command":"validator","status":"passed","evidence":""}]'
		fi
	fi
  unresolved='[]'
  if [[ "${FAKE_FAILED_COMPLETED:-0}" == '1' ]]; then
    validators='[{"command":"validator","status":"failed","evidence":"failed evidence"}]'
  fi
  if [[ "${FAKE_UNRESOLVED_COMPLETED:-0}" == '1' ]]; then
    unresolved='["remaining work"]'
  fi
  printf '{"outcome":"%s","summary":"worker concise result","changedFiles":[],"validators":%s,"unresolved":%s,"parentAction":%s}\n' "$outcome" "$validators" "$unresolved" "$parent_action" > "$result_path"
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"large stream stays in log"}}'
else
	printf '%s\n' 'irrelevant connector warning' >&2
	if [[ "${FAKE_REQUIRE_CLOSED_PROMPT_FD:-0}" == '1' ]] && (: <&8) 2>/dev/null; then
		exit 92
	fi
	[[ -z "${TRACKER_HANDSHAKE_COMPLETED_MARKER:-}" ]] || : >"$TRACKER_HANDSHAKE_COMPLETED_MARKER"
	if [[ "${FAKE_HANDSHAKE_PROMPT_RACE:-0}" == '1' ]]; then
		: >"$PROMPT_RACE_MARKER"
		while [[ ! -e "$PROMPT_RACE_RELEASE" ]]; do sleep 0.01; done
	fi
	if [[ "${FAKE_REQUIRE_READ_ONLY_HANDSHAKE:-0}" == '1' && " $* " != *' -s read-only '* ]]; then exit 91; fi
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
ln -s "$BIN_DIR/codex" "$SLOW_BIN_DIR/codex"
cat >"$SLOW_BIN_DIR/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${LUNA_TEST_SLOW_PS:-0}" == '1' && "$*" == '-ax -o pid=,ppid=,stat=' && ! -e "$SLOW_PS_MARKER" ]]; then
	: >"$SLOW_PS_MARKER"
	sleep 2
fi
if [[ "${LUNA_TEST_DELAY_REPARENT_PS:-0}" == '1' && "$*" == '-ax -o pid=,ppid=,stat=' ]]; then
	if [[ -e "$FAST_REPARENT_PS_MARKER" ]]; then
		sleep 0.2
	else
		: >"$FAST_REPARENT_PS_MARKER"
	fi
fi
if [[ "$*" == '-ax -o pid=,ppid=,stat=' && -n "${TRACKER_PS_COUNT_FILE:-}" ]]; then
	count=0
	[[ ! -f "$TRACKER_PS_COUNT_FILE" ]] || count="$(cat "$TRACKER_PS_COUNT_FILE")"
	count=$((count + 1))
	printf '%s\n' "$count" >"$TRACKER_PS_COUNT_FILE"
fi
exec "$(command -p -v ps)" "$@"
EOF
chmod +x "$SLOW_BIN_DIR/ps"
export PATH="$BIN_DIR:$PATH"
export CODEX_CALLS
export CODEX_COUNTER
export CODEX_CHILD_PID_FILE
export CODEX_DESCENDANT_PID_FILE
export CODEX_DETACHED_PID_FILE
export CODEX_DETACHED_OBSERVED_FILE
export CODEX_FAST_REPARENT_PID_FILE
export CODEX_PROMPT_CAPTURE
export PROMPT_RACE_MARKER PROMPT_RACE_RELEASE
export TRACKER_PS_COUNT_FILE
export CODEX_HOME="$CODEX_STATE"
export LUNA_AUTHORITY_ROOT="$AUTHORITY_ROOT"

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
default_parent="$TEST_ROOT/default-runtime-parent"
default_repo="$TEST_ROOT/default-repo"
mkdir "$default_parent"
chmod 1777 "$default_parent"
mkdir -p "$default_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$default_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$default_repo/.agents/skills/caveman"
git -C "$default_repo" init -q
default_registry="$(env -u LUNA_REGISTRY_ROOT -u XDG_RUNTIME_DIR TMPDIR="$default_parent" "$INIT_SCRIPT" --repo "$default_repo" --print-path)"
default_state_root="$default_parent/luna-local-review-loop-$UID"
default_state_root="$(cd -P "$default_state_root" && pwd -P)"
[[ "$default_registry" == "$default_state_root/"*/registry.json ]] || fail 'default registry root was not namespaced by user identity'
default_state_mode="$(stat -f '%Lp' "$default_state_root" 2>/dev/null || true)"
if [[ ! "$default_state_mode" =~ ^[0-7]+$ ]]; then
	default_state_mode="$(stat -c '%a' "$default_state_root" 2>/dev/null)"
fi
[[ "$default_state_mode" == 700 ]] || fail "default registry root was not private: mode $default_state_mode"
rm -rf "$default_state_root"
insecure_state_root="$TEST_ROOT/insecure-state"
mkdir "$insecure_state_root"
chmod 0777 "$insecure_state_root"
if "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$insecure_state_root" >"$TEST_ROOT/insecure-state.out" 2>&1; then
	fail 'init trusted a state root with group or other permissions'
fi
rg -F 'state root must not grant group or other permissions' "$TEST_ROOT/insecure-state.out" >/dev/null || fail 'insecure state-root refusal lacked permission evidence'
rm -rf "$insecure_state_root"
overlap_root="$TEST_ROOT/overlapping-authority-state"
if LUNA_AUTHORITY_ROOT="$overlap_root" "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$overlap_root" >"$TEST_ROOT/overlapping-authority-state.out" 2>&1; then
	fail 'init accepted an authority root inside the selectable registry state root'
fi
rg -F 'checkout authority root must be outside the selectable registry state root' "$TEST_ROOT/overlapping-authority-state.out" >/dev/null || fail 'overlapping authority/state refusal lacked separation evidence'
[[ ! -e "$overlap_root" ]] || fail 'overlapping authority/state refusal created unsafe shared state'
registry_path="$($INIT_SCRIPT --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --print-path)"
state_root_real="$(cd "$STATE_ROOT" && pwd -P)"
repo_real="$(cd -P "$REPO_ROOT" && pwd -P)"
[[ "$registry_path" == "$state_root_real/"*/registry.json ]] || fail "registry was not created below the external state root: $registry_path"
alternate_state_root="$TEST_ROOT/alternate-state"
alternate_registry="$($INIT_SCRIPT --existing-path --repo "$REPO_ROOT" --state-root "$alternate_state_root")"
[[ "$alternate_registry" == "$registry_path" ]] || fail 'changed state root selected a duplicate registry for the same checkout'
[[ ! -e "$alternate_state_root" ]] || fail 'authoritative registry lookup created the ignored alternate state root'
[[ ! -e "$REPO_ROOT/.agents/agent-registry" ]] || fail 'init created project-local registry state'
[[ ! -e "$REPO_ROOT/.gitignore" ]] || fail 'init modified repository ignore rules'
[[ "$(git -C "$REPO_ROOT" status --short)" == "$before_status" ]] || fail 'init modified repository files'
jq -e '.schema_version == 3 and (.repository_identity | type == "string" and length > 0) and (.repository_checkout_identity | type == "string" and length > 0) and .workers == [] and .identity_ledger == []' "$registry_path" >/dev/null || fail 'new registry schema is invalid'
jq '.schema_version = 2 | del(.repository_checkout_identity)' "$registry_path" >"$registry_path.tmp"
mv "$registry_path.tmp" "$registry_path"
"$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null
jq -e '.schema_version == 3 and .workers == []' "$registry_path" >/dev/null || fail 'empty schema version 2 registry was not migrated safely'
instance_marker="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)/luna-local-review-loop.instance"
[[ -f "$instance_marker" && ! -L "$instance_marker" ]] || fail 'init did not create a durable Git-directory instance marker'
registry_locator="${instance_marker%/*}/luna-local-review-loop.registry"
locator_checkout_identity="$(jq -r '.repository_checkout_identity' "$registry_locator")"
locator_backup="$TEST_ROOT/registry-locator.before-invalid-root-tests"
cp "$registry_locator" "$locator_backup"
locator_insecure_state="$TEST_ROOT/locator-insecure-state"
locator_insecure_registry_dir="$locator_insecure_state/registry"
mkdir -p "$locator_insecure_registry_dir"
chmod 0777 "$locator_insecure_state"
cp "$registry_path" "$locator_insecure_registry_dir/registry.json"
locator_insecure_registry="$(cd -P "$locator_insecure_registry_dir" && pwd -P)/registry.json"
jq -nc --arg checkout_identity "$locator_checkout_identity" --arg registry_path "$locator_insecure_registry" '{registry_path:$registry_path, registry_state:"ready", repository_checkout_identity:$checkout_identity}' >"$registry_locator.tmp"
mv "$registry_locator.tmp" "$registry_locator"
if "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/locator-insecure-root.out" 2>&1; then
	fail 'init trusted an authoritative locator state root with group or other permissions'
fi
rg -F 'state root must not grant group or other permissions' "$TEST_ROOT/locator-insecure-root.out" >/dev/null || fail 'authoritative locator insecure-root refusal lacked permission evidence'
cp "$locator_backup" "$registry_locator"
rm -rf "$locator_insecure_state"

locator_authority_registry_dir="$TEST_ROOT/locator-registry"
mkdir -p "$locator_authority_registry_dir"
cp "$registry_path" "$locator_authority_registry_dir/registry.json"
locator_authority_registry="$(cd -P "$locator_authority_registry_dir" && pwd -P)/registry.json"
jq -nc --arg checkout_identity "$locator_checkout_identity" --arg registry_path "$locator_authority_registry" '{registry_path:$registry_path, registry_state:"ready", repository_checkout_identity:$checkout_identity}' >"$registry_locator.tmp"
mv "$registry_locator.tmp" "$registry_locator"
if "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/locator-authority-overlap.out" 2>&1; then
	fail 'init allowed authoritative locator state to contain durable checkout authority'
fi
rg -F 'checkout authority root must be outside the selectable registry state root' "$TEST_ROOT/locator-authority-overlap.out" >/dev/null || fail 'authoritative locator authority-separation refusal lacked evidence'
cp "$locator_backup" "$registry_locator"
rm -rf "$locator_authority_registry_dir" "$locator_backup"

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-locator-worker --scope 'refuse missing authoritative locator fallback' >/dev/null
cp "$registry_locator" "$TEST_ROOT/registry-locator.backup"
rm "$registry_locator"
missing_locator_state="$TEST_ROOT/missing-locator-state"
if "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$missing_locator_state" >"$TEST_ROOT/missing-locator.out" 2>&1; then
	fail 'init replaced a missing authoritative locator with a second registry'
fi
rg -e 'instance marker exists but its authoritative registry locator is missing|durable checkout authority retains 1 live worker\(s\)' "$TEST_ROOT/missing-locator.out" >/dev/null || fail 'missing locator refusal lacked recovery evidence'
[[ ! -e "$missing_locator_state" ]] || fail 'missing locator fallback created a second state root'
mv "$TEST_ROOT/registry-locator.backup" "$registry_locator"
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-locator-worker --status interrupted --evidence 'missing locator test complete' >/dev/null
[[ "$(cat "$instance_marker")" =~ ^[0-9a-f]{64}$ ]] || fail 'repository instance marker is malformed'

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-registry-worker --scope 'refuse missing authoritative registry recreation' >/dev/null
cp "$registry_path" "$TEST_ROOT/registry-target.backup"
rm "$registry_path"
if "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/missing-registry.out" 2>&1; then
	fail 'init recreated a missing authoritative registry target'
fi
rg -e 'checkout authority registry target is missing|authoritative registry target is missing behind a ready locator' "$TEST_ROOT/missing-registry.out" >/dev/null || fail 'missing registry target refusal lacked recovery evidence'
[[ ! -e "$registry_path" ]] || fail 'missing registry target refusal recreated empty state'
mv "$TEST_ROOT/registry-target.backup" "$registry_path"
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-registry-worker --status interrupted --evidence 'missing registry target test complete' >/dev/null

pending_repo="$TEST_ROOT/pending-repo"
pending_state="$TEST_ROOT/pending-state"
mkdir -p "$pending_repo/.agents/skills" "$pending_state/pending-registry"
chmod 0700 "$pending_state"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$pending_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$pending_repo/.agents/skills/caveman"
git -C "$pending_repo" init -q
git -C "$pending_repo" config user.email 'test@example.com'
git -C "$pending_repo" config user.name 'Test User'
touch "$pending_repo/.agents/skills/.keep"
git -C "$pending_repo" add .
git -C "$pending_repo" commit -qm init
pending_git_dir="$(git -C "$pending_repo" rev-parse --absolute-git-dir)"
if pending_checkout_identity="$(stat -f '%d:%i' "$pending_git_dir" 2>/dev/null)" && [[ "$pending_checkout_identity" =~ ^[0-9]+:[0-9]+$ ]]; then
	:
elif pending_checkout_identity="$(stat -c '%d:%i' "$pending_git_dir" 2>/dev/null)" && [[ "$pending_checkout_identity" =~ ^[0-9]+:[0-9]+$ ]]; then
	:
else
	fail 'cannot derive pending-locator checkout identity'
fi
pending_registry="$(cd -P "$pending_state/pending-registry" && pwd -P)/registry.json"
jq -nc --arg checkout_identity "$pending_checkout_identity" --arg registry_path "$pending_registry" '{registry_path:$registry_path, registry_state:"pending", repository_checkout_identity:$checkout_identity}' >"$pending_git_dir/luna-local-review-loop.registry"
chmod 0600 "$pending_git_dir/luna-local-review-loop.registry"
resolved_pending_registry="$($INIT_SCRIPT --repo "$pending_repo" --state-root "$pending_state" --print-path)"
[[ "$resolved_pending_registry" == "$pending_registry" && -f "$pending_registry" ]] || fail 'pending locator did not recover its interrupted initial registry creation'
jq -e '.registry_state == "ready"' "$pending_git_dir/luna-local-review-loop.registry" >/dev/null || fail 'recovered pending locator was not promoted to ready'

interrupted_repo="$TEST_ROOT/interrupted-initialization-repo"
interrupted_state="$TEST_ROOT/interrupted-initialization-state"
mkdir -p "$interrupted_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$interrupted_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$interrupted_repo/.agents/skills/caveman"
git -C "$interrupted_repo" init -q
interrupted_git_dir="$(git -C "$interrupted_repo" rev-parse --absolute-git-dir)"
interrupted_marker="$interrupted_git_dir/luna-local-review-loop.instance"
interrupted_locator="$interrupted_git_dir/luna-local-review-loop.registry"
printf '%064d\n' 1 >"$interrupted_marker"
interrupted_marker_contents="$(cat "$interrupted_marker")"
if "$INIT_SCRIPT" --existing-path --repo "$interrupted_repo" --state-root "$interrupted_state" >"$TEST_ROOT/interrupted-existing-only.out" 2>&1; then
	fail 'recovery-only init invented state for a marker-only interrupted initialization'
fi
rg -F 'instance marker exists but its authoritative registry locator is missing' "$TEST_ROOT/interrupted-existing-only.out" >/dev/null || fail 'recovery-only marker-only refusal lacked locator evidence'
[[ ! -e "$interrupted_locator" && ! -e "$interrupted_state" ]] || fail 'recovery-only marker-only init created state'
interrupted_repo_real="$(cd -P "$interrupted_repo" && pwd -P)"
interrupted_authority_key="$(printf '%s\n' "$interrupted_repo_real" | shasum -a 256 | awk '{print $1}')"
interrupted_authority="$AUTHORITY_ROOT/$interrupted_authority_key.json"
interrupted_missing_target="$interrupted_state/damaged/registry.json"
jq -nc --arg root "$interrupted_repo_real" --arg registry_path "$interrupted_missing_target" '{registry_path:$registry_path, repository_root:$root}' >"$interrupted_authority"
chmod 0600 "$interrupted_authority"
if "$INIT_SCRIPT" --repo "$interrupted_repo" --state-root "$interrupted_state" >"$TEST_ROOT/interrupted-damaged-authority.out" 2>&1; then
	fail 'normal init resumed marker-only initialization despite damaged durable authority'
fi
rg -F 'checkout authority registry target is missing' "$TEST_ROOT/interrupted-damaged-authority.out" >/dev/null || fail 'damaged marker-only authority refusal lacked recovery evidence'
[[ ! -e "$interrupted_locator" && ! -e "$interrupted_state" ]] || fail 'damaged marker-only authority refusal created state'
rm "$interrupted_authority"
interrupted_conflict_dir="$interrupted_state/conflicting-registry"
mkdir -p "$interrupted_conflict_dir"
chmod 0700 "$interrupted_state" "$interrupted_conflict_dir"
interrupted_conflict_registry="$interrupted_conflict_dir/registry.json"
jq --arg root "$interrupted_repo_real" '.repository_root = $root | .workers = []' "$registry_path" >"$interrupted_conflict_registry"
if "$INIT_SCRIPT" --repo "$interrupted_repo" --state-root "$interrupted_state" >"$TEST_ROOT/interrupted-conflicting-state.out" 2>&1; then
	fail 'normal init guessed ownership of conflicting marker-only external state'
fi
rg -F 'first-initialization recovery found external registry state without its authoritative Git locator' "$TEST_ROOT/interrupted-conflicting-state.out" >/dev/null || fail 'conflicting marker-only state refusal lacked recovery evidence'
[[ ! -e "$interrupted_locator" ]] || fail 'conflicting marker-only state refusal published a locator'
rm -rf "$interrupted_state"
interrupted_registry="$($INIT_SCRIPT --repo "$interrupted_repo" --state-root "$interrupted_state" --print-path)"
[[ -f "$interrupted_registry" && -f "$interrupted_locator" ]] || fail 'normal init did not resume a safe marker-only first initialization'
jq -e '.registry_state == "ready"' "$interrupted_locator" >/dev/null || fail 'resumed marker-only initialization did not publish a ready locator'
[[ "$(cat "$interrupted_marker")" == "$interrupted_marker_contents" ]] || fail 'marker-only recovery replaced the real instance marker'

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id external-recovery-with-legacy --scope 'recover external state after legacy registry reappears' >/dev/null
registry_checkout_identity="$(jq -r '.repository_checkout_identity' "$registry_path")"
jq '.schema_version = 2 | del(.repository_checkout_identity)' "$registry_path" >"$registry_path.tmp"
mv "$registry_path.tmp" "$registry_path"
if "$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/live-v2-migration.out" 2>&1; then
	fail 'schema migration abandoned a live version 2 worker'
fi
rg -F 'schema version 2 registry contains 1 live worker' "$TEST_ROOT/live-v2-migration.out" >/dev/null || fail 'live version 2 migration refusal lacked recovery evidence'
jq --arg checkout_identity "$registry_checkout_identity" '.schema_version = 3 | .repository_checkout_identity = $checkout_identity' "$registry_path" >"$registry_path.tmp"
mv "$registry_path.tmp" "$registry_path"
mkdir -p "$REPO_ROOT/.agents/agent-registry"
cat >"$REPO_ROOT/.agents/agent-registry/registry.json" <<EOF
{"schema_version":1,"registry":"luna-local-review-loop","workers":[{"task_id":"restored-legacy-live","status":"active"}]}
EOF
"$REGISTRY_SCRIPT" query --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id external-recovery-with-legacy >/dev/null || fail 'reappearing legacy state blocked external registry recovery'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id external-recovery-with-legacy --status interrupted --evidence 'external recovery remained authoritative' >/dev/null
rm -rf "$REPO_ROOT/.agents/agent-registry"

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id option-like-session --scope 'reject option-like session identity' >/dev/null
if "$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id option-like-session --session-id --last >"$TEST_ROOT/option-like-session.out" 2>&1; then
	fail 'registry accepted an option-like Codex session ID'
fi
jq -e 'any(.workers[]; .task_id == "option-like-session" and .status == "reserved" and .session_id == null)' "$registry_path" >/dev/null || fail 'rejected option-like session ID mutated the reservation'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id option-like-session --status interrupted --evidence 'option-like session test complete' >/dev/null

for invalid_task_id in . ..; do
	if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id "$invalid_task_id" --scope "reject artifact path component $invalid_task_id" >"$TEST_ROOT/invalid-task-component-registry.out" 2>&1; then
		fail "registry accepted artifact-unsafe task ID $invalid_task_id"
	fi
	if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id "$invalid_task_id" --scope "reject runner artifact path component $invalid_task_id" --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-task-component-runner.out" 2>&1; then
		fail "runner accepted artifact-unsafe task ID $invalid_task_id"
	fi
done
if jq -e 'any(.identity_ledger[]; .task_id == "." or .task_id == "..")' "$registry_path" >/dev/null; then
	fail 'artifact-unsafe task ID consumed durable registry identity'
fi

schema_repo="$TEST_ROOT/schema-repo"
schema_state="$TEST_ROOT/schema-state"
mkdir -p "$schema_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$schema_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$schema_repo/.agents/skills/caveman"
git -C "$schema_repo" init -q
schema_registry="$($INIT_SCRIPT --repo "$schema_repo" --state-root "$schema_state" --print-path)"
schema_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
"$REGISTRY_SCRIPT" reserve --repo "$schema_repo" --state-root "$schema_state" --task-id valid-task-id --scope 'reject unreachable persisted task identity' >/dev/null
cp "$schema_registry" "$schema_registry.valid-task"
jq '.identity_ledger[0].task_id = "." | .workers[0].task_id = "."' "$schema_registry.valid-task" >"$schema_registry"
if "$INIT_SCRIPT" --existing-path --repo "$schema_repo" --state-root "$schema_state" >"$TEST_ROOT/invalid-task-id.out" 2>&1; then
	fail 'schema accepted a persisted task ID rejected by registry commands'
fi
cp "$schema_registry.valid-task" "$schema_registry"
"$REGISTRY_SCRIPT" complete-and-retire --repo "$schema_repo" --state-root "$schema_state" --task-id valid-task-id --status interrupted --evidence 'persisted task identity test complete' >/dev/null
jq --arg timestamp "$schema_timestamp" '
  .identity_ledger += [{task_id:"orphan-live-row", scope:"damaged registry", sandbox:"workspace-write", retry_of:null, session_id:null, status:"reserved", reserved_at:$timestamp, bound_at:null, activated_at:null, terminal_at:null, retired_at:null, terminal_status:null, terminal_evidence:""}]
' "$schema_registry" >"$schema_registry.tmp"
mv "$schema_registry.tmp" "$schema_registry"
if "$INIT_SCRIPT" --existing-path --repo "$schema_repo" --state-root "$schema_state" >"$TEST_ROOT/orphan-ledger.out" 2>&1; then
	fail 'schema accepted a live identity-ledger row without a worker entry'
fi

duplicate_scope_repo="$TEST_ROOT/duplicate-scope-repo"
duplicate_scope_state="$TEST_ROOT/duplicate-scope-state"
mkdir -p "$duplicate_scope_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$duplicate_scope_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$duplicate_scope_repo/.agents/skills/caveman"
git -C "$duplicate_scope_repo" init -q
duplicate_scope_registry="$($INIT_SCRIPT --repo "$duplicate_scope_repo" --state-root "$duplicate_scope_state" --print-path)"
"$REGISTRY_SCRIPT" reserve --repo "$duplicate_scope_repo" --state-root "$duplicate_scope_state" --task-id scope-owner-a --scope 'duplicate live scope' >/dev/null
jq --arg timestamp "$schema_timestamp" '
  .identity_ledger += [{task_id:"scope-owner-b", scope:"duplicate live scope", sandbox:"workspace-write", retry_of:null, session_id:null, status:"reserved", reserved_at:$timestamp, bound_at:null, activated_at:null, terminal_at:null, retired_at:null, terminal_status:null, terminal_evidence:""}]
  | .workers += [{task_id:"scope-owner-b", scope:"duplicate live scope", sandbox:"workspace-write", retry_of:null, session_id:null, status:"reserved", created_at:$timestamp, updated_at:$timestamp, bound_at:null, activated_at:null, checkpoint_evidence:"", invocation_pid:null, invocation_token:null, invocation_instance:null, active_child_pgid:null, active_child_instance:null}]
' "$duplicate_scope_registry" >"$duplicate_scope_registry.tmp"
mv "$duplicate_scope_registry.tmp" "$duplicate_scope_registry"
if "$INIT_SCRIPT" --existing-path --repo "$duplicate_scope_repo" --state-root "$duplicate_scope_state" >"$TEST_ROOT/duplicate-scope.out" 2>&1; then
	fail 'schema accepted duplicate live worker scopes'
fi

history_scope_repo="$TEST_ROOT/history-scope-repo"
history_scope_state="$TEST_ROOT/history-scope-state"
mkdir -p "$history_scope_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$history_scope_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$history_scope_repo/.agents/skills/caveman"
git -C "$history_scope_repo" init -q
history_scope_registry="$($INIT_SCRIPT --repo "$history_scope_repo" --state-root "$history_scope_state" --print-path)"
"$REGISTRY_SCRIPT" reserve --repo "$history_scope_repo" --state-root "$history_scope_state" --task-id scope-history-a --scope 'unique root scope history' >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$history_scope_repo" --state-root "$history_scope_state" --task-id scope-history-a --status failed --evidence 'prepare persisted scope validation' >/dev/null
cp "$history_scope_registry" "$history_scope_registry.clean"
jq '.identity_ledger += [(.identity_ledger[0] | .task_id = "scope-history-b")]' "$history_scope_registry.clean" >"$history_scope_registry"
if "$INIT_SCRIPT" --existing-path --repo "$history_scope_repo" --state-root "$history_scope_state" >"$TEST_ROOT/duplicate-root-scope.out" 2>&1; then
	fail 'schema accepted duplicate independent root scope histories'
fi
cp "$history_scope_registry.clean" "$history_scope_registry"
jq '.identity_ledger[0].scope = "persisted\nmultiline scope"' "$history_scope_registry.clean" >"$history_scope_registry"
if "$INIT_SCRIPT" --existing-path --repo "$history_scope_repo" --state-root "$history_scope_state" >"$TEST_ROOT/multiline-scope.out" 2>&1; then
	fail 'schema accepted a persisted scope rejected by registry commands'
fi

pid_schema_repo="$TEST_ROOT/pid-schema-repo"
pid_schema_state="$TEST_ROOT/pid-schema-state"
mkdir -p "$pid_schema_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$pid_schema_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$pid_schema_repo/.agents/skills/caveman"
git -C "$pid_schema_repo" init -q
pid_schema_registry="$($INIT_SCRIPT --repo "$pid_schema_repo" --state-root "$pid_schema_state" --print-path)"
"$REGISTRY_SCRIPT" reserve --repo "$pid_schema_repo" --state-root "$pid_schema_state" --task-id malformed-process-id --scope 'reject malformed persisted process identifiers' >/dev/null
cp "$pid_schema_registry" "$pid_schema_registry.clean"
jq '.workers[0].invocation_pid = "not-a-pid" | .workers[0].invocation_token = "owner" | .workers[0].invocation_instance = "ps:Thu Jan 1 00:00:00 1970"' "$pid_schema_registry.clean" >"$pid_schema_registry"
if "$INIT_SCRIPT" --existing-path --repo "$pid_schema_repo" --state-root "$pid_schema_state" >"$TEST_ROOT/malformed-invocation-pid.out" 2>&1; then
	fail 'schema accepted a nonnumeric invocation PID'
fi
cp "$pid_schema_registry.clean" "$pid_schema_registry"
jq '.workers[0].invocation_pid = "123" | .workers[0].invocation_token = "owner" | .workers[0].invocation_instance = null' "$pid_schema_registry.clean" >"$pid_schema_registry"
if "$INIT_SCRIPT" --existing-path --repo "$pid_schema_repo" --state-root "$pid_schema_state" >"$TEST_ROOT/missing-invocation-instance.out" 2>&1; then
	fail 'schema accepted an invocation claim without process-start identity'
fi
cp "$pid_schema_registry.clean" "$pid_schema_registry"
jq '.workers[0].invocation_pid = "123" | .workers[0].invocation_token = "owner" | .workers[0].invocation_instance = "ps:garbage"' "$pid_schema_registry.clean" >"$pid_schema_registry"
if "$INIT_SCRIPT" --existing-path --repo "$pid_schema_repo" --state-root "$pid_schema_state" >"$TEST_ROOT/malformed-invocation-instance.out" 2>&1; then
	fail 'schema accepted a malformed invocation process-start identity'
fi
cp "$pid_schema_registry.clean" "$pid_schema_registry"
jq '.workers[0].invocation_pid = "123" | .workers[0].invocation_token = "invalid token" | .workers[0].invocation_instance = "ps:Thu Jan 1 00:00:00 1970"' "$pid_schema_registry.clean" >"$pid_schema_registry"
if "$INIT_SCRIPT" --existing-path --repo "$pid_schema_repo" --state-root "$pid_schema_state" >"$TEST_ROOT/malformed-invocation-token.out" 2>&1; then
	fail 'schema accepted an invocation token rejected by registry commands'
fi
cp "$pid_schema_registry.clean" "$pid_schema_registry"
jq '.workers[0].invocation_pid = "123" | .workers[0].invocation_token = "owner" | .workers[0].invocation_instance = "ps:Thu Jan 1 00:00:00 1970" | .workers[0].active_child_pgid = "not-a-pgid" | .workers[0].active_child_instance = "ps:Thu Jan 1 00:00:00 1970"' "$pid_schema_registry.clean" >"$pid_schema_registry"
if "$INIT_SCRIPT" --existing-path --repo "$pid_schema_repo" --state-root "$pid_schema_state" >"$TEST_ROOT/malformed-child-pgid.out" 2>&1; then
	fail 'schema accepted a nonnumeric child process-group ID'
fi
cp "$pid_schema_registry.clean" "$pid_schema_registry"
jq '.workers[0].invocation_pid = "123" | .workers[0].invocation_token = "owner" | .workers[0].invocation_instance = "ps:Thu Jan 1 00:00:00 1970" | .workers[0].active_child_pgid = "123" | .workers[0].active_child_instance = null' "$pid_schema_registry.clean" >"$pid_schema_registry"
if "$INIT_SCRIPT" --existing-path --repo "$pid_schema_repo" --state-root "$pid_schema_state" >"$TEST_ROOT/missing-child-instance.out" 2>&1; then
	fail 'schema accepted a child process group without leader process-start identity'
fi
cp "$pid_schema_registry.clean" "$pid_schema_registry"
jq '.workers[0].invocation_pid = "123" | .workers[0].invocation_token = "owner" | .workers[0].invocation_instance = "ps:Thu Jan 1 00:00:00 1970" | .workers[0].active_child_pgid = "123" | .workers[0].active_child_instance = "ps:garbage"' "$pid_schema_registry.clean" >"$pid_schema_registry"
if "$INIT_SCRIPT" --existing-path --repo "$pid_schema_repo" --state-root "$pid_schema_state" >"$TEST_ROOT/malformed-child-instance.out" 2>&1; then
	fail 'schema accepted a malformed child process-group leader identity'
fi
cp "$pid_schema_registry.clean" "$pid_schema_registry"

moved_repo="$TEST_ROOT/moved-repo"
moved_repo_new="$TEST_ROOT/moved-repo-renamed"
moved_state="$TEST_ROOT/moved-state"
mkdir -p "$moved_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$moved_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$moved_repo/.agents/skills/caveman"
git -C "$moved_repo" init -q
moved_registry="$($INIT_SCRIPT --repo "$moved_repo" --state-root "$moved_state" --print-path)"
"$REGISTRY_SCRIPT" reserve --repo "$moved_repo" --state-root "$moved_state" --task-id moved-checkout-worker --scope 'preserve live state across repository move' >/dev/null
moved_marker_contents="$(cat "$moved_repo/.git/luna-local-review-loop.instance")"
mv "$moved_repo" "$moved_repo_new"
rm "$moved_repo_new/.git/luna-local-review-loop.instance"
if "$INIT_SCRIPT" --repo "$moved_repo_new" --state-root "$moved_state" >"$TEST_ROOT/moved-missing-marker.out" 2>&1; then
	fail 'moved checkout with a missing marker abandoned its live external registry'
fi
rg -F 'instance marker is missing while 1 live worker(s) remain for this checkout' "$TEST_ROOT/moved-missing-marker.out" >/dev/null || fail 'moved missing-marker refusal lacked path-independent checkout evidence'
[[ ! -e "$moved_repo_new/.git/luna-local-review-loop.instance" ]] || fail 'moved missing-marker refusal created a replacement marker'
printf '%s\n' "$moved_marker_contents" >"$moved_repo_new/.git/luna-local-review-loop.instance"
moved_registry_after="$($INIT_SCRIPT --existing-path --repo "$moved_repo_new" --state-root "$moved_state")"
[[ "$moved_registry_after" == "$moved_registry" ]] || fail 'repository move selected a new external registry'
moved_repo_new_real="$(cd -P "$moved_repo_new" && pwd -P)"
jq -e --arg root "$moved_repo_new_real" '.repository_root == $root and any(.workers[]; .task_id == "moved-checkout-worker")' "$moved_registry" >/dev/null || fail 'repository move did not preserve live state and update its canonical root'
copied_repo="$TEST_ROOT/copied-repo"
cp -a "$moved_repo_new" "$copied_repo"
copied_registry="$($INIT_SCRIPT --repo "$copied_repo" --state-root "$moved_state" --print-path)"
[[ "$copied_registry" != "$moved_registry" ]] || fail 'copied checkout shared the original checkout registry'
jq -e '.workers == [] and .identity_ledger == []' "$copied_registry" >/dev/null || fail 'copied checkout inherited original live worker state'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$moved_repo_new" --state-root "$moved_state" --task-id moved-checkout-worker --status interrupted --evidence 'repository move test complete' >/dev/null

mkdir -p "$moved_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$moved_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$moved_repo/.agents/skills/caveman"
git -C "$moved_repo" init -q
replacement_repo_real="$(cd -P "$moved_repo" && pwd -P)"
replacement_registry="$($INIT_SCRIPT --repo "$moved_repo" --state-root "$moved_state" --print-path)"
[[ "$replacement_registry" != "$moved_registry" ]] || fail 'replacement repository reused moved checkout registry path'
jq -e '.workers == [] and .identity_ledger == []' "$replacement_registry" >/dev/null || fail 'replacement repository inherited moved checkout lifecycle state'
old_authority_key="$(printf '%s\n' "$replacement_repo_real" | shasum -a 256 | awk '{print $1}')"
jq -e --arg root "$replacement_repo_real" --arg registry "$replacement_registry" '.repository_root == $root and .registry_path == $registry' "$AUTHORITY_ROOT/$old_authority_key.json" >/dev/null || fail 'stale old-path checkout authority was not replaced for the replacement repository'
jq -e --arg root "$moved_repo_new_real" '.repository_root == $root and .workers == []' "$moved_registry" >/dev/null || fail 'moved checkout registry was not preserved while retiring stale old-path authority'

linked_main_repo="$TEST_ROOT/linked-main-repo"
linked_worktree="$TEST_ROOT/linked-worktree"
linked_worktree_copy="$TEST_ROOT/linked-worktree-copy"
linked_state="$TEST_ROOT/linked-state"
mkdir -p "$linked_main_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$linked_main_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$linked_main_repo/.agents/skills/caveman"
git -C "$linked_main_repo" init -q
git -C "$linked_main_repo" config user.email test@example.com
git -C "$linked_main_repo" config user.name Test
git -C "$linked_main_repo" add .agents
git -C "$linked_main_repo" commit -qm init
git -C "$linked_main_repo" worktree add -qb linked-test "$linked_worktree"
linked_registry="$($INIT_SCRIPT --repo "$linked_worktree" --state-root "$linked_state" --print-path)"
"$REGISTRY_SCRIPT" reserve --repo "$linked_worktree" --state-root "$linked_state" --task-id linked-live-worker --scope 'preserve linked worktree ownership' >/dev/null
cp -a "$linked_worktree" "$linked_worktree_copy"
if "$INIT_SCRIPT" --repo "$linked_worktree_copy" --state-root "$linked_state" >"$TEST_ROOT/copied-linked-worktree.out" 2>&1; then
	fail 'init accepted a copied linked-worktree alias'
fi
linked_worktree_real="$(cd -P "$linked_worktree" && pwd -P)"
jq -e --arg root "$linked_worktree_real" '.repository_root == $root and any(.workers[]; .task_id == "linked-live-worker")' "$linked_registry" >/dev/null || fail 'copied linked-worktree alias rewrote or abandoned original live state'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$linked_worktree" --state-root "$linked_state" --task-id linked-live-worker --status interrupted --evidence 'linked-worktree alias test complete' >/dev/null

ordinary_repo="$TEST_ROOT/ordinary-repo"
ordinary_alias="$TEST_ROOT/ordinary-alias"
ordinary_state="$TEST_ROOT/ordinary-state"
mkdir -p "$ordinary_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$ordinary_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$ordinary_repo/.agents/skills/caveman"
git -C "$ordinary_repo" init -q
ordinary_registry="$($INIT_SCRIPT --repo "$ordinary_repo" --state-root "$ordinary_state" --print-path)"
"$REGISTRY_SCRIPT" reserve --repo "$ordinary_repo" --state-root "$ordinary_state" --task-id ordinary-live-worker --scope 'reject ordinary checkout Git-directory aliases' >/dev/null
mkdir -p "$ordinary_alias"
cp -R "$ordinary_repo/.agents" "$ordinary_alias/.agents"
ln -s "$ordinary_repo/.git" "$ordinary_alias/.git"
if "$INIT_SCRIPT" --repo "$ordinary_alias" --state-root "$ordinary_state" >"$TEST_ROOT/ordinary-git-alias.out" 2>&1; then
	fail 'init accepted an ordinary checkout alias to another repository Git directory'
fi
rg -F 'cannot identify the physical Git checkout' "$TEST_ROOT/ordinary-git-alias.out" >/dev/null || fail 'ordinary Git-directory alias refusal lacked checkout evidence'
ordinary_repo_real="$(cd -P "$ordinary_repo" && pwd -P)"
jq -e --arg root "$ordinary_repo_real" '.repository_root == $root and any(.workers[]; .task_id == "ordinary-live-worker")' "$ordinary_registry" >/dev/null || fail 'ordinary Git-directory alias rewrote or abandoned original live state'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$ordinary_repo" --state-root "$ordinary_state" --task-id ordinary-live-worker --status interrupted --evidence 'ordinary Git-directory alias test complete' >/dev/null

metadata_repo="$TEST_ROOT/metadata-replacement-repo"
metadata_state="$TEST_ROOT/metadata-replacement-state"
mkdir -p "$metadata_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$metadata_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$metadata_repo/.agents/skills/caveman"
git -C "$metadata_repo" init -q
metadata_registry="$($INIT_SCRIPT --repo "$metadata_repo" --state-root "$metadata_state" --print-path)"
"$REGISTRY_SCRIPT" reserve --repo "$metadata_repo" --state-root "$metadata_state" --task-id metadata-live-worker --scope 'preserve live ownership across Git metadata replacement' >/dev/null
mv "$metadata_repo/.git" "$metadata_repo/.git-original"
cp -R "$metadata_repo/.git-original" "$metadata_repo/.git"
if "$INIT_SCRIPT" --repo "$metadata_repo" --state-root "$metadata_state" >"$TEST_ROOT/metadata-replacement.out" 2>&1; then
	fail 'init replaced a stale locator while its referenced registry retained live ownership of the same working tree'
fi
rg -F 'Git metadata changed while the registry referenced by its locator still owns live workers' "$TEST_ROOT/metadata-replacement.out" >/dev/null || fail 'Git metadata replacement refusal lacked live-ownership evidence'
metadata_repo_real="$(cd -P "$metadata_repo" && pwd -P)"
jq -e --arg root "$metadata_repo_real" '.repository_root == $root and any(.workers[]; .task_id == "metadata-live-worker")' "$metadata_registry" >/dev/null || fail 'Git metadata replacement rewrote or abandoned original live state'
mv "$metadata_repo/.git" "$metadata_repo/.git-replacement"
mv "$metadata_repo/.git-original" "$metadata_repo/.git"
"$REGISTRY_SCRIPT" complete-and-retire --repo "$metadata_repo" --state-root "$metadata_state" --task-id metadata-live-worker --status interrupted --evidence 'Git metadata replacement test complete' >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$metadata_repo" --state-root "$metadata_state" --task-id metadata-loss-worker --scope 'preserve live ownership when Git authority files disappear' >/dev/null
mv "$metadata_repo/.git" "$metadata_repo/.git-owning"
cp -R "$metadata_repo/.git-owning" "$metadata_repo/.git"
rm "$metadata_repo/.git/luna-local-review-loop.instance" "$metadata_repo/.git/luna-local-review-loop.registry"
metadata_loss_state="$TEST_ROOT/metadata-loss-alternate-state"
if "$INIT_SCRIPT" --repo "$metadata_repo" --state-root "$metadata_loss_state" >"$TEST_ROOT/metadata-loss.out" 2>&1; then
	fail 'init forked live ownership after replacement Git metadata dropped both authority files'
fi
rg -F 'durable checkout authority retains 1 live worker(s)' "$TEST_ROOT/metadata-loss.out" >/dev/null || fail 'metadata-loss refusal lacked durable external authority evidence'
[[ ! -e "$metadata_loss_state" ]] || fail 'metadata-loss refusal created an alternate registry root'
[[ ! -e "$metadata_repo/.git/luna-local-review-loop.instance" && ! -e "$metadata_repo/.git/luna-local-review-loop.registry" ]] || fail 'metadata-loss refusal created replacement Git authority files'
mv "$metadata_repo/.git" "$metadata_repo/.git-without-authority"
mv "$metadata_repo/.git-owning" "$metadata_repo/.git"
"$REGISTRY_SCRIPT" complete-and-retire --repo "$metadata_repo" --state-root "$metadata_state" --task-id metadata-loss-worker --status interrupted --evidence 'Git authority loss test complete' >/dev/null

identity_repo="$TEST_ROOT/identity-repo"
identity_state="$TEST_ROOT/identity-state"
mkdir -p "$identity_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$identity_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$identity_repo/.agents/skills/caveman"
git -C "$identity_repo" init -q
"$INIT_SCRIPT" --repo "$identity_repo" --state-root "$identity_state" >/dev/null
"$REGISTRY_SCRIPT" reserve --repo "$identity_repo" --state-root "$identity_state" --task-id original-checkout-worker --scope 'bind state to original repository instance' >/dev/null
rm -rf "$identity_repo"
mkdir -p "$identity_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$identity_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$identity_repo/.agents/skills/caveman"
git -C "$identity_repo" init -q
if "$INIT_SCRIPT" --existing-path --repo "$identity_repo" --state-root "$identity_state" >"$TEST_ROOT/replaced-repository.out" 2>&1; then
	fail 'init attached live state to a replacement repository at the same path'
fi
rg -e 'instance marker is missing|cannot read or safely create the Git-directory instance marker|durable checkout authority retains 1 live worker\(s\)' "$TEST_ROOT/replaced-repository.out" >/dev/null || fail 'repository replacement refusal lacked identity evidence'

if CODEX_BIN="$TEST_ROOT/missing-codex" "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/missing-codex.out" 2>&1; then
	fail 'normal init accepted a missing Codex CLI'
fi
rg -F 'Codex CLI not found' "$TEST_ROOT/missing-codex.out" >/dev/null || fail 'normal init did not report the missing Codex CLI'
CODEX_BIN="$TEST_ROOT/missing-codex" "$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'recovery-only init unexpectedly required Codex'

dependency_bin="$TEST_ROOT/dependency-bin"
dependency_commands=(bash dirname git jq mkdir rm rmdir mv ln kill ps sleep awk shasum stat cat mktemp date chmod sort head sed od tr mkfifo codex)
for missing_dependency in sort head sed; do
	rm -rf "$dependency_bin"
	mkdir "$dependency_bin"
	for dependency_command in "${dependency_commands[@]}"; do
		[[ "$dependency_command" == "$missing_dependency" ]] && continue
		ln -s "$(command -v "$dependency_command")" "$dependency_bin/$dependency_command"
	done
	if PATH="$dependency_bin" CODEX_BIN=codex "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/missing-$missing_dependency.out" 2>&1; then
		fail "normal init accepted missing runner dependency: $missing_dependency"
	fi
	rg -F "missing runtime prerequisite(s): $missing_dependency" "$TEST_ROOT/missing-$missing_dependency.out" >/dev/null || fail "init did not report missing runner dependency: $missing_dependency"
done
for recovery_optional_dependency in sort head; do
	rm -rf "$dependency_bin"
	mkdir "$dependency_bin"
	for dependency_command in "${dependency_commands[@]}"; do
		[[ "$dependency_command" == "$recovery_optional_dependency" ]] && continue
		ln -s "$(command -v "$dependency_command")" "$dependency_bin/$dependency_command"
	done
	PATH="$dependency_bin" CODEX_BIN=codex "$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" --state-root "$alternate_state_root" >/dev/null || fail "recovery required launch-only dependency: $recovery_optional_dependency"
done
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-sort-continuation --scope 'validate continuation launch dependencies' >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-sort-continuation --session-id 01missing-sort >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-sort-continuation --session-id 01missing-sort >/dev/null
rm -rf "$dependency_bin"
mkdir "$dependency_bin"
for dependency_command in "${dependency_commands[@]}"; do
	[[ "$dependency_command" == sort ]] && continue
	ln -s "$(command -v "$dependency_command")" "$dependency_bin/$dependency_command"
done
if PATH="$dependency_bin" CODEX_BIN=codex "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-sort-continuation --prompt-file "$CONTINUE_FILE" >"$TEST_ROOT/missing-sort-continuation.out" 2>&1; then
	fail 'continuation started without the descendant monitor sort dependency'
fi
rg -F 'missing runtime prerequisite(s): sort' "$TEST_ROOT/missing-sort-continuation.out" >/dev/null || fail 'continuation dependency refusal did not identify sort'
jq -e 'any(.workers[]; .task_id == "missing-sort-continuation" and .status == "active" and .invocation_pid == null)' "$registry_path" >/dev/null || fail 'missing continuation dependency claimed or retired the active task'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-sort-continuation --status interrupted --evidence 'missing dependency validation complete' >/dev/null
rm -rf "$dependency_bin"
mkdir "$dependency_bin"
for dependency_command in "${dependency_commands[@]}"; do
	[[ "$dependency_command" == dirname ]] && continue
	ln -s "$(command -v "$dependency_command")" "$dependency_bin/$dependency_command"
done
if PATH="$dependency_bin" CODEX_BIN=codex "$REGISTRY_SCRIPT" path --repo "$REPO_ROOT" --state-root "$alternate_state_root" >"$TEST_ROOT/missing-dirname.out" 2>&1; then
	fail 'registry recovery accepted a missing dirname prerequisite'
fi
rg -F 'missing runtime prerequisite(s): dirname' "$TEST_ROOT/missing-dirname.out" >/dev/null || fail 'registry recovery did not report its missing dirname prerequisite'

if "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$REPO_ROOT/.runtime/luna" >"$TEST_ROOT/project-state.out" 2>&1; then
	fail 'init accepted a state root inside the repository'
fi
[[ ! -e "$REPO_ROOT/.runtime" ]] || fail 'init mutated the repository before rejecting an in-project state root'

mkdir -p "$REPO_ROOT/.state-link-target/child"
ln -s "$REPO_ROOT/.state-link-target/child" "$TEST_ROOT/state-link"
if "$INIT_SCRIPT" --repo "$REPO_ROOT" --state-root "$TEST_ROOT/state-link/../escaped-state" >"$TEST_ROOT/symlink-dotdot.out" 2>&1; then
	fail 'init accepted a symlink-plus-dotdot state root inside the repository'
fi
[[ ! -e "$REPO_ROOT/.state-link-target/escaped-state" ]] || fail 'state-root validation mutated the repository through a symlink-plus-dotdot path'
rm -f "$TEST_ROOT/state-link"
rm -rf "$REPO_ROOT/.state-link-target"

fingerprint_state="$TEST_ROOT/fingerprint-state"
fingerprint_repo="$TEST_ROOT/fingerprint-repo"
fingerprint_target="$fingerprint_repo/.fingerprint-target"
mkdir -p "$fingerprint_repo/.agents/skills"
cp -R "$REPO_ROOT/.agents/skills/code-reviewer" "$fingerprint_repo/.agents/skills/code-reviewer"
cp -R "$REPO_ROOT/.agents/skills/caveman" "$fingerprint_repo/.agents/skills/caveman"
git -C "$fingerprint_repo" init -q
fingerprint_repo_real="$(cd -P "$fingerprint_repo" && pwd -P)"
repo_fingerprint="$(printf '%s' "$fingerprint_repo_real" | shasum -a 256 | awk '{print $1}')"
mkdir -p "$fingerprint_state" "$fingerprint_target"
ln -s "$fingerprint_target" "$fingerprint_state/$repo_fingerprint"
if "$INIT_SCRIPT" --repo "$fingerprint_repo" --state-root "$fingerprint_state" >"$TEST_ROOT/fingerprint-symlink.out" 2>&1; then
	fail 'init accepted a symlinked repository fingerprint directory'
fi
[[ ! -e "$fingerprint_target/registry.json" && ! -e "$fingerprint_target/.lock" ]] || fail 'init wrote registry state through a symlinked fingerprint directory'
rm -f "$fingerprint_state/$repo_fingerprint"
rm -rf "$fingerprint_target"

registry_dir="$(dirname "$registry_path")"
lock_symlink_target="$REPO_ROOT/.lock-symlink-target"
mkdir "$lock_symlink_target"
printf '%s\n' 'do not mutate' >"$lock_symlink_target/sentinel"
ln -s "$lock_symlink_target" "$registry_dir/.lock"
if "$REGISTRY_SCRIPT" active --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/lock-symlink.out" 2>&1; then
	fail 'registry accepted a symlinked mutation lock'
fi
[[ "$(cat "$lock_symlink_target/sentinel")" == 'do not mutate' ]] || fail 'symlinked mutation-lock target was modified'
rm -f "$registry_dir/.lock"
rm -rf "$lock_symlink_target"

: >"$registry_dir/.lock"
"$REGISTRY_SCRIPT" active --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'registry could not reclaim an ownerless atomic lock file'
[[ ! -e "$registry_dir/.lock" ]] || fail 'ownerless atomic lock remained after recovery'

printf '%s|%s\n' "$$" 'ps:Thu Jan 1 00:00:00 1970' >"$registry_dir/.lock"
"$REGISTRY_SCRIPT" active --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'registry could not reclaim a lock after PID reuse'
[[ ! -e "$registry_dir/.lock" ]] || fail 'PID-reused stale lock remained after recovery'

sleep 0.01 &
stale_lock_pid=$!
wait "$stale_lock_pid"
printf '%s\n' "$stale_lock_pid" >"$registry_dir/.lock"
lock_status_a=0
lock_status_b=0
"$REGISTRY_SCRIPT" active --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/lock-a.out" 2>&1 &
lock_command_a=$!
"$REGISTRY_SCRIPT" active --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/lock-b.out" 2>&1 &
lock_command_b=$!
wait "$lock_command_a" || lock_status_a=$?
wait "$lock_command_b" || lock_status_b=$?
[[ "$lock_status_a" -eq 0 && "$lock_status_b" -eq 0 ]] || fail 'registry commands could not serialize stale-lock reclamation'
jq -e '.schema_version == 3' "$registry_path" >/dev/null || fail 'stale-lock contention corrupted the registry'
[[ ! -e "$registry_dir/.lock" ]] || fail 'registry lock remained after stale-lock contention'

artifact_target="$REPO_ROOT/.artifact-target"
mkdir -p "$artifact_target"
ln -s "$artifact_target" "$registry_dir/artifacts"
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id symlinked-artifact-root --scope 'reject symlinked artifact root' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/artifact-root.out" 2>&1; then
	fail 'runner accepted a symlinked artifact root'
fi
[[ -z "$(ls -A "$artifact_target")" ]] || fail 'runner wrote through a symlinked artifact root'
rm -f "$registry_dir/artifacts"
rm -rf "$artifact_target"
mkdir "$registry_dir/artifacts"
chmod 0700 "$registry_dir/artifacts"

task_artifact_target="$REPO_ROOT/.task-artifact-target"
mkdir -p "$task_artifact_target"
ln -s "$task_artifact_target" "$registry_dir/artifacts/symlinked-task-artifact"
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id symlinked-task-artifact --scope 'reject symlinked task artifact directory' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/task-artifact.out" 2>&1; then
	fail 'runner accepted a symlinked task artifact directory'
fi
[[ -z "$(ls -A "$task_artifact_target")" ]] || fail 'runner wrote through a symlinked task artifact directory'
rm -f "$registry_dir/artifacts/symlinked-task-artifact"
rm -rf "$task_artifact_target"

artifact_file_target="$REPO_ROOT/.artifact-file-target"
printf '%s\n' 'preserve artifact target' >"$artifact_file_target"
mkdir "$registry_dir/artifacts/symlinked-artifact-file"
ln -s "$artifact_file_target" "$registry_dir/artifacts/symlinked-artifact-file/launch.jsonl"
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id symlinked-artifact-file --scope 'reject symlinked artifact file' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/artifact-file.out" 2>&1; then
	fail 'runner accepted a symlinked handshake artifact file'
fi
[[ "$(cat "$artifact_file_target")" == 'preserve artifact target' ]] || fail 'runner wrote through a symlinked handshake artifact file'

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id symlinked-continuation-file --scope 'reject symlinked continuation artifact file' >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id symlinked-continuation-file --session-id 01symlinked-continuation >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id symlinked-continuation-file --session-id 01symlinked-continuation >/dev/null
mkdir "$registry_dir/artifacts/symlinked-continuation-file"
ln -s "$artifact_file_target" "$registry_dir/artifacts/symlinked-continuation-file/stream-1.jsonl"
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id symlinked-continuation-file --prompt-file "$CONTINUE_FILE" >"$TEST_ROOT/continuation-artifact-file.out" 2>&1; then
	fail 'runner accepted a symlinked continuation artifact file'
fi
[[ "$(cat "$artifact_file_target")" == 'preserve artifact target' ]] || fail 'runner wrote through a symlinked continuation artifact file'
rm -f "$artifact_file_target"

hardlink_artifact_target="$REPO_ROOT/.hardlink-artifact-target"
printf '%s\n' 'preserve hard-linked artifact target' >"$hardlink_artifact_target"
mkdir "$registry_dir/artifacts/hardlinked-artifact-file"
ln "$hardlink_artifact_target" "$registry_dir/artifacts/hardlinked-artifact-file/launch.jsonl"
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id hardlinked-artifact-file --scope 'reject hard-linked artifact file' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/hardlink-artifact-file.out" 2>&1; then
	fail 'runner accepted a hard-linked handshake artifact file'
fi
[[ "$(cat "$hardlink_artifact_target")" == 'preserve hard-linked artifact target' ]] || fail 'runner wrote through a hard-linked handshake artifact file'

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id hardlinked-continuation-file --scope 'reject hard-linked continuation artifact file' >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id hardlinked-continuation-file --session-id 01hardlinked-continuation >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id hardlinked-continuation-file --session-id 01hardlinked-continuation >/dev/null
mkdir "$registry_dir/artifacts/hardlinked-continuation-file"
ln "$hardlink_artifact_target" "$registry_dir/artifacts/hardlinked-continuation-file/stream-1.jsonl"
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id hardlinked-continuation-file --prompt-file "$CONTINUE_FILE" >"$TEST_ROOT/hardlink-continuation-file.out" 2>&1; then
	fail 'runner accepted a hard-linked continuation artifact file'
fi
[[ "$(cat "$hardlink_artifact_target")" == 'preserve hard-linked artifact target' ]] || fail 'runner wrote through a hard-linked continuation artifact file'
rm -f "$hardlink_artifact_target"

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id sparse-continuation-artifacts --scope 'preserve sparse continuation artifacts' >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id sparse-continuation-artifacts --session-id 01sparse-continuation >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id sparse-continuation-artifacts --session-id 01sparse-continuation >/dev/null
mkdir "$registry_dir/artifacts/sparse-continuation-artifacts"
printf '%s\n' 'preserve stream one' >"$registry_dir/artifacts/sparse-continuation-artifacts/stream-1.jsonl"
printf '%s\n' 'preserve stream three' >"$registry_dir/artifacts/sparse-continuation-artifacts/stream-3.jsonl"
sparse_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id sparse-continuation-artifacts --prompt-file "$CONTINUE_FILE" 2>"$TEST_ROOT/sparse-continuation.err")"
jq -e '.outcome == "completed"' <<<"$sparse_output" >/dev/null || fail 'sparse continuation did not complete'
[[ "$(cat "$registry_dir/artifacts/sparse-continuation-artifacts/stream-3.jsonl")" == 'preserve stream three' ]] || fail 'sparse continuation overwrote the highest existing attempt'
[[ -f "$registry_dir/artifacts/sparse-continuation-artifacts/stream-4.jsonl" && -f "$registry_dir/artifacts/sparse-continuation-artifacts/result-4.json" ]] || fail 'sparse continuation did not select max attempt plus one'

mkdir "$registry_dir/artifacts/reserved-continuation"
chmod 0700 "$registry_dir/artifacts/reserved-continuation"
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id reserved-continuation --scope 'reject continuation before activation' >/dev/null
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id reserved-continuation --prompt-file "$CONTINUE_FILE" >"$TEST_ROOT/reserved-continuation.out" 2>&1; then
	fail 'continue accepted a reserved task'
fi
jq -e 'any(.workers[]; .task_id == "reserved-continuation" and .status == "reserved" and .invocation_pid == null and .invocation_token == null)' "$registry_path" >/dev/null || fail 'rejected continuation mutated or retired its reservation'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id reserved-continuation --status interrupted --evidence 'continuation predicate test complete' >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-launch --scope 'exact retry scope' --sandbox read-only >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-launch --status failed --evidence 'pre-bind launch failed' >/dev/null
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-retry --scope 'exact retry scope' >/dev/null 2>&1; then
	fail 'duplicate scope was accepted without retry-of'
fi
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id privilege-escalating-retry --scope 'exact retry scope' --retry-of failed-launch --sandbox workspace-write >/dev/null 2>&1; then
	fail 'retry changed the original sandbox'
fi
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id retry-launch --scope 'exact retry scope' --retry-of failed-launch >/dev/null
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id duplicate-retry --scope 'exact retry scope' --retry-of failed-launch >/dev/null 2>&1; then
	fail 'one failed attempt accepted multiple retry children'
fi
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id retry-launch --status interrupted --evidence 'retry test complete' >/dev/null
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id duplicate-retired-retry --scope 'exact retry scope' --retry-of failed-launch >/dev/null 2>&1; then
	fail 'retired failed attempt accepted a second retry child'
fi
jq -e 'any(.identity_ledger[]; .task_id == "retry-launch" and .retry_of == "failed-launch" and .scope == "exact retry scope" and .sandbox == "read-only")' "$registry_path" >/dev/null || fail 'retry linkage or inherited sandbox was not recorded'
cp "$registry_path" "$registry_path.valid-retry-chain"
jq '(.identity_ledger[] | select(.task_id == "failed-launch") | .terminal_status) = "completed"' "$registry_path.valid-retry-chain" >"$registry_path"
if "$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/completed-retry-parent.out" 2>&1; then
	fail 'schema accepted a retry whose parent did not fail or get interrupted'
fi
jq '(.identity_ledger[] | select(.task_id == "failed-launch") | .retry_of) = "retry-launch"' "$registry_path.valid-retry-chain" >"$registry_path"
if "$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >"$TEST_ROOT/cyclic-retry-chain.out" 2>&1; then
	fail 'schema accepted a cyclic or later-parent retry chain'
fi
mv "$registry_path.valid-retry-chain" "$registry_path"

zombie_pid_file="$TEST_ROOT/zombie.pid"
bash -c '(exit 0) & printf "%s\n" "$!" >"$1"; sleep 30' _ "$zombie_pid_file" &
zombie_parent_pid=$!
poll_attempt=0
while [[ ! -s "$zombie_pid_file" && "$poll_attempt" -lt 100 ]]; do
	sleep 0.01
	poll_attempt=$((poll_attempt + 1))
done
[[ -s "$zombie_pid_file" ]] || fail 'zombie fixture did not publish its child PID'
zombie_pid="$(cat "$zombie_pid_file")"
poll_attempt=0
while [[ "$(ps -p "$zombie_pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')" != Z* && "$poll_attempt" -lt 100 ]]; do
	sleep 0.01
	poll_attempt=$((poll_attempt + 1))
done
if [[ "$(ps -p "$zombie_pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')" == Z* ]]; then
	"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id zombie-recovery --scope 'reclaim a defunct invocation owner' >/dev/null
	"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id zombie-recovery --session-id 01zombie-recovery-session >/dev/null
	"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id zombie-recovery --session-id 01zombie-recovery-session >/dev/null
	"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id zombie-recovery --pid "$zombie_pid" --token zombie-owner >/dev/null
	"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id zombie-recovery --pid "$$" --token zombie-reclaimer >/dev/null
	"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id zombie-recovery --status interrupted --evidence 'defunct owner reclaimed' --invocation-token zombie-reclaimer >/dev/null
else
	printf '%s\n' 'SKIP: shell reaped zombie fixture before observation' >&2
fi
kill "$zombie_parent_pid" 2>/dev/null || true
wait "$zombie_parent_pid" 2>/dev/null || true

sleep 30 &
bind_owner_pid=$!
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-bind --scope 'require live invocation authority for bind and activate' --pid "$bind_owner_pid" --token bind-owner >/dev/null
if "$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-bind --session-id 01owned-bind-session >/dev/null 2>&1; then
	fail 'tokenless bind mutated a task owned by a live invocation'
fi
if "$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-bind --session-id 01owned-bind-session --invocation-token wrong-owner >/dev/null 2>&1; then
	fail 'mismatched invocation token bound an owned task'
fi
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-bind --session-id 01owned-bind-session --invocation-token bind-owner >/dev/null
if "$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-bind --session-id 01owned-bind-session >/dev/null 2>&1; then
	fail 'tokenless activation mutated a task owned by a live invocation'
fi
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-bind --session-id 01owned-bind-session --invocation-token bind-owner >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-bind --status interrupted --evidence 'bind ownership test complete' --invocation-token bind-owner >/dev/null
kill "$bind_owner_pid" 2>/dev/null || true
wait "$bind_owner_pid" 2>/dev/null || true
bind_owner_pid=''

sleep 30 &
dead_bind_owner_pid=$!
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id recovered-bind --scope 'allow tokenless bind after invocation owner exits' --pid "$dead_bind_owner_pid" --token dead-bind-owner >/dev/null
kill "$dead_bind_owner_pid" 2>/dev/null || true
wait "$dead_bind_owner_pid" 2>/dev/null || true
dead_bind_owner_pid=''
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id recovered-bind --session-id 01recovered-bind-session >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id recovered-bind --session-id 01recovered-bind-session >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id recovered-bind --status interrupted --evidence 'dead owner recovery complete' >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-reservation --scope 'atomic initial reservation ownership' --pid "$$" --token initial-owner >/dev/null
if "$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-reservation --status interrupted --evidence 'tokenless live-owner retirement' >/dev/null 2>&1; then
	fail 'tokenless recovery retired a task owned by a live invocation'
fi
if "$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-reservation --status failed --evidence 'wrong owner' --invocation-token wrong-owner >/dev/null 2>&1; then
	fail 'a mismatched invocation token retired an owned reservation'
fi
jq -e 'any(.workers[]; .task_id == "owned-reservation" and .invocation_token == "initial-owner")' "$registry_path" >/dev/null || fail 'owned reservation was not retained after mismatched cleanup'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id owned-reservation --status interrupted --evidence 'ownership test complete' --invocation-token initial-owner >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id unowned-completed-retirement --scope 'reject unowned completed retirement' >/dev/null
if "$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id unowned-completed-retirement --status completed --evidence 'missing structured result' >/dev/null 2>&1; then
	fail 'unowned reserved task bypassed the completed structured-result contract'
fi
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id unowned-completed-retirement --status interrupted --evidence 'completed retirement contract test complete' >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-finish-status --scope 'reject completed explicit finish' >/dev/null
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-finish-status --status completed --evidence 'must use structured result' >"$TEST_ROOT/invalid-finish.out" 2>&1; then
	fail 'explicit finish accepted completed status'
fi
jq -e 'any(.workers[]; .task_id == "invalid-finish-status" and .status == "reserved" and .invocation_token == null)' "$registry_path" >/dev/null || fail 'invalid finish status mutated the live reservation'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-finish-status --status interrupted --evidence 'invalid finish test complete' >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-artifact-finish --scope 'recover without worker artifacts' >/dev/null
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing-artifact-finish --status interrupted --evidence 'artifacts were unavailable' >"$TEST_ROOT/missing-artifact-finish.out"
jq -e 'any(.identity_ledger[]; .task_id == "missing-artifact-finish" and .status == "retired" and .terminal_status == "interrupted")' "$registry_path" >/dev/null || fail 'registry-only finish could not retire a task without artifacts'

readonly INVALID_CODEX_STATE="$TEST_ROOT/codex-home-file"
printf '%s\n' 'not a directory' >"$INVALID_CODEX_STATE"
if CODEX_HOME="$INVALID_CODEX_STATE" CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id denied-runtime --scope 'runtime permission probe' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/denied-runtime.out" 2>&1; then
	fail 'runner accepted an invalid Codex runtime state path'
fi
jq -e 'all(.identity_ledger[]; .task_id != "denied-runtime")' "$registry_path" >/dev/null || fail 'runtime permission failure burned a task reservation'

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id rejected-launch-staging --scope 'reject launch after prompt staging' >/dev/null
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id rejected-launch-staging --scope 'reject launch after prompt staging' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/rejected-launch-staging.out" 2>&1; then
	fail 'reservation-conflict launch unexpectedly succeeded'
fi
for staged_prompt_path in "$registry_dir"/artifacts/.prompt-*; do
	[[ -e "$staged_prompt_path" || -L "$staged_prompt_path" ]] || continue
	fail 'rejected launch left a staged prompt copy'
done
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id rejected-launch-staging --status interrupted --evidence 'rejected launch staging cleanup test complete' >/dev/null

if FAKE_FAIL_HANDSHAKE=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-runner --scope 'runner retry scope' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/failed-runner.out" 2>&1; then
	fail 'failed handshake unexpectedly succeeded'
fi
jq -e 'any(.identity_ledger[]; .task_id == "failed-runner" and .session_id == null and .status == "retired" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'failed pre-bind launch was not atomically retired'
retry_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id failed-runner-retry --scope 'runner retry scope' --retry-of failed-runner --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/retry.err")"
jq -e '.outcome == "completed"' <<<"$retry_output" >/dev/null || fail 'runner retry did not complete'

printf '%s\n' 'blocked worker' >"$PROMPT_FILE"
blocked_output="$(FAKE_BLOCKED_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id blocked-runner --scope 'blocked runner retry scope' --sandbox read-only --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/blocked-runner.err")"
jq -e '.outcome == "blocked"' <<<"$blocked_output" >/dev/null || fail 'runner did not return a blocked result'
jq -e 'any(.identity_ledger[]; .task_id == "blocked-runner" and .status == "retired" and .terminal_status == "blocked")' "$registry_path" >/dev/null || fail 'blocked runner result was not retired as blocked'
blocked_retry_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id blocked-runner-retry --scope 'blocked runner retry scope' --retry-of blocked-runner --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/blocked-retry.err")"
jq -e '.outcome == "completed"' <<<"$blocked_retry_output" >/dev/null || fail 'retired blocked task did not resume through exact-scope retry'
jq -e 'any(.identity_ledger[]; .task_id == "blocked-runner-retry" and .retry_of == "blocked-runner" and .sandbox == "read-only" and .terminal_status == "completed")' "$registry_path" >/dev/null || fail 'blocked retry did not preserve linkage and sandbox'
"$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'init validation rejected a valid blocked retry chain'

if FAKE_FAIL_HANDSHAKE=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id read-only-failed-runner --scope 'read-only runner retry scope' --sandbox read-only --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/read-only-failed.out" 2>&1; then
	fail 'read-only failed handshake unexpectedly succeeded'
fi
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id read-only-escalating-retry --scope 'read-only runner retry scope' --retry-of read-only-failed-runner --sandbox workspace-write --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/read-only-escalating.out" 2>&1; then
	fail 'runner retry escalated read-only task to workspace-write'
fi
read_only_retry_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id read-only-runner-retry --scope 'read-only runner retry scope' --retry-of read-only-failed-runner --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/read-only-retry.err")"
jq -e '.outcome == "completed"' <<<"$read_only_retry_output" >/dev/null || fail 'read-only runner retry did not complete'
jq -e 'any(.identity_ledger[]; .task_id == "read-only-runner-retry" and .sandbox == "read-only" and .terminal_status == "completed")' "$registry_path" >/dev/null || fail 'runner retry did not preserve read-only sandbox'

printf '%s\n' 'workspace-write task after read-only handshake' >"$PROMPT_FILE"
handshake_sandbox_output="$(FAKE_REQUIRE_READ_ONLY_HANDSHAKE=1 FAKE_REQUIRE_WORKSPACE_WRITE_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id handshake-sandbox-contract --scope 'read-only handshake before workspace-write resume' --sandbox workspace-write --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/handshake-sandbox.err")"
jq -e '.outcome == "completed"' <<<"$handshake_sandbox_output" >/dev/null || fail 'workspace-write task did not use read-only handshake and registered resume sandbox'
jq -e 'any(.identity_ledger[]; .task_id == "handshake-sandbox-contract" and .sandbox == "workspace-write" and .terminal_status == "completed")' "$registry_path" >/dev/null || fail 'workspace-write task did not retain its registered resume sandbox'

prompt_race_original='immutable task prompt before handshake'
printf '%s\n' "$prompt_race_original" >"$PROMPT_FILE"
rm -f "$PROMPT_RACE_MARKER" "$PROMPT_RACE_RELEASE" "$CODEX_PROMPT_CAPTURE"
prompt_race_status=0
FAKE_HANDSHAKE_PROMPT_RACE=1 FAKE_REQUIRE_CLOSED_PROMPT_FD=1 FAKE_REQUIRE_WORKSPACE_WRITE_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id prompt-race-worker --scope 'open immutable prompt before workspace-write resume' --sandbox workspace-write --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/prompt-race.out" 2>"$TEST_ROOT/prompt-race.err" &
prompt_race_runner_pid=$!
poll_attempt=0
while [[ ! -e "$PROMPT_RACE_MARKER" && "$poll_attempt" -lt 200 ]]; do
	sleep 0.01
	poll_attempt=$((poll_attempt + 1))
done
[[ -e "$PROMPT_RACE_MARKER" ]] || fail 'prompt race handshake did not reach its controlled pause'
prompt_snapshot_path="$registry_dir/artifacts/prompt-race-worker/.task-prompt"
[[ -f "$prompt_snapshot_path" && ! -L "$prompt_snapshot_path" ]] || fail 'launch did not create a private prompt snapshot before handshake'
[[ "$(cat "$prompt_snapshot_path")" == "$prompt_race_original" ]] || fail 'prompt snapshot did not preserve validated prompt contents before handshake'
jq -e 'any(.workers[]; .task_id == "prompt-race-worker" and .status == "reserved")' "$registry_path" >/dev/null || fail 'prompt race did not prove snapshot creation preceded registry reservation'
printf '%s\n' 'caller replacement during handshake' >"$PROMPT_FILE"
printf '%s\n' 'task artifact replacement during handshake' >"$TEST_ROOT/prompt-race-replacement"
mv "$TEST_ROOT/prompt-race-replacement" "$prompt_snapshot_path"
: >"$PROMPT_RACE_RELEASE"
prompt_race_status=0
wait "$prompt_race_runner_pid" || prompt_race_status=$?
prompt_race_runner_pid=''
[[ "$prompt_race_status" -eq 0 ]] || fail 'prompt snapshot race worker did not complete'
jq -e '.outcome == "completed"' <"$TEST_ROOT/prompt-race.out" >/dev/null || fail 'prompt snapshot race worker returned invalid result'
[[ "$(cat "$CODEX_PROMPT_CAPTURE")" == "$prompt_race_original" ]] || fail 'first workspace-write resume consumed a task-artifact replacement during handshake'
snapshot_link_count="$(stat -c '%h' "$prompt_snapshot_path" 2>/dev/null || stat -f '%l' "$prompt_snapshot_path" 2>/dev/null)"
[[ "$snapshot_link_count" == '1' ]] || fail 'prompt snapshot did not retain single-link ownership'

relative_codex_output="$(cd "$TEST_ROOT" && PATH="bin:$PATH" CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id relative-codex-worker --scope 'canonicalize relative codex path' --prompt-file task.txt 2>"$TEST_ROOT/relative-codex.err")"
jq -e '.outcome == "completed"' <<<"$relative_codex_output" >/dev/null || fail 'runner did not canonicalize a Codex executable found through a relative PATH entry'

relative_codex_home="$TEST_ROOT/relative-codex-home"
mkdir "$relative_codex_home"
relative_codex_home_output="$(cd "$TEST_ROOT" && PATH="bin:$PATH" CODEX_HOME='relative-codex-home' CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id relative-codex-home-worker --scope 'preserve relative Codex home across repository-directory changes' --prompt-file task.txt 2>"$TEST_ROOT/relative-codex-home.err")"
jq -e '.outcome == "completed"' <<<"$relative_codex_home_output" >/dev/null || fail 'runner did not complete with a relative CODEX_HOME'
relative_codex_home_real="$(cd -P "$relative_codex_home" && pwd -P)"
rg -F "codex_home=$relative_codex_home_real" "$CODEX_CALLS" >/dev/null || fail 'runner did not preserve relative CODEX_HOME as an absolute physical path after changing to --repo'

slow_ps_marker="$TEST_ROOT/slow-ps.ready"
slow_tracker_output="$(PATH="$SLOW_BIN_DIR:$PATH" LUNA_TEST_SLOW_PS=1 SLOW_PS_MARKER="$slow_ps_marker" CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id slow-tracker-worker --scope 'wait for slow tracker readiness' --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/slow-tracker.err")"
jq -e '.outcome == "completed"' <<<"$slow_tracker_output" >/dev/null || fail 'runner imposed a fixed deadline on tracker readiness'
[[ -e "$slow_ps_marker" ]] || fail 'slow tracker fixture did not delay its initial process snapshot'

rm -f "$TRACKER_PS_COUNT_FILE" "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE"
printf '%s\n' 'stable tracker cadence' >"$PROMPT_FILE"
FAKE_BLOCK_RESUME=1 PATH="$SLOW_BIN_DIR:$PATH" CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id adaptive-tracker-worker --scope 'use adaptive ancestry tracker cadence' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/adaptive-tracker.out" 2>"$TEST_ROOT/adaptive-tracker.err" &
cadence_runner_pid=$!
wait_for_blocking_fixture "$cadence_runner_pid" "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE" 'adaptive tracker Codex process group did not start'
sleep 1
cadence_snapshot_count="$(cat "$TRACKER_PS_COUNT_FILE")"
[[ "$cadence_snapshot_count" -lt 40 ]] || fail "adaptive tracker kept 10 ms full-table churn: $cadence_snapshot_count snapshots in one second"
kill -TERM "$cadence_runner_pid"
cadence_status=0
wait "$cadence_runner_pid" || cadence_status=$?
cadence_runner_pid=''
[[ "$cadence_status" -ne 0 ]] || fail 'adaptive tracker termination unexpectedly succeeded'
jq -e 'any(.identity_ledger[]; .task_id == "adaptive-tracker-worker" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'adaptive tracker termination did not preserve failed lifecycle evidence'

runner_output="$(cd "$TEST_ROOT" && CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id fast-worker --scope 'one fast task' --prompt-file task.txt 2>"$TEST_ROOT/runner.err")"
jq -e '.outcome == "completed" and .summary == "worker concise result" and (.validators | length == 1) and .validators[0].status == "passed"' <<<"$runner_output" >/dev/null || fail 'runner did not return concise structured output with valid completion evidence'
"$REGISTRY_SCRIPT" assert-no-active --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'completed worker was not atomically retired'
jq -e 'any(.identity_ledger[]; .task_id == "fast-worker" and (.session_id | startswith("01fake-session-")) and .status == "retired" and .terminal_status == "completed")' "$registry_path" >/dev/null || fail 'fast worker identity/result was not retained'

printf '%s\n' 'needs parent' >"$PROMPT_FILE"
needs_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --scope 'one continued task' --sandbox read-only --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/needs.err")"
jq -e '.outcome == "needs_parent_action"' <<<"$needs_output" >/dev/null || fail 'parent-action result was not returned'
jq -e 'any(.workers[]; .task_id == "continued-worker" and .status == "active" and .sandbox == "read-only" and (.session_id | startswith("01fake-session-")))' "$registry_path" >/dev/null || fail 'parent-action worker was not retained as an active read-only session'

jq --arg pid "$$" '
  .workers |= map(if .task_id == "continued-worker"
    then .invocation_pid = $pid | .invocation_token = "reused-pid-stale-owner" | .invocation_instance = "ps:Thu Jan 1 00:00:00 1970"
    else .
    end)
' "$registry_path" >"$registry_path.tmp"
mv "$registry_path.tmp" "$registry_path"
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --pid "$$" --token reused-pid-current-owner >/dev/null
jq -e 'any(.workers[]; .task_id == "continued-worker" and .invocation_pid == $pid and .invocation_token == "reused-pid-current-owner" and (.invocation_instance | type == "string" and length > 0 and . != "ps:Thu Jan 1 00:00:00 1970"))' --arg pid "$$" "$registry_path" >/dev/null || fail 'PID reuse simulation did not replace stale invocation process identity'
"$REGISTRY_SCRIPT" release-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --token reused-pid-current-owner >/dev/null

sleep 30 &
stale_owner_pid=$!
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --pid "$stale_owner_pid" --token stale-owner >/dev/null
kill "$stale_owner_pid" 2>/dev/null || true
wait "$stale_owner_pid" 2>/dev/null || true
stale_owner_pid=''
jq --arg pgid "$$" '
  .workers |= map(if .task_id == "continued-worker"
    then .active_child_pgid = $pgid | .active_child_instance = "ps:Thu Jan 1 00:00:00 1970"
    else .
    end)
' "$registry_path" >"$registry_path.tmp"
mv "$registry_path.tmp" "$registry_path"
stale_tracker="$registry_dir/artifacts/continued-worker/.descendants-stale-owner.json"
if "$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --pid "$$" --token missing-tracker-reclaimer >"$TEST_ROOT/missing-stale-tracker.out" 2>&1; then
	fail 'stale invocation reclaim accepted a recorded child after its tracker artifact disappeared'
fi
printf '%s\n' '{"status":"active","root_pid":99999999,"processes":[]}' >"$stale_tracker"
if "$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --pid "$$" --token premature-reclaimer >"$TEST_ROOT/active-stale-tracker.out" 2>&1; then
	fail 'stale invocation reclaim ignored an active tracker from the previous token'
fi
printf '%s\n' '{"status":"clean","root_pid":99999999,"processes":[{"pid":99999999,"instance":"ps:recorded-process"}]}' >"$stale_tracker"
if "$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --pid "$$" --token dirty-clean-reclaimer >"$TEST_ROOT/dirty-clean-tracker.out" 2>&1; then
	fail 'stale invocation reclaim accepted a clean tracker that retained process identities'
fi
printf '%s\n' '{"status":"clean","root_pid":99999999,"processes":[]}' >"$stale_tracker"
if "$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --pid "$$" --token mismatched-root-reclaimer >"$TEST_ROOT/mismatched-root-tracker.out" 2>&1; then
	fail 'stale invocation reclaim accepted cleanup evidence for a different process-tree root'
fi
printf '%s\n' "{\"status\":\"clean\",\"root_pid\":$$,\"processes\":[]}" >"$stale_tracker"
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
jq -e --arg token "$winning_claim_token" 'any(.workers[]; .task_id == "continued-worker" and .invocation_token == $token and .active_child_pgid == null and .active_child_instance == null)' "$registry_path" >/dev/null || fail 'atomic stale claim winner was not recorded or stale child process-group identity was retained'
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
claim_owner_a=''
claim_owner_b=''
continue_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id continued-worker --prompt-file "$CONTINUE_FILE" 2>"$TEST_ROOT/continue.err")"
jq -e '.outcome == "completed"' <<<"$continue_output" >/dev/null || fail 'exact-session continuation did not complete'
"$REGISTRY_SCRIPT" assert-empty --repo "$REPO_ROOT" --state-root "$STATE_ROOT" >/dev/null || fail 'continued worker was not retired'

printf '%s\n' 'needs parent' >"$PROMPT_FILE"
if FAKE_INVALID_PARENT_ACTION=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-parent-action --scope 'invalid parent action contract' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-parent.out" 2>&1; then
	fail 'runner accepted needs_parent_action with a null parentAction'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-parent-action" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'invalid structured result was not retired as failed'

printf '%s\n' 'complete only with valid evidence' >"$PROMPT_FILE"
if FAKE_FAILED_COMPLETED=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-completed-validator --scope 'reject completed result with failed validation' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-validator.out" 2>&1; then
	fail 'runner retired a completed result with failed validation'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-validator" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'failed completed-validator result was not left retryable as failed'
if FAKE_UNRESOLVED_COMPLETED=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-completed-unresolved --scope 'reject completed result with unresolved work' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-unresolved.out" 2>&1; then
	fail 'runner retired a completed result with unresolved work'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-unresolved" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'unresolved completed result was not left retryable as failed'
if FAKE_EMPTY_COMPLETED_VALIDATORS=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-completed-empty-validators --scope 'reject completed result without validators' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-empty-validators.out" 2>&1; then
	fail 'runner retired a completed result without validators'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-empty-validators" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'empty completed validators were not left retryable as failed'
if FAKE_BLANK_COMPLETED_COMMAND=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-completed-blank-command --scope 'reject completed result with blank validator command' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-blank-command.out" 2>&1; then
	fail 'runner retired a completed result with a blank validator command'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-blank-command" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'blank completed validator command was not left retryable as failed'
if FAKE_BLANK_COMPLETED_EVIDENCE=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id invalid-completed-blank-evidence --scope 'reject completed result with blank validator evidence' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-blank-evidence.out" 2>&1; then
	fail 'runner retired a completed result with blank validator evidence'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-blank-evidence" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'blank completed validator evidence was not left retryable as failed'

if "$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id missing --session-id nope --handle process-123 >/dev/null 2>&1; then
	fail 'ambiguous process handle argument was accepted'
fi
if rg -- '--ephemeral' "$CODEX_CALLS" >/dev/null; then fail 'runner used --ephemeral'; fi
if rg -- '-maxdepth' "$RUNNER_SCRIPT" >/dev/null; then fail 'runner used GNU-only find arguments'; fi
resume_count="$(rg -c 'exec resume .* -- (01fake-session-[0-9]+|01sparse-continuation) -' "$CODEX_CALLS")"
[[ "$resume_count" -eq 20 ]] || fail "expected twenty exact-session resumes, got $resume_count"
ignore_count="$(rg -c -- '--ignore-user-config' "$CODEX_CALLS")"
[[ "$ignore_count" -eq 40 ]] || fail "expected unrelated user MCP config disabled on every Codex call, got $ignore_count"
read_only_count="$(rg -c -- '-s read-only' "$CODEX_CALLS")"
[[ "$read_only_count" -eq 20 ]] || fail "expected every handshake to use read-only sandbox, got $read_only_count"
resume_sandbox_count="$(rg -c -- 'exec resume .*sandbox_mode=' "$CODEX_CALLS")"
[[ "$resume_sandbox_count" -eq 20 ]] || fail "expected every resume to reapply its registered sandbox, got $resume_sandbox_count"
read_only_resume_count="$(rg -c -- 'exec resume .*sandbox_mode="read-only"' "$CODEX_CALLS")"
[[ "$read_only_resume_count" -eq 5 ]] || fail "expected read-only sandbox on retry, blocked retry, and both continued-session resumes, got $read_only_resume_count"
if ! awk -v expected="cwd=$repo_real " '/exec resume/ && index($0, expected) != 1 {bad=1} END {exit bad ? 1 : 0}' "$CODEX_CALLS"; then
	fail 'a resumed Codex session ran outside the canonical target repository'
fi
if rg -F 'irrelevant connector warning' "$(dirname "$registry_path")/artifacts/fast-worker/launch.jsonl" >/dev/null; then
	fail 'handshake stderr corrupted the JSONL event stream'
fi
rg -F 'irrelevant connector warning' "$(dirname "$registry_path")/artifacts/fast-worker/launch.stderr.log" >/dev/null || fail 'handshake stderr was not preserved separately'
[[ "$(git -C "$REPO_ROOT" status --short)" == "$before_status" ]] || fail 'worker lifecycle modified repository tooling state'

printf '%s\n' 'drain detached descendant' >"$PROMPT_FILE"
rm -f "$CODEX_DETACHED_PID_FILE" "$CODEX_DETACHED_OBSERVED_FILE"
detached_tracker_dir="$(dirname "$registry_path")/artifacts/detached-worker"
detached_status=0
detached_output="$(FAKE_DETACH_RESUME=1 CODEX_DETACHED_TRACKER_DIR="$detached_tracker_dir" CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id detached-worker --scope 'drain detached worker descendant' --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/detached.err")" || detached_status=$?
[[ -s "$CODEX_DETACHED_PID_FILE" ]] || fail 'detached descendant fixture did not publish its PID'
[[ -s "$CODEX_DETACHED_OBSERVED_FILE" ]] || fail 'detached descendant fixture exited before tracker observation'
detached_pid="$(cat "$CODEX_DETACHED_PID_FILE")"
detached_trackers=("$(dirname "$registry_path")/artifacts/detached-worker/".descendants-*.json)
[[ "${#detached_trackers[@]}" -eq 1 && -f "${detached_trackers[0]}" ]] || fail 'detached worker descendant tracker was not unique'
jq -e '.processes | type == "array" and all(.[]; (.pid | type == "number") and (.instance | type == "string" and length > 0))' "${detached_trackers[0]}" >/dev/null || fail 'descendant tracker did not pin process instances'
if jq -e 'any(.processes[]; .instance | startswith("ps:"))' "${detached_trackers[0]}" >/dev/null; then
	[[ "$detached_status" -ne 0 ]] || fail 'non-procfs cleanup destructively signaled a descendant using only second-resolution process identity'
	process_is_live_non_zombie "$detached_pid" || fail 'non-procfs safe refusal did not preserve the unprovable detached descendant'
	kill -TERM "$detached_pid" 2>/dev/null || true
	poll_attempt=0
	while process_is_live_non_zombie "$detached_pid" && [[ "$poll_attempt" -lt 100 ]]; do
		sleep 0.05
		poll_attempt=$((poll_attempt + 1))
	done
	process_is_live_non_zombie "$detached_pid" && fail 'detached descendant fixture did not stop after explicit test cleanup'
	poll_attempt=0
	while [[ "$(jq -r '.status // empty' "${detached_trackers[0]}" 2>/dev/null)" != clean ]] && [[ "$poll_attempt" -lt 100 ]]; do
		sleep 0.05
		poll_attempt=$((poll_attempt + 1))
	done
	jq -e '.status == "clean" and (.processes | length) == 0' "${detached_trackers[0]}" >/dev/null || fail 'detached tracker did not publish clean evidence after explicit test cleanup'
	CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id detached-worker --status interrupted --evidence 'non-procfs descendant required explicit cleanup' >"$TEST_ROOT/detached-finish.out"
else
	[[ "$detached_status" -eq 0 ]] || fail 'worker with safely identifiable detached descendant did not complete'
	jq -e '.outcome == "completed"' <<<"$detached_output" >/dev/null || fail 'worker with detached descendant did not return its structured result'
	if process_is_live_non_zombie "$detached_pid"; then
		fail 'detached worker descendant survived registry retirement'
	fi
fi

printf '%s\n' 'drain fast-reparented descendant' >"$PROMPT_FILE"
rm -f "$CODEX_FAST_REPARENT_PID_FILE"
fast_reparent_ps_marker="$TEST_ROOT/fast-reparent-ps.ready"
fast_reparent_status=0
fast_reparent_output="$(PATH="$SLOW_BIN_DIR:$PATH" LUNA_TEST_DELAY_REPARENT_PS=1 FAST_REPARENT_PS_MARKER="$fast_reparent_ps_marker" FAKE_FAST_REPARENT_RESUME=1 CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id fast-reparent-worker --scope 'drain a fast-reparented worker descendant' --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/fast-reparent.err")" || fast_reparent_status=$?
[[ -s "$CODEX_FAST_REPARENT_PID_FILE" ]] || fail 'fast-reparent fixture did not publish its descendant PID'
fast_reparent_pid="$(cat "$CODEX_FAST_REPARENT_PID_FILE")"
[[ -e "$fast_reparent_ps_marker" ]] || fail 'fast-reparent fixture did not delay the post-launch ancestry snapshot'
if [[ "$fast_reparent_status" -eq 0 ]]; then
	jq -e '.outcome == "completed"' <<<"$fast_reparent_output" >/dev/null || fail 'worker with a safely identifiable fast-reparented descendant returned an invalid result'
	process_is_live_non_zombie "$fast_reparent_pid" && fail 'fast-reparented descendant escaped cleanup and registry retirement'
else
	process_is_live_non_zombie "$fast_reparent_pid" || fail 'safe cleanup refusal lost its live fast-reparent evidence'
	jq -e 'any(.workers[]; .task_id == "fast-reparent-worker" and .status == "active")' "$registry_path" >/dev/null || fail 'safe cleanup refusal retired the worker while its fast-reparented descendant remained live'
	kill -TERM "$fast_reparent_pid" 2>/dev/null || true
	poll_attempt=0
	while process_is_live_non_zombie "$fast_reparent_pid" && [[ "$poll_attempt" -lt 100 ]]; do
		sleep 0.05
		poll_attempt=$((poll_attempt + 1))
	done
	process_is_live_non_zombie "$fast_reparent_pid" && fail 'fast-reparented descendant did not stop after explicit cleanup'
	fast_reparent_trackers=("$(dirname "$registry_path")/artifacts/fast-reparent-worker/".descendants-*.json)
	[[ "${#fast_reparent_trackers[@]}" -eq 1 && -f "${fast_reparent_trackers[0]}" ]] || fail 'fast-reparent tracker was not unique'
	fast_reparent_tracker="${fast_reparent_trackers[0]}"
	poll_attempt=0
	while [[ "$(jq -r '.status // empty' "$fast_reparent_tracker" 2>/dev/null)" != clean ]] && [[ "$poll_attempt" -lt 100 ]]; do
		sleep 0.05
		poll_attempt=$((poll_attempt + 1))
	done
	jq -e '.status == "clean" and (.processes | length) == 0' "$fast_reparent_tracker" >/dev/null || fail 'fast-reparent tracker did not publish clean evidence after explicit cleanup'
	CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id fast-reparent-worker --status interrupted --evidence 'non-procfs fast-reparented descendant required explicit cleanup' >"$TEST_ROOT/fast-reparent-finish.out"
fi

printf '%s\n' 'preserve lease when descendant cleanup is unproven' >"$PROMPT_FILE"
rm -f "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE" "$TRACKER_HANDSHAKE_COMPLETED_MARKER" "$TRACKER_LEASE_WRITER_READY_MARKER" "$TRACKER_LEASE_RELEASE_MARKER"
unproven_artifact_dir="$registry_dir/artifacts/unproven-signal-worker"
unproven_lease_writer_pid=''
(
	writer_fd_opened=0
	while [[ "$writer_fd_opened" -eq 0 ]]; do
		if [[ ! -e "$TRACKER_HANDSHAKE_COMPLETED_MARKER" ]]; then
			sleep 0.01
			continue
		fi
		for lease_path in "$unproven_artifact_dir"/.lease-*; do
			[[ -p "$lease_path" ]] || continue
			if exec 8>"$lease_path"; then
				writer_fd_opened=1
				break
			fi
		done
		[[ "$writer_fd_opened" -eq 1 ]] || sleep 0.01
	done
	: >"$TRACKER_LEASE_WRITER_READY_MARKER"
	while [[ ! -e "$TRACKER_LEASE_RELEASE_MARKER" ]]; do sleep 0.01; done
) &
unproven_lease_writer_pid=$!
FAKE_BLOCK_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id unproven-signal-worker --scope 'preserve active state when lease cleanup is unproven' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/unproven-signal.out" 2>"$TEST_ROOT/unproven-signal.err" &
unproven_runner_pid=$!
wait_for_blocking_fixture "$unproven_runner_pid" "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE" 'unproven-cleanup Codex process group did not start'
poll_attempt=0
while [[ ! -e "$TRACKER_LEASE_WRITER_READY_MARKER" ]] && process_is_live_non_zombie "$unproven_runner_pid" && [[ "$poll_attempt" -lt 200 ]]; do
	sleep 0.05
	poll_attempt=$((poll_attempt + 1))
done
[[ -e "$TRACKER_LEASE_WRITER_READY_MARKER" ]] || fail 'unproven-cleanup lease writer did not retain lease evidence'
kill -HUP "$unproven_runner_pid"
unproven_status=0
wait "$unproven_runner_pid" || unproven_status=$?
unproven_runner_pid=''
[[ "$unproven_status" -ne 0 ]] || fail 'runner with unproven descendant cleanup exited successfully'
jq -e 'any(.workers[]; .task_id == "unproven-signal-worker" and .status == "active" and .invocation_pid != null and .active_child_pgid != null)' "$registry_path" >/dev/null || fail 'unproven descendant cleanup retired or cleared recoverable registry state'
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id unproven-signal-worker --status interrupted --evidence 'lease evidence still requires explicit cleanup' >"$TEST_ROOT/unproven-signal-finish.out" 2>&1; then
	fail 'recovery retired a task while its lifecycle lease remained live'
fi
: >"$TRACKER_LEASE_RELEASE_MARKER"
poll_attempt=0
while process_is_live_non_zombie "$unproven_lease_writer_pid" && [[ "$poll_attempt" -lt 100 ]]; do
	sleep 0.05
	poll_attempt=$((poll_attempt + 1))
done
kill -TERM "$unproven_lease_writer_pid" 2>/dev/null || true
wait "$unproven_lease_writer_pid" 2>/dev/null || true
unproven_lease_writer_pid=''
unproven_tracker="$unproven_artifact_dir/.descendants-$(jq -r '.workers[] | select(.task_id == "unproven-signal-worker") | .invocation_token' "$registry_path").json"
poll_attempt=0
while [[ ! -f "$unproven_tracker" || "$(jq -r '.status // empty' "$unproven_tracker" 2>/dev/null)" != clean ]] && [[ "$poll_attempt" -lt 200 ]]; do
	sleep 0.05
	poll_attempt=$((poll_attempt + 1))
done
jq -e '.status == "clean" and (.processes | length) == 0' "$unproven_tracker" >/dev/null || fail 'unproven-cleanup tracker did not publish clean evidence after explicit lease cleanup'
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id unproven-signal-worker --status interrupted --evidence 'lease evidence explicitly cleaned' >"$TEST_ROOT/unproven-signal-finish-clean.out"

printf '%s\n' 'terminate child safely' >"$PROMPT_FILE"
rm -f "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE"
FAKE_BLOCK_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id terminated-worker --scope 'terminate child before retirement' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/terminated.out" 2>"$TEST_ROOT/terminated.err" &
terminating_runner_pid=$!
wait_for_blocking_fixture "$terminating_runner_pid" "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE" 'blocking Codex process group did not start'
codex_child_pid="$(cat "$CODEX_CHILD_PID_FILE")"
codex_descendant_pid="$(cat "$CODEX_DESCENDANT_PID_FILE")"
codex_child_pgid="$(ps -p "$codex_child_pid" -o pgid= 2>/dev/null | awk 'NF {print $1; exit}')"
[[ "$codex_child_pgid" == "$codex_child_pid" ]] || fail 'Codex child was not isolated as a process-group leader'
kill -TERM "$terminating_runner_pid"
terminated_status=0
wait "$terminating_runner_pid" || terminated_status=$?
terminating_runner_pid=''
[[ "$terminated_status" -ne 0 ]] || fail 'terminated runner exited successfully'
poll_attempt=0
while process_is_live_non_zombie "$codex_child_pid" && [[ "$poll_attempt" -lt 100 ]]; do
	sleep 0.05
	poll_attempt=$((poll_attempt + 1))
done
if process_is_live_non_zombie "$codex_child_pid"; then
	fail 'Codex child survived runner termination and registry retirement'
fi
if process_is_live_non_zombie "$codex_descendant_pid" || process_group_has_live_non_zombie "$codex_child_pgid"; then
	fail 'Codex descendant process group survived runner termination and registry retirement'
fi
jq -e 'any(.identity_ledger[]; .task_id == "terminated-worker" and .status == "retired" and .terminal_status == "failed") and all(.workers[]; .task_id != "terminated-worker")' "$registry_path" >/dev/null || fail 'terminated runner retired registry state before child cleanup completed'

printf '%s\n' 'retain hard-killed child identity' >"$PROMPT_FILE"
rm -f "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE"
FAKE_BLOCK_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id hard-killed-worker --scope 'retain hard-killed child identity' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/hard-killed.out" 2>"$TEST_ROOT/hard-killed.err" &
hard_killed_runner_pid=$!
wait_for_blocking_fixture "$hard_killed_runner_pid" "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE" 'hard-kill Codex process group did not start'
hard_killed_child_pid="$(cat "$CODEX_CHILD_PID_FILE")"
hard_killed_descendant_pid="$(cat "$CODEX_DESCENDANT_PID_FILE")"
hard_killed_child_pgid="$(ps -p "$hard_killed_child_pid" -o pgid= 2>/dev/null | awk 'NF {print $1; exit}')"
[[ "$hard_killed_child_pgid" == "$hard_killed_child_pid" ]] || fail 'hard-kill Codex child was not its process-group leader'
hard_killed_owner_pid="$hard_killed_runner_pid"
kill -KILL "$hard_killed_runner_pid"
wait "$hard_killed_runner_pid" 2>/dev/null || true
hard_killed_runner_pid=''
process_group_has_live_non_zombie "$hard_killed_child_pgid" || fail 'hard-killed runner did not leave a live Codex process group for recovery test'
jq -e --arg runner_pid "$hard_killed_owner_pid" --arg child_pgid "$hard_killed_child_pgid" 'any(.workers[]; .task_id == "hard-killed-worker" and .status == "active" and .invocation_pid == $runner_pid and .active_child_pgid == $child_pgid and (.active_child_instance | type == "string" and length > 0))' "$registry_path" >/dev/null || fail 'registry lost durable process-group identity after hard kill'
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id hard-killed-worker --status interrupted --evidence 'must not retire live child' >"$TEST_ROOT/live-child-finish.out" 2>&1; then
	fail 'recovery retired a task while its hard-kill-surviving process group was live'
fi
jq -e 'any(.workers[]; .task_id == "hard-killed-worker" and .active_child_pgid != null)' "$registry_path" >/dev/null || fail 'rejected recovery removed hard-kill process-group evidence'
kill -TERM -- "-$hard_killed_child_pgid"
poll_attempt=0
while process_group_has_live_non_zombie "$hard_killed_child_pgid" && [[ "$poll_attempt" -lt 100 ]]; do
	sleep 0.05
	poll_attempt=$((poll_attempt + 1))
done
if process_group_has_live_non_zombie "$hard_killed_child_pgid" || process_is_live_non_zombie "$hard_killed_descendant_pid"; then
	fail 'hard-kill recovery process group did not stop'
fi
hard_killed_tracker="$registry_dir/artifacts/hard-killed-worker/.descendants-$(jq -r '.workers[] | select(.task_id == "hard-killed-worker") | .invocation_token' "$registry_path").json"
poll_attempt=0
while [[ ! -f "$hard_killed_tracker" || "$(jq -r '.status // empty' "$hard_killed_tracker" 2>/dev/null)" != 'clean' ]] && [[ "$poll_attempt" -lt 100 ]]; do
	sleep 0.05
	poll_attempt=$((poll_attempt + 1))
done
[[ -f "$hard_killed_tracker" ]] || fail 'hard-kill recovery tracker did not publish cleanup evidence'
mv "$hard_killed_tracker" "$hard_killed_tracker.saved"
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id hard-killed-worker --status interrupted --evidence 'missing tracker must block retirement' >"$TEST_ROOT/missing-tracker-finish.out" 2>&1; then
	fail 'recovery retired a recorded child after its tracker artifact disappeared'
fi
mv "$hard_killed_tracker.saved" "$hard_killed_tracker"
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --state-root "$STATE_ROOT" --task-id hard-killed-worker --status interrupted --evidence 'child stopped and identity verified' >"$TEST_ROOT/hard-kill-finish.out"
jq -e 'any(.identity_ledger[]; .task_id == "hard-killed-worker" and .status == "retired" and .terminal_status == "interrupted") and all(.workers[]; .task_id != "hard-killed-worker")' "$registry_path" >/dev/null || fail 'hard-kill recovery did not retire after child exit'
hard_killed_child_pgid=''

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
