#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly INIT_SCRIPT="$SCRIPT_DIR/init.sh"
readonly REGISTRY_SCRIPT="$SCRIPT_DIR/registry.sh"
readonly RUNNER_SCRIPT="$SCRIPT_DIR/run-worker.sh"
readonly CLAIM_SCRIPT="$SCRIPT_DIR/cross-path-claim.sh"
readonly WORKER_BOUNDARY_INSTRUCTION='You are the sole worker for this immutable task. Perform the owned scope directly; never spawn, delegate to, or hand work to another subagent.'

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

file_mode() {
	local path="$1"
	if stat -c '%a' "$path" 2>/dev/null; then
		return 0
	fi
	stat -f '%Lp' "$path"
}

file_sha256() {
	local path="$1"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$path" | awk '{print $1}'
		return 0
	fi
	sha256sum "$path" | awk '{print $1}'
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
	for fixture_pid in "${bind_owner_pid:-}" "${dead_bind_owner_pid:-}" "${stale_owner_pid:-}" "${claim_owner_a:-}" "${claim_owner_b:-}" "${unproven_lease_writer_pid:-}" "${legacy_race_owner_pid:-}" "${finish_race_owner_pid:-}"; do
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
readonly PROMPT_RACE_MARKER_WAIT_ATTEMPTS=1000
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
if [[ "$#" -eq 1 && "$1" == '--version' ]]; then
  printf '%s\n' "${FAKE_CODEX_VERSION:-codex-cli 0.147.0}"
  exit 0
fi
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

make_test_repo() {
	local root="$1"
	mkdir -p "$root/.agents/skills/code-reviewer" "$root/.agents/skills/caveman"
	cp -R "$REPO_ROOT/.agents/skills/code-reviewer/." "$root/.agents/skills/code-reviewer/"
	cp -R "$REPO_ROOT/.agents/skills/caveman/." "$root/.agents/skills/caveman/"
	git -C "$root" init -q
	git -C "$root" config user.email test@example.com
	git -C "$root" config user.name Test
	git -C "$root" add .agents
	git -C "$root" commit -qm init
}

expect_init_failure() {
	local repo="$1"
	local output="$2"
	if "$INIT_SCRIPT" --existing-path --repo "$repo" >"$output" 2>&1; then
		fail "init unexpectedly accepted $repo"
	fi
}

expect_normal_init_failure() {
	local repo="$1"
	local output="$2"
	if "$INIT_SCRIPT" --repo "$repo" >"$output" 2>&1; then
		fail "normal init unexpectedly accepted $repo"
	fi
}

repo_real="$(cd -P "$REPO_ROOT" && pwd -P)"
registry_path="$repo_real/.agents/agent-registry/registry.json"
registry_dir="$repo_real/.agents/agent-registry"

printf '%s\n' 'keep-one' '.agents/agent-registry/' 'keep-two' '.agents/agent-registry/' >"$REPO_ROOT/.gitignore"
chmod 0640 "$REPO_ROOT/.gitignore"
registry_output="$("$INIT_SCRIPT" --repo "$REPO_ROOT" --print-path)"
[[ "$registry_output" == "$registry_path" ]] || fail "registry path was not exact project-local path: $registry_output"
[[ "$(file_mode "$registry_dir")" == 700 ]] || fail 'registry directory is not mode 0700'
[[ "$(file_mode "$registry_path")" == 600 ]] || fail 'registry file is not mode 0600'
[[ "$(file_mode "$REPO_ROOT/.gitignore")" == 640 ]] || fail '.gitignore mode changed'
[[ "$(rg -c '^\.agents/agent-registry/$' "$REPO_ROOT/.gitignore")" == 1 ]] || fail '.gitignore does not contain exactly one registry line'
[[ "$(sed -n '1,3p' "$REPO_ROOT/.gitignore")" == $'keep-one\nkeep-two\n.agents/agent-registry/' ]] || fail '.gitignore changed unrelated lines'
private_ignore="$registry_dir/.gitignore"
[[ "$(file_mode "$private_ignore")" == 600 ]] || fail 'registry-local .gitignore is not private'
[[ "$(sed -n '$p' "$private_ignore")" == '*' ]] || fail 'registry-local .gitignore does not end with *'
for ignored_path in \
  '.agents/agent-registry/registry.json' \
  '.agents/agent-registry/.lock' \
  '.agents/agent-registry/.lock-owner.candidate' \
  '.agents/agent-registry/artifacts/example/nested/result.json'; do
  git -C "$REPO_ROOT" check-ignore --no-index -q -- "$ignored_path" || fail "registry representative is not ignored: $ignored_path"
done
git_admin_dir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"
seal_path="$git_admin_dir/.luna-checkout-identity"
[[ -f "$seal_path" && ! -L "$seal_path" ]] || fail 'checkout identity seal is missing'
[[ "$(file_mode "$seal_path")" == 600 ]] || fail 'checkout identity seal is not private'
[[ "$(stat -c '%h' "$seal_path" 2>/dev/null || stat -f '%l' "$seal_path")" == 1 ]] || fail 'checkout identity seal is multiply linked'
[[ "$(cat "$seal_path")" =~ ^[0-9a-f]{64}$ ]] || fail 'checkout identity seal is not 256-bit lowercase hex'
[[ "$(jq -r '.repository_checkout_identity' "$registry_path")" =~ ^gitdir:[0-9]+:[0-9]+:seal:[0-9a-f]{64}:seal-file:[0-9]+:[0-9]+$ ]] || fail 'registry did not combine physical and seal identity evidence'
second_registry="$("$INIT_SCRIPT" --repo "$REPO_ROOT" --print-path)"
[[ "$second_registry" == "$registry_path" ]] || fail 'init was not idempotent'
[[ "$(rg -c '^\.agents/agent-registry/$' "$REPO_ROOT/.gitignore")" == 1 ]] || fail 'idempotent init duplicated .gitignore line'
identity_before="$(jq -r '.repository_identity' "$registry_path")"
checkout_identity_before="$(jq -r '.repository_checkout_identity' "$registry_path")"
before_status="$(git -C "$REPO_ROOT" status --short)"
[[ "$identity_before" != *'/'* && "$checkout_identity_before" != *'/'* ]] || fail 'identity unexpectedly depends on repository path'
lookup_only_repo="$TEST_ROOT/lookup-only-repo"
make_test_repo "$lookup_only_repo"
if "$INIT_SCRIPT" --existing-path --repo "$lookup_only_repo" >"$TEST_ROOT/lookup-only.out" 2>&1; then
	fail 'existing-path lookup initialized an absent project-local registry'
fi
[[ ! -e "$lookup_only_repo/.agents/agent-registry" ]] || fail 'existing-path lookup created a registry directory'
[[ ! -e "$lookup_only_repo/.gitignore" ]] || fail 'existing-path lookup changed project metadata'

legacy_live_repo="$TEST_ROOT/legacy-live-repo"
make_test_repo "$legacy_live_repo"
mkdir -p "$legacy_live_repo/.agents/agent-registry"
printf '%s\n' '{"schema_version":1,"registry":"luna-local-review-loop","workers":[{"task_id":"legacy-live","status":"active"}]}' >"$legacy_live_repo/.agents/agent-registry/registry.json"
chmod 0600 "$legacy_live_repo/.agents/agent-registry/registry.json"
legacy_before="$(cat "$legacy_live_repo/.agents/agent-registry/registry.json")"
if "$INIT_SCRIPT" --repo "$legacy_live_repo" >"$TEST_ROOT/legacy-live.out" 2>&1; then fail 'live schema-v1 state was abandoned'; fi
rg -F 'contains 1 live worker' "$TEST_ROOT/legacy-live.out" >/dev/null || fail 'schema-v1 recovery evidence omitted live worker count'
[[ "$(cat "$legacy_live_repo/.agents/agent-registry/registry.json")" == "$legacy_before" ]] || fail 'live schema-v1 state changed'

legacy_empty_repo="$TEST_ROOT/legacy-empty-repo"
make_test_repo "$legacy_empty_repo"
legacy_empty_real="$(cd -P "$legacy_empty_repo" && pwd -P)"
mkdir -p "$legacy_empty_repo/.agents/agent-registry"
printf '{"schema_version":1,"registry":"luna-local-review-loop","repository_root":"%s","workers":[]}\n' "$legacy_empty_real" >"$legacy_empty_repo/.agents/agent-registry/registry.json"
chmod 0600 "$legacy_empty_repo/.agents/agent-registry/registry.json"
"$INIT_SCRIPT" --repo "$legacy_empty_repo" >/dev/null
jq -e '.schema_version == 3 and .workers == [] and .identity_ledger == []' "$legacy_empty_repo/.agents/agent-registry/registry.json" >/dev/null || fail 'empty owned schema-v1 state did not migrate'

v2_repo="$TEST_ROOT/v2-repo"
make_test_repo "$v2_repo"
v2_path="$("$INIT_SCRIPT" --repo "$v2_repo" --print-path)"
jq '.schema_version = 2 | del(.repository_checkout_identity)' "$v2_path" >"$v2_path.tmp"
mv "$v2_path.tmp" "$v2_path"
"$INIT_SCRIPT" --repo "$v2_repo" >/dev/null
jq -e '.schema_version == 3 and .workers == []' "$v2_path" >/dev/null || fail 'empty project-local schema-v2 state did not migrate'

for v2_invalid_case in malformed unsafe; do
	v2_invalid_repo="$TEST_ROOT/v2-$v2_invalid_case-repo"
	make_test_repo "$v2_invalid_repo"
	v2_invalid_path="$("$INIT_SCRIPT" --repo "$v2_invalid_repo" --print-path)"
	v2_invalid_git_dir="$(git -C "$v2_invalid_repo" rev-parse --absolute-git-dir)"
	v2_invalid_seal="$v2_invalid_git_dir/.luna-checkout-identity"
	case "$v2_invalid_case" in
	malformed)
		jq '.schema_version = 2 | del(.repository_checkout_identity) | .identity_ledger = [] | .created_at = {}' "$v2_invalid_path" >"$v2_invalid_path.tmp"
		;;
	unsafe)
		jq '.schema_version = 2 | del(.repository_checkout_identity) | .identity_ledger = [] | .created_at = ["unsafe-v2"]' "$v2_invalid_path" >"$v2_invalid_path.tmp"
		;;
	esac
	mv "$v2_invalid_path.tmp" "$v2_invalid_path"
	chmod 0600 "$v2_invalid_path"
	rm "$v2_invalid_seal"
	v2_invalid_before="$(cat "$v2_invalid_path")"
	expect_normal_init_failure "$v2_invalid_repo" "$TEST_ROOT/v2-$v2_invalid_case.out"
	[[ "$(cat "$v2_invalid_path")" == "$v2_invalid_before" ]] || fail "$v2_invalid_case schema-v2 state changed before safe migration rejection"
	[[ ! -e "$v2_invalid_seal" && ! -L "$v2_invalid_seal" ]] || fail "$v2_invalid_case schema-v2 rejection created checkout seal"
	if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$v2_invalid_repo" --task-id "fallback-v2-$v2_invalid_case" --scope "reject unsafe schema-v2 fallback preflight: $v2_invalid_case" --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/fallback-v2-$v2_invalid_case.out" 2>&1; then
		fail "$v2_invalid_case schema-v2 fallback preflight unexpectedly started"
	fi
	[[ "$(cat "$v2_invalid_path")" == "$v2_invalid_before" ]] || fail "$v2_invalid_case fallback preflight changed registry bytes"
	[[ ! -e "$v2_invalid_seal" && ! -L "$v2_invalid_seal" ]] || fail "$v2_invalid_case fallback preflight created checkout seal"
done

for fallback_ignore_case in symlink wrong-mode malformed root-negation; do
	fallback_ignore_repo="$TEST_ROOT/fallback-ignore-$fallback_ignore_case-repo"
	make_test_repo "$fallback_ignore_repo"
	fallback_ignore_path="$("$INIT_SCRIPT" --repo "$fallback_ignore_repo" --print-path)"
	fallback_ignore_dir="$(dirname "$fallback_ignore_path")"
	fallback_ignore_file="$fallback_ignore_dir/.gitignore"
	fallback_ignore_git_dir="$(git -C "$fallback_ignore_repo" rev-parse --absolute-git-dir)"
	fallback_ignore_seal="$fallback_ignore_git_dir/.luna-checkout-identity"
	jq '.schema_version = 2 | del(.repository_checkout_identity)' "$fallback_ignore_path" >"$fallback_ignore_path.tmp"
	mv "$fallback_ignore_path.tmp" "$fallback_ignore_path"
	chmod 0600 "$fallback_ignore_path"
	case "$fallback_ignore_case" in
	symlink)
		fallback_ignore_target="$TEST_ROOT/fallback-ignore-symlink-target"
		printf '%s\n' preserve >"$fallback_ignore_target"
		rm "$fallback_ignore_file"
		ln -s "$fallback_ignore_target" "$fallback_ignore_file"
		;;
	wrong-mode)
		chmod 0644 "$fallback_ignore_file"
		;;
	malformed)
		printf '%s\n' invalid-private-rule >"$fallback_ignore_file"
		chmod 0600 "$fallback_ignore_file"
		;;
	root-negation)
		printf '%s\n' '.agents/agent-registry/' '!.agents/agent-registry/registry.json' >"$fallback_ignore_repo/.gitignore"
		;;
	esac
	rm "$fallback_ignore_seal"
	fallback_ignore_registry_before="$TEST_ROOT/fallback-ignore-$fallback_ignore_case-registry.before"
	fallback_ignore_root_before="$TEST_ROOT/fallback-ignore-$fallback_ignore_case-root.before"
	cp "$fallback_ignore_path" "$fallback_ignore_registry_before"
	cp "$fallback_ignore_repo/.gitignore" "$fallback_ignore_root_before"
	if [[ "$fallback_ignore_case" == symlink ]]; then
		fallback_ignore_private_before='symlink'
	else
		fallback_ignore_private_before="$TEST_ROOT/fallback-ignore-$fallback_ignore_case-private.before"
		cp "$fallback_ignore_file" "$fallback_ignore_private_before"
	fi
	fallback_ignore_status=0
	CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$fallback_ignore_repo" --task-id "fallback-ignore-$fallback_ignore_case" --scope "reject unsafe fallback ignore state: $fallback_ignore_case" --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/fallback-ignore-$fallback_ignore_case.out" 2>&1 || fallback_ignore_status=$?
	[[ "$fallback_ignore_status" -ne 0 ]] || fail "unsafe fallback ignore state unexpectedly started: $fallback_ignore_case"
	cmp -s "$fallback_ignore_registry_before" "$fallback_ignore_path" || fail "fallback ignore rejection changed registry bytes: $fallback_ignore_case"
	cmp -s "$fallback_ignore_root_before" "$fallback_ignore_repo/.gitignore" || fail "fallback ignore rejection changed root ignore bytes: $fallback_ignore_case"
	[[ ! -e "$fallback_ignore_seal" && ! -L "$fallback_ignore_seal" ]] || fail "fallback ignore rejection created checkout seal: $fallback_ignore_case"
	case "$fallback_ignore_case" in
	symlink)
		[[ -L "$fallback_ignore_file" ]] || fail 'fallback symlink ignore was replaced'
		[[ "$(cat "$fallback_ignore_target")" == preserve ]] || fail 'fallback symlink ignore target changed'
		;;
	*)
		cmp -s "$fallback_ignore_private_before" "$fallback_ignore_file" || fail "fallback private ignore bytes changed: $fallback_ignore_case"
		;;
	esac
done

v2_history_repo="$TEST_ROOT/v2-history-repo"
make_test_repo "$v2_history_repo"
v2_history_path="$("$INIT_SCRIPT" --repo "$v2_history_repo" --print-path)"
jq '.schema_version = 2 | .identity_ledger = [{"task_id":"old-history"}]' "$v2_history_path" >"$v2_history_path.tmp"
mv "$v2_history_path.tmp" "$v2_history_path"
v2_history_before="$(cat "$v2_history_path")"
if "$INIT_SCRIPT" --existing-path --repo "$v2_history_repo" >"$TEST_ROOT/v2-history.out" 2>&1; then
	fail 'non-empty project-local schema-v2 state migrated automatically'
fi
[[ "$(cat "$v2_history_path")" == "$v2_history_before" ]] || fail 'non-empty schema-v2 state changed during refused migration'

private_ignore_repair_repo="$TEST_ROOT/private-ignore-repair-repo"
make_test_repo "$private_ignore_repair_repo"
private_ignore_repair_path="$("$INIT_SCRIPT" --repo "$private_ignore_repair_repo" --print-path)"
private_ignore_repair_file="$(dirname "$private_ignore_repair_path")/.gitignore"
printf '%s\n' 'legacy-private-rule' >"$private_ignore_repair_file"
chmod 0600 "$private_ignore_repair_file"
"$INIT_SCRIPT" --repo "$private_ignore_repair_repo" >/dev/null || fail 'normal init did not repair registry-local .gitignore'
[[ "$(cat "$private_ignore_repair_file")" == $'legacy-private-rule\n*' ]] || fail 'normal init did not append final * registry-local ignore rule'
[[ "$(file_mode "$private_ignore_repair_file")" == 600 ]] || fail 'normal registry-local .gitignore repair changed private mode'
printf '%s\n' 'invalid-private-rule' >"$private_ignore_repair_file"
private_ignore_recovery_registry_before="$(cat "$private_ignore_repair_path")"
private_ignore_recovery_file_before="$(cat "$private_ignore_repair_file")"
private_ignore_recovery_root_before="$(cat "$private_ignore_repair_repo/.gitignore")"
expect_init_failure "$private_ignore_repair_repo" "$TEST_ROOT/private-ignore-recovery.out"
[[ "$(cat "$private_ignore_repair_file")" == "$private_ignore_recovery_file_before" ]] || fail 'existing-path recovery repaired invalid registry-local .gitignore'
[[ "$(cat "$private_ignore_repair_path")" == "$private_ignore_recovery_registry_before" ]] || fail 'existing-path recovery changed registry while rejecting invalid registry-local .gitignore'
[[ "$(cat "$private_ignore_repair_repo/.gitignore")" == "$private_ignore_recovery_root_before" ]] || fail 'existing-path recovery changed root .gitignore while rejecting invalid registry-local .gitignore'

unsafe_agents_repo="$TEST_ROOT/unsafe-agents-repo"
make_test_repo "$unsafe_agents_repo"
chmod 0777 "$unsafe_agents_repo/.agents"
expect_init_failure "$unsafe_agents_repo" "$TEST_ROOT/unsafe-agents.out"
[[ "$(file_mode "$unsafe_agents_repo/.agents")" == 777 ]] || fail 'unsafe ancestor mode was changed'

symlink_agents_repo="$TEST_ROOT/symlink-agents-repo"
make_test_repo "$symlink_agents_repo"
mv "$symlink_agents_repo/.agents" "$symlink_agents_repo/.agents.saved"
mkdir "$TEST_ROOT/symlink-agents-target"
ln -s "$TEST_ROOT/symlink-agents-target" "$symlink_agents_repo/.agents"
expect_init_failure "$symlink_agents_repo" "$TEST_ROOT/symlink-agents.out"
[[ ! -e "$TEST_ROOT/symlink-agents-target/agent-registry" ]] || fail 'symlinked ancestor received registry state'

symlink_registry_repo="$TEST_ROOT/symlink-registry-repo"
make_test_repo "$symlink_registry_repo"
mkdir "$TEST_ROOT/symlink-registry-target"
ln -s "$TEST_ROOT/symlink-registry-target" "$symlink_registry_repo/.agents/agent-registry"
expect_init_failure "$symlink_registry_repo" "$TEST_ROOT/symlink-registry.out"
[[ ! -e "$TEST_ROOT/symlink-registry-target/registry.json" ]] || fail 'symlinked registry directory received state'

symlink_ignore_repo="$TEST_ROOT/symlink-ignore-repo"
make_test_repo "$symlink_ignore_repo"
printf '%s\n' preserve >"$TEST_ROOT/ignore-target"
ln -s "$TEST_ROOT/ignore-target" "$symlink_ignore_repo/.gitignore"
expect_init_failure "$symlink_ignore_repo" "$TEST_ROOT/symlink-ignore.out"
[[ "$(cat "$TEST_ROOT/ignore-target")" == preserve ]] || fail 'symlinked .gitignore target changed'

unsafe_ignore_repo="$TEST_ROOT/unsafe-ignore-repo"
make_test_repo "$unsafe_ignore_repo"
printf '%s\n' preserve >"$unsafe_ignore_repo/.gitignore"
chmod 0660 "$unsafe_ignore_repo/.gitignore"
expect_init_failure "$unsafe_ignore_repo" "$TEST_ROOT/unsafe-ignore.out"
[[ "$(file_mode "$unsafe_ignore_repo/.gitignore")" == 660 ]] || fail 'unsafe .gitignore mode was changed'

hardlink_ignore_repo="$TEST_ROOT/hardlink-ignore-repo"
make_test_repo "$hardlink_ignore_repo"
printf '%s\n' preserve >"$TEST_ROOT/hardlink-ignore-target"
ln "$TEST_ROOT/hardlink-ignore-target" "$hardlink_ignore_repo/.gitignore"
expect_init_failure "$hardlink_ignore_repo" "$TEST_ROOT/hardlink-ignore.out"
[[ "$(cat "$TEST_ROOT/hardlink-ignore-target")" == preserve ]] || fail 'hard-linked .gitignore target changed'

for nested_ignore_case in \
  '.agents/agent-registry/registry.json' \
  '.agents/agent-registry/.lock' \
  '.agents/agent-registry/.lock-owner.candidate' \
  '.agents/agent-registry/artifacts/example/nested/result.json'; do
  nested_ignore_name="$(printf '%s' "$nested_ignore_case" | tr '/' '-')"
  nested_ignore_repo="$TEST_ROOT/nested-ignore-$nested_ignore_name"
  make_test_repo "$nested_ignore_repo"
  printf '%s\n' '.agents/agent-registry/' "!$nested_ignore_case" >"$nested_ignore_repo/.gitignore"
  nested_ignore_before="$(cat "$nested_ignore_repo/.gitignore")"
  if "$INIT_SCRIPT" --repo "$nested_ignore_repo" >"$TEST_ROOT/nested-ignore-$nested_ignore_name.out" 2>&1; then
    fail "unsafe nested ignore negation was accepted: $nested_ignore_case"
  fi
  [[ "$(cat "$nested_ignore_repo/.gitignore")" == "$nested_ignore_before" ]] || fail "nested ignore rejection rewrote root .gitignore: $nested_ignore_case"
  [[ ! -e "$nested_ignore_repo/.agents/agent-registry" ]] || fail "nested ignore rejection created registry state: $nested_ignore_case"
done

insecure_registry_repo="$TEST_ROOT/insecure-registry-repo"
make_test_repo "$insecure_registry_repo"
insecure_registry_path="$("$INIT_SCRIPT" --repo "$insecure_registry_repo" --print-path)"
chmod 0644 "$insecure_registry_path"
expect_init_failure "$insecure_registry_repo" "$TEST_ROOT/insecure-registry.out"
chmod 0600 "$insecure_registry_path"

private_ignore_insecure_repo="$TEST_ROOT/private-ignore-insecure-repo"
make_test_repo "$private_ignore_insecure_repo"
private_ignore_insecure_path="$("$INIT_SCRIPT" --repo "$private_ignore_insecure_repo" --print-path)"
private_ignore_insecure_file="$(dirname "$private_ignore_insecure_path")/.gitignore"
chmod 0644 "$private_ignore_insecure_file"
private_ignore_insecure_before="$(cat "$private_ignore_insecure_file")"
expect_init_failure "$private_ignore_insecure_repo" "$TEST_ROOT/private-ignore-insecure.out"
[[ "$(cat "$private_ignore_insecure_file")" == "$private_ignore_insecure_before" ]] || fail 'unsafe registry-local .gitignore changed'
chmod 0600 "$private_ignore_insecure_file"

private_ignore_symlink_repo="$TEST_ROOT/private-ignore-symlink-repo"
make_test_repo "$private_ignore_symlink_repo"
private_ignore_symlink_path="$("$INIT_SCRIPT" --repo "$private_ignore_symlink_repo" --print-path)"
private_ignore_symlink_file="$(dirname "$private_ignore_symlink_path")/.gitignore"
private_ignore_symlink_target="$TEST_ROOT/private-ignore-symlink-target"
printf '%s\n' preserve >"$private_ignore_symlink_target"
rm "$private_ignore_symlink_file"
ln -s "$private_ignore_symlink_target" "$private_ignore_symlink_file"
expect_init_failure "$private_ignore_symlink_repo" "$TEST_ROOT/private-ignore-symlink.out"
[[ "$(cat "$private_ignore_symlink_target")" == preserve ]] || fail 'symlinked registry-local .gitignore target changed'
rm "$private_ignore_symlink_file"
printf '%s\n' '*' >"$private_ignore_symlink_file"
chmod 0600 "$private_ignore_symlink_file"

private_ignore_hardlink_repo="$TEST_ROOT/private-ignore-hardlink-repo"
make_test_repo "$private_ignore_hardlink_repo"
private_ignore_hardlink_path="$("$INIT_SCRIPT" --repo "$private_ignore_hardlink_repo" --print-path)"
private_ignore_hardlink_file="$(dirname "$private_ignore_hardlink_path")/.gitignore"
private_ignore_hardlink_target="$TEST_ROOT/private-ignore-hardlink-target"
printf '%s\n' '*' >"$private_ignore_hardlink_target"
chmod 0600 "$private_ignore_hardlink_target"
rm "$private_ignore_hardlink_file"
ln "$private_ignore_hardlink_target" "$private_ignore_hardlink_file"
expect_init_failure "$private_ignore_hardlink_repo" "$TEST_ROOT/private-ignore-hardlink.out"
[[ "$(cat "$private_ignore_hardlink_target")" == '*' ]] || fail 'hard-linked registry-local .gitignore target changed'
rm "$private_ignore_hardlink_file"
printf '%s\n' '*' >"$private_ignore_hardlink_file"
chmod 0600 "$private_ignore_hardlink_file"

hardlink_registry_repo="$TEST_ROOT/hardlink-registry-repo"
make_test_repo "$hardlink_registry_repo"
hardlink_registry_path="$("$INIT_SCRIPT" --repo "$hardlink_registry_repo" --print-path)"
printf '%s\n' preserve >"$TEST_ROOT/hardlink-registry-target"
chmod 0600 "$TEST_ROOT/hardlink-registry-target"
ln "$hardlink_registry_path" "$TEST_ROOT/hardlink-registry-target-link"
if "$INIT_SCRIPT" --existing-path --repo "$hardlink_registry_repo" >"$TEST_ROOT/hardlink-registry.out" 2>&1; then fail 'hard-linked registry file was accepted'; fi
[[ "$(cat "$TEST_ROOT/hardlink-registry-target")" == preserve ]] || fail 'hard-linked registry inspection changed target'

seal_security_repo="$TEST_ROOT/seal-security-repo"
make_test_repo "$seal_security_repo"
seal_security_path="$("$INIT_SCRIPT" --repo "$seal_security_repo" --print-path)"
seal_security_git_dir="$(git -C "$seal_security_repo" rev-parse --absolute-git-dir)"
seal_security_file="$seal_security_git_dir/.luna-checkout-identity"
seal_security_saved="$seal_security_git_dir/.luna-checkout-identity.saved"
seal_security_target="$TEST_ROOT/seal-security-target"
seal_security_registry_before="$(cat "$seal_security_path")"
seal_security_ignore_before="$(cat "$seal_security_repo/.gitignore")"
mv "$seal_security_file" "$seal_security_saved"
expect_init_failure "$seal_security_repo" "$TEST_ROOT/seal-missing.out"
[[ "$(cat "$seal_security_path")" == "$seal_security_registry_before" ]] || fail 'missing seal changed registry during existing-path recovery'
[[ "$(cat "$seal_security_repo/.gitignore")" == "$seal_security_ignore_before" ]] || fail 'missing seal changed root metadata during existing-path recovery'
mv "$seal_security_saved" "$seal_security_file"

mv "$seal_security_file" "$seal_security_saved"
printf '%s\n' invalid-seal >"$seal_security_file"
chmod 0600 "$seal_security_file"
expect_init_failure "$seal_security_repo" "$TEST_ROOT/seal-malformed.out"
[[ "$(cat "$seal_security_path")" == "$seal_security_registry_before" ]] || fail 'malformed seal changed registry'
rm "$seal_security_file"
mv "$seal_security_saved" "$seal_security_file"

chmod 0644 "$seal_security_file"
expect_init_failure "$seal_security_repo" "$TEST_ROOT/seal-mode.out"
chmod 0600 "$seal_security_file"

cp "$seal_security_file" "$seal_security_target"
chmod 0600 "$seal_security_target"
mv "$seal_security_file" "$seal_security_saved"
ln "$seal_security_target" "$seal_security_file"
expect_init_failure "$seal_security_repo" "$TEST_ROOT/seal-hardlink.out"
rm "$seal_security_file"
mv "$seal_security_saved" "$seal_security_file"

mv "$seal_security_file" "$seal_security_saved"
ln -s "$seal_security_target" "$seal_security_file"
expect_init_failure "$seal_security_repo" "$TEST_ROOT/seal-symlink.out"
rm "$seal_security_file"
mv "$seal_security_saved" "$seal_security_file"

mv "$seal_security_file" "$seal_security_saved"
printf '%064d\n' 0 >"$seal_security_file"
chmod 0600 "$seal_security_file"
expect_init_failure "$seal_security_repo" "$TEST_ROOT/seal-replacement.out"
rm "$seal_security_file"
mv "$seal_security_saved" "$seal_security_file"

preseal_repo="$TEST_ROOT/preseal-migration-repo"
make_test_repo "$preseal_repo"
preseal_path="$("$INIT_SCRIPT" --repo "$preseal_repo" --print-path)"
preseal_git_dir="$(git -C "$preseal_repo" rev-parse --absolute-git-dir)"
preseal_seal="$preseal_git_dir/.luna-checkout-identity"
preseal_git_identity="$(stat -c '%d:%i' "$preseal_git_dir" 2>/dev/null || stat -f '%d:%i' "$preseal_git_dir")"
jq --arg checkout "gitdir:$preseal_git_identity" '
  .repository_checkout_identity = $checkout
  | .updated_at = "2020-01-01T00:00:00Z"
  | .preserved_state = {ledger:"keep",number:7}
  | .identity_ledger = [{
      task_id:"retired-history",
      scope:"pre-seal historical task",
      sandbox:"read-only",
      retry_of:null,
      session_id:"01preseal-history",
      status:"retired",
      reserved_at:"2026-01-01T00:00:00Z",
      bound_at:"2026-01-01T00:01:00Z",
      activated_at:"2026-01-01T00:02:00Z",
      terminal_at:"2026-01-01T00:03:00Z",
      retired_at:"2026-01-01T00:03:00Z",
      terminal_status:"completed",
      terminal_evidence:"historical completion"
    }]
  | .workers = []
' "$preseal_path" >"$preseal_path.tmp"
mv "$preseal_path.tmp" "$preseal_path"
rm "$preseal_seal"
"$INIT_SCRIPT" --repo "$preseal_repo" >/dev/null
jq -e '.repository_checkout_identity | test("^gitdir:[0-9]+:[0-9]+:seal:[0-9a-f]{64}:seal-file:[0-9]+:[0-9]+$")' "$preseal_path" >/dev/null || fail 'drained pre-seal registry did not receive seal identity'
jq -e 'any(.identity_ledger[]; .task_id == "retired-history" and .terminal_evidence == "historical completion")' "$preseal_path" >/dev/null || fail 'pre-seal migration discarded retired identity history'
jq -e '.updated_at != "2020-01-01T00:00:00Z" and .preserved_state == {ledger:"keep",number:7}' "$preseal_path" >/dev/null || fail 'checkout seal migration did not atomically update timestamp while preserving registry state'

sealed_legacy_checkout_identity="$(jq -r '.repository_checkout_identity' "$preseal_path" | sed -E 's/:seal-file:[0-9]+:[0-9]+$//')"
[[ "$sealed_legacy_checkout_identity" =~ ^gitdir:[0-9]+:[0-9]+:seal:[0-9a-f]{64}$ ]] || fail 'sealed legacy fixture did not omit only seal-file identity component'
jq --arg checkout "$sealed_legacy_checkout_identity" '.repository_checkout_identity = $checkout' "$preseal_path" >"$preseal_path.tmp"
mv "$preseal_path.tmp" "$preseal_path"
sealed_legacy_before_file="$TEST_ROOT/sealed-legacy-before.json"
cp "$preseal_path" "$sealed_legacy_before_file"
sealed_legacy_registry_sha_before="$(file_sha256 "$preseal_path")"
sealed_legacy_seal_sha_before="$(file_sha256 "$preseal_seal")"
"$REGISTRY_SCRIPT" preflight --repo "$preseal_repo" >/dev/null || fail 'valid sealed legacy schema-v3 registry failed read-only preflight'
sealed_legacy_registry_sha_after="$(file_sha256 "$preseal_path")"
sealed_legacy_seal_sha_after="$(file_sha256 "$preseal_seal")"
[[ "$sealed_legacy_registry_sha_after" == "$sealed_legacy_registry_sha_before" ]] || fail 'sealed legacy schema-v3 preflight changed registry SHA-256'
cmp -s "$sealed_legacy_before_file" "$preseal_path" || fail 'sealed legacy schema-v3 preflight changed registry bytes'
[[ "$sealed_legacy_seal_sha_after" == "$sealed_legacy_seal_sha_before" ]] || fail 'sealed legacy schema-v3 preflight changed checkout seal'

preseal_live_repo="$TEST_ROOT/preseal-live-repo"
make_test_repo "$preseal_live_repo"
preseal_live_path="$("$INIT_SCRIPT" --repo "$preseal_live_repo" --print-path)"
preseal_live_git_dir="$(git -C "$preseal_live_repo" rev-parse --absolute-git-dir)"
preseal_live_seal="$preseal_live_git_dir/.luna-checkout-identity"
preseal_live_identity="$(stat -c '%d:%i' "$preseal_live_git_dir" 2>/dev/null || stat -f '%d:%i' "$preseal_live_git_dir")"
jq --arg checkout "gitdir:$preseal_live_identity" '
  .repository_checkout_identity = $checkout
  | .identity_ledger = [{
      task_id:"live-pre-seal",
      scope:"live pre-seal task",
      sandbox:"read-only",
      retry_of:null,
      session_id:"01preseal-live",
      status:"active",
      reserved_at:"2026-01-01T00:00:00Z",
      bound_at:"2026-01-01T00:01:00Z",
      activated_at:"2026-01-02T00:02:00Z",
      terminal_at:null,
      retired_at:null,
      terminal_status:null,
      terminal_evidence:""
    }]
  | .workers = [{
      task_id:"live-pre-seal",
      scope:"live pre-seal task",
      sandbox:"read-only",
      retry_of:null,
      session_id:"01preseal-live",
      status:"active",
      created_at:"2026-01-01T00:00:00Z",
      updated_at:"2026-01-02T00:02:00Z",
      bound_at:"2026-01-01T00:01:00Z",
      activated_at:"2026-01-02T00:02:00Z",
      checkpoint_evidence:"",
      invocation_pid:null,
      invocation_token:null,
      invocation_instance:null,
      active_child_pgid:null,
      active_child_instance:null
    }]
' "$preseal_live_path" >"$preseal_live_path.tmp"
mv "$preseal_live_path.tmp" "$preseal_live_path"
rm "$preseal_live_seal"
preseal_live_before="$(cat "$preseal_live_path")"
expect_init_failure "$preseal_live_repo" "$TEST_ROOT/preseal-live.out"
[[ "$(cat "$preseal_live_path")" == "$preseal_live_before" ]] || fail 'live pre-seal registry changed during refused migration'
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$preseal_live_repo" --task-id fallback-preseal-live --scope 'reject live pre-seal fallback preflight' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/fallback-preseal-live.out" 2>&1; then
	fail 'live pre-seal fallback preflight unexpectedly started'
fi
[[ "$(cat "$preseal_live_path")" == "$preseal_live_before" ]] || fail 'live pre-seal fallback preflight changed registry bytes'
[[ ! -e "$preseal_live_seal" && ! -L "$preseal_live_seal" ]] || fail 'live pre-seal fallback preflight created checkout seal'

preseal_unproven_repo="$TEST_ROOT/preseal-unproven-repo"
make_test_repo "$preseal_unproven_repo"
preseal_unproven_path="$("$INIT_SCRIPT" --repo "$preseal_unproven_repo" --print-path)"
preseal_unproven_git_dir="$(git -C "$preseal_unproven_repo" rev-parse --absolute-git-dir)"
preseal_unproven_identity="$(stat -c '%d:%i' "$preseal_unproven_git_dir" 2>/dev/null || stat -f '%d:%i' "$preseal_unproven_git_dir")"
jq --arg checkout "gitdir:$preseal_unproven_identity" '.repository_root = "/unproven/repository/root" | .repository_checkout_identity = $checkout | .workers = [] | .identity_ledger = []' "$preseal_unproven_path" >"$preseal_unproven_path.tmp"
mv "$preseal_unproven_path.tmp" "$preseal_unproven_path"
preseal_unproven_before="$(cat "$preseal_unproven_path")"
expect_init_failure "$preseal_unproven_repo" "$TEST_ROOT/preseal-unproven.out"
[[ "$(cat "$preseal_unproven_path")" == "$preseal_unproven_before" ]] || fail 'unproven pre-seal registry changed during refused migration'

move_repo="$TEST_ROOT/move-repo"
make_test_repo "$move_repo"
move_path_before="$($INIT_SCRIPT --repo "$move_repo" --print-path)"
move_identity_before="$(jq -r '.repository_identity' "$move_path_before")"
mv "$move_repo" "$TEST_ROOT/move-repo-renamed"
move_repo_new="$TEST_ROOT/move-repo-renamed"
move_path_after="$("$INIT_SCRIPT" --repo "$move_repo_new" --print-path)"
move_repo_new_real="$(cd -P "$move_repo_new" && pwd -P)"
[[ "$move_path_after" == "$move_repo_new_real/.agents/agent-registry/registry.json" ]] || fail 'moved checkout path was not deterministic'
jq -e --arg root "$move_repo_new_real" '.repository_root == $root' "$move_path_after" >/dev/null || fail 'moved checkout root was not updated'
[[ "$(jq -r '.repository_identity' "$move_path_after")" == "$move_identity_before" ]] || fail 'moved checkout changed repository identity'

copied_repo="$TEST_ROOT/copied-repo"
cp -R "$move_repo_new" "$copied_repo"
if "$INIT_SCRIPT" --existing-path --repo "$copied_repo" >"$TEST_ROOT/copied-repo.out" 2>&1; then fail 'copied repository reused original registry identity'; fi
replacement_repo="$TEST_ROOT/replacement-repo"
mkdir -p "$replacement_repo"
cp -R "$move_repo_new/.agents" "$replacement_repo/.agents"
cp "$move_repo_new/.gitignore" "$replacement_repo/.gitignore"
git -C "$replacement_repo" init -q
if "$INIT_SCRIPT" --existing-path --repo "$replacement_repo" >"$TEST_ROOT/replacement-repo.out" 2>&1; then fail 'replacement Git repository reused original registry'; fi

linked_main="$TEST_ROOT/linked-main"
linked_worktree="$TEST_ROOT/linked-worktree"
linked_copy="$TEST_ROOT/linked-worktree-copy"
make_test_repo "$linked_main"
"$INIT_SCRIPT" --repo "$linked_main" >/dev/null
git -C "$linked_main" add .gitignore
git -C "$linked_main" commit -qm 'ignore registry'
git -C "$linked_main" worktree add -q "$linked_worktree" -b linked-test
linked_main_path="$("$INIT_SCRIPT" --existing-path --repo "$linked_main")"
linked_worktree_path="$("$INIT_SCRIPT" --repo "$linked_worktree" --print-path)"
[[ "$linked_main_path" != "$linked_worktree_path" ]] || fail 'linked worktree shared registry path'
cp -R "$linked_worktree" "$linked_copy"
if "$INIT_SCRIPT" --existing-path --repo "$linked_copy" >"$TEST_ROOT/copied-linked.out" 2>&1; then fail 'copied linked worktree alias was accepted'; fi

ordinary_alias_repo="$TEST_ROOT/ordinary-alias-repo"
ordinary_alias="$TEST_ROOT/ordinary-alias"
make_test_repo "$ordinary_alias_repo"
"$INIT_SCRIPT" --repo "$ordinary_alias_repo" >/dev/null
mkdir "$ordinary_alias"
ln -s "$ordinary_alias_repo/.git" "$ordinary_alias/.git"
if "$INIT_SCRIPT" --existing-path --repo "$ordinary_alias" >"$TEST_ROOT/ordinary-alias.out" 2>&1; then fail 'ordinary Git-directory symlink alias was accepted'; fi

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id direct-active --scope 'direct lifecycle and checkpoint' --sandbox read-only >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id direct-active --session-id 01direct-active >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id direct-active --session-id 01direct-active >/dev/null
"$REGISTRY_SCRIPT" checkpoint --repo "$REPO_ROOT" --task-id direct-active --evidence checkpoint >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id direct-active --status blocked --evidence blocked >/dev/null
jq -e 'any(.identity_ledger[]; .task_id == "direct-active" and .terminal_status == "blocked")' "$registry_path" >/dev/null || fail 'direct lifecycle row missing'
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id retry-parent --scope 'direct retry scope' --sandbox read-only >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id retry-parent --status failed --evidence failed >/dev/null
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id retry-child --scope 'direct retry scope' --retry-of retry-parent >/dev/null
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id retry-escalation --scope 'direct retry scope' --retry-of retry-parent --sandbox workspace-write >/dev/null 2>&1; then fail 'retry escalated sandbox'; fi
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id retry-child --status interrupted --evidence 'done' >/dev/null
if "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id retry-duplicate --scope 'direct retry scope' --retry-of retry-parent >/dev/null 2>&1; then fail 'retry parent accepted multiple children'; fi
jq -e 'any(.identity_ledger[]; .task_id == "retry-child" and .retry_of == "retry-parent" and .sandbox == "read-only")' "$registry_path" >/dev/null || fail 'retry linkage or sandbox missing'

hardlink_registry_target="$TEST_ROOT/registry-hardlink-target"
printf '%s\n' untouched >"$hardlink_registry_target"
chmod 0600 "$hardlink_registry_target"
ln "$registry_path" "$hardlink_registry_target.link"
if "$REGISTRY_SCRIPT" active --repo "$REPO_ROOT" >"$TEST_ROOT/hardlink-registry-check.out" 2>&1; then fail 'registry accepted multiply-linked authoritative file'; fi
[[ "$(cat "$hardlink_registry_target")" == untouched ]] || fail 'registry hard-link target changed'
rm -f "$hardlink_registry_target.link"

mkdir -m 0700 "$registry_dir/artifacts"
artifact_symlink_target="$TEST_ROOT/artifact-symlink-target"
mkdir -m 0700 "$artifact_symlink_target"
ln -s "$artifact_symlink_target" "$registry_dir/artifacts/symlink-artifact"
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id symlink-artifact --scope 'reject symlinked task artifact directory' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/symlink-artifact.out" 2>&1; then
	fail 'runner accepted a symlinked task artifact directory'
fi
[[ ! -e "$artifact_symlink_target/.task-prompt" ]] || fail 'symlinked task artifact target received state'
rm -f "$registry_dir/artifacts/symlink-artifact"

hardlink_artifact_dir="$registry_dir/artifacts/hardlink-artifact"
mkdir -m 0700 "$hardlink_artifact_dir"
hardlink_artifact_target="$TEST_ROOT/hardlink-artifact-target"
printf '%s\n' untouched >"$hardlink_artifact_target"
chmod 0600 "$hardlink_artifact_target"
ln "$hardlink_artifact_target" "$hardlink_artifact_dir/.task-prompt"
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id hardlink-artifact --scope 'reject multiply-linked task prompt artifact' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/hardlink-artifact.out" 2>&1; then
	fail 'runner accepted a multiply-linked task prompt artifact'
fi
[[ "$(cat "$hardlink_artifact_target")" == untouched ]] || fail 'multiply-linked task prompt target changed'
rm -f "$hardlink_artifact_dir/.task-prompt"
rmdir "$hardlink_artifact_dir"

gate_registry_before="$(cat "$registry_path")"
if FAKE_CODEX_VERSION='codex-cli 0.146.9' CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id old-codex-workspace-write --scope 'reject workspace-write before reservation on old Codex' --sandbox workspace-write --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/old-codex-workspace-write.out" 2>&1; then
  fail 'Codex 0.146.9 was accepted for workspace-write'
fi
[[ "$(cat "$registry_path")" == "$gate_registry_before" ]] || fail 'old Codex workspace-write gate mutated registry before reservation'
if FAKE_CODEX_VERSION='codex-cli not-a-version' CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id malformed-codex-workspace-write --scope 'reject malformed Codex version before reservation' --sandbox workspace-write --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/malformed-codex-workspace-write.out" 2>&1; then
  fail 'malformed Codex version was accepted for workspace-write'
fi
[[ "$(cat "$registry_path")" == "$gate_registry_before" ]] || fail 'malformed Codex workspace-write gate mutated registry'
old_read_only_output="$(FAKE_CODEX_VERSION='codex-cli 0.146.9' CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id old-codex-read-only --scope 'retain read-only support on old Codex' --sandbox read-only --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/old-codex-read-only.err")"
jq -e '.outcome == "completed"' <<<"$old_read_only_output" >/dev/null || fail 'read-only task was blocked by workspace-write version gate'

lock_fail_bin="$TEST_ROOT/lock-fail-bin"
mkdir "$lock_fail_bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$lock_fail_bin/sed"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$lock_fail_bin/ps"
chmod 0755 "$lock_fail_bin/sed" "$lock_fail_bin/ps"
if PATH="$lock_fail_bin:$PATH" "$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" >"$TEST_ROOT/lock-candidate-failure.out" 2>&1; then
  fail 'lock process identity failure unexpectedly succeeded'
fi
for lock_candidate in "$registry_dir"/.lock-owner.*; do
	[[ ! -e "$lock_candidate" && ! -L "$lock_candidate" ]] || fail 'failed process identity left a lock-owner candidate'
done

lock_probe_bin="$TEST_ROOT/lock-probe-bin"
lock_probe_count="$TEST_ROOT/lock-probe-count"
mkdir "$lock_probe_bin"
# shellcheck disable=SC2016 # The following single-quoted lines generate a separate probe script.
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'count=0' \
	'if [[ -f "${LOCK_PROBE_COUNT_FILE:?}" ]]; then count="$(command -p cat "$LOCK_PROBE_COUNT_FILE")"; fi' \
	'count=$((count + 1))' \
	'printf "%s\n" "$count" >"$LOCK_PROBE_COUNT_FILE"' \
	'if [[ "$count" == 1 ]]; then exec "${LOCK_PROBE_REAL_SED:?}" "$@"; fi' \
	'exit 1' >"$lock_probe_bin/sed"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$lock_probe_bin/ps"
chmod 0755 "$lock_probe_bin/sed" "$lock_probe_bin/ps"
lock_probe_real_sed="$(command -p -v sed)"
if PATH="$lock_probe_bin:$PATH" LOCK_PROBE_COUNT_FILE="$lock_probe_count" LOCK_PROBE_REAL_SED="$lock_probe_real_sed" "$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id registry-lock-candidate-failure --scope 'shared registry caller lock candidate cleanup' >/dev/null 2>&1; then
	fail 'registry caller lock process identity failure unexpectedly succeeded'
fi
for lock_candidate in "$registry_dir"/.lock-owner.*; do
	[[ ! -e "$lock_candidate" && ! -L "$lock_candidate" ]] || fail 'registry caller left a lock-owner candidate after process identity failure'
done
jq -e 'all(.workers[]; .task_id != "registry-lock-candidate-failure")' "$registry_path" >/dev/null || fail 'registry caller lock failure mutated registry state'

version_gate_continue_scope='reject workspace-write continuation before invocation claim'
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id old-codex-continue --scope "$version_gate_continue_scope" --sandbox workspace-write >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id old-codex-continue --session-id 01old-codex-continue >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id old-codex-continue --session-id 01old-codex-continue >/dev/null
if FAKE_CODEX_VERSION='codex-cli 0.146.9' CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --task-id old-codex-continue --prompt-file "$CONTINUE_FILE" >"$TEST_ROOT/old-codex-continue.out" 2>&1; then
  fail 'old Codex workspace-write continuation was accepted'
fi
jq -e 'any(.workers[]; .task_id == "old-codex-continue" and .invocation_token == null)' "$registry_path" >/dev/null || fail 'old Codex continuation claimed invocation before version gate'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id old-codex-continue --status interrupted --evidence 'version gate test complete' >/dev/null

printf '%s\n' 'runner task' >"$PROMPT_FILE"
runner_output="$(FAKE_CODEX_VERSION='codex-cli 0.147.0' CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id local-runner --scope 'local runner artifact and structured-result contract' --sandbox workspace-write --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/local-runner.err")"
jq -e '.outcome == "completed" and (.validators | length > 0)' <<<"$runner_output" >/dev/null || fail 'registered runner did not complete'
jq -e 'any(.identity_ledger[]; .task_id == "local-runner" and .terminal_status == "completed") and .workers == []' "$registry_path" >/dev/null || fail 'runner did not retire completed task'
runner_artifact_dir="$registry_dir/artifacts/local-runner"
[[ -f "$runner_artifact_dir/.task-prompt" && -f "$runner_artifact_dir/launch.jsonl" ]] || fail 'runner artifacts not below project-local registry'
[[ "$(file_mode "$runner_artifact_dir/.task-prompt")" == 600 ]] || fail 'task prompt snapshot not private'
if rg -F -- '--ephemeral' "$CODEX_CALLS" >/dev/null; then fail 'runner used ephemeral session'; fi
rg -F -- 'exec resume' "$CODEX_CALLS" >/dev/null || fail 'runner did not resume exact session'
rg -F -- '--ignore-user-config' "$CODEX_CALLS" >/dev/null || fail 'runner enabled user config'
rg -F -- 'sandbox_mode="workspace-write"' "$CODEX_CALLS" >/dev/null || fail 'runner did not reapply registered sandbox'
rg -F -- '-s read-only' "$CODEX_CALLS" >/dev/null || fail 'handshake was not read-only'
awk -v expected="cwd=$repo_real " '/exec resume/ && index($0, expected) != 1 {bad=1} END {exit bad ? 1 : 0}' "$CODEX_CALLS" || fail 'resume did not use canonical repository root'

printf '%s\n' 'needs parent' >"$PROMPT_FILE"
needs_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id continuation-runner --scope 'same-session continuation contract' --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/continuation.err")"
jq -e '.outcome == "needs_parent_action" and (.parentAction | length > 0)' <<<"$needs_output" >/dev/null || fail 'needs_parent_action result invalid'
jq -e 'any(.workers[]; .task_id == "continuation-runner" and .status == "active")' "$registry_path" >/dev/null || fail 'needs_parent_action did not preserve active worker'
printf '%s\n' 'continue and complete' >"$CONTINUE_FILE"
continue_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --task-id continuation-runner --prompt-file "$CONTINUE_FILE" 2>"$TEST_ROOT/continuation-resume.err")"
jq -e '.outcome == "completed"' <<<"$continue_output" >/dev/null || fail 'same-session continuation did not complete'
jq -e 'any(.identity_ledger[]; .task_id == "continuation-runner" and .terminal_status == "completed") and .workers == []' "$registry_path" >/dev/null || fail 'continuation did not retire worker'
continuation_artifact_dir="$registry_dir/artifacts/continuation-runner"
continuation_trackers=("$continuation_artifact_dir/".descendants-*.json)
[[ -f "$continuation_artifact_dir/.task-prompt" && -f "$continuation_artifact_dir/stream-2.jsonl" && -f "$continuation_artifact_dir/result-2.json" ]] || fail 'continue artifacts were not below exact project-local registry authority'
[[ "${#continuation_trackers[@]}" -eq 2 ]] || fail 'launch and continue tracker artifacts were not retained below project-local registry authority'
[[ ! -e "$REPO_ROOT/artifacts" && ! -L "$REPO_ROOT/artifacts" ]] || fail 'continue created repository-root artifacts'

"$REGISTRY_SCRIPT" assert-no-active --repo "$REPO_ROOT" >/dev/null
"$REGISTRY_SCRIPT" assert-empty --repo "$REPO_ROOT" >/dev/null
[[ "$(rg -c '^\.agents/agent-registry/$' "$REPO_ROOT/.gitignore")" == 1 ]] || fail 'final init was not idempotent'

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
	"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id zombie-recovery --scope 'reclaim a defunct invocation owner' >/dev/null
	"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id zombie-recovery --session-id 01zombie-recovery-session >/dev/null
	"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id zombie-recovery --session-id 01zombie-recovery-session >/dev/null
	"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id zombie-recovery --pid "$zombie_pid" --token zombie-owner >/dev/null
	"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id zombie-recovery --pid "$$" --token zombie-reclaimer >/dev/null
	"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id zombie-recovery --status interrupted --evidence 'defunct owner reclaimed' --invocation-token zombie-reclaimer >/dev/null
else
	printf '%s\n' 'SKIP: shell reaped zombie fixture before observation' >&2
fi
kill "$zombie_parent_pid" 2>/dev/null || true
wait "$zombie_parent_pid" 2>/dev/null || true

sleep 30 &
bind_owner_pid=$!
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id owned-bind --scope 'require live invocation authority for bind and activate' --pid "$bind_owner_pid" --token bind-owner >/dev/null
if "$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id owned-bind --session-id 01owned-bind-session >/dev/null 2>&1; then
	fail 'tokenless bind mutated a task owned by a live invocation'
fi
if "$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id owned-bind --session-id 01owned-bind-session --invocation-token wrong-owner >/dev/null 2>&1; then
	fail 'mismatched invocation token bound an owned task'
fi
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id owned-bind --session-id 01owned-bind-session --invocation-token bind-owner >/dev/null
if "$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id owned-bind --session-id 01owned-bind-session >/dev/null 2>&1; then
	fail 'tokenless activation mutated a task owned by a live invocation'
fi
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id owned-bind --session-id 01owned-bind-session --invocation-token bind-owner >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id owned-bind --status interrupted --evidence 'bind ownership test complete' --invocation-token bind-owner >/dev/null
kill "$bind_owner_pid" 2>/dev/null || true
wait "$bind_owner_pid" 2>/dev/null || true
bind_owner_pid=''

sleep 30 &
dead_bind_owner_pid=$!
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id recovered-bind --scope 'allow tokenless bind after invocation owner exits' --pid "$dead_bind_owner_pid" --token dead-bind-owner >/dev/null
kill "$dead_bind_owner_pid" 2>/dev/null || true
wait "$dead_bind_owner_pid" 2>/dev/null || true
dead_bind_owner_pid=''
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id recovered-bind --session-id 01recovered-bind-session >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id recovered-bind --session-id 01recovered-bind-session >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id recovered-bind --status interrupted --evidence 'dead owner recovery complete' >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id owned-reservation --scope 'atomic initial reservation ownership' --pid "$$" --token initial-owner >/dev/null
if "$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id owned-reservation --status interrupted --evidence 'tokenless live-owner retirement' >/dev/null 2>&1; then
	fail 'tokenless recovery retired a task owned by a live invocation'
fi
if "$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id owned-reservation --status failed --evidence 'wrong owner' --invocation-token wrong-owner >/dev/null 2>&1; then
	fail 'a mismatched invocation token retired an owned reservation'
fi
jq -e 'any(.workers[]; .task_id == "owned-reservation" and .invocation_token == "initial-owner")' "$registry_path" >/dev/null || fail 'owned reservation was not retained after mismatched cleanup'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id owned-reservation --status interrupted --evidence 'ownership test complete' --invocation-token initial-owner >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id unowned-completed-retirement --scope 'reject unowned completed retirement' >/dev/null
if "$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id unowned-completed-retirement --status completed --evidence 'missing structured result' >/dev/null 2>&1; then
	fail 'unowned reserved task bypassed the completed structured-result contract'
fi
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id unowned-completed-retirement --status interrupted --evidence 'completed retirement contract test complete' >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id invalid-finish-status --scope 'reject completed explicit finish' >/dev/null
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id invalid-finish-status --status completed --evidence 'must use structured result' >"$TEST_ROOT/invalid-finish.out" 2>&1; then
	fail 'explicit finish accepted completed status'
fi
jq -e 'any(.workers[]; .task_id == "invalid-finish-status" and .status == "reserved" and .invocation_token == null)' "$registry_path" >/dev/null || fail 'invalid finish status mutated the live reservation'
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id invalid-finish-status --status interrupted --evidence 'invalid finish test complete' >/dev/null

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id missing-artifact-finish --scope 'recover without worker artifacts' >/dev/null
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id missing-artifact-finish --status interrupted --evidence 'artifacts were unavailable' >"$TEST_ROOT/missing-artifact-finish.out"
jq -e 'any(.identity_ledger[]; .task_id == "missing-artifact-finish" and .status == "retired" and .terminal_status == "interrupted")' "$registry_path" >/dev/null || fail 'registry-only finish could not retire a task without artifacts'

readonly INVALID_CODEX_STATE="$TEST_ROOT/codex-home-file"
printf '%s\n' 'not a directory' >"$INVALID_CODEX_STATE"
if CODEX_HOME="$INVALID_CODEX_STATE" CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id denied-runtime --scope 'runtime permission probe' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/denied-runtime.out" 2>&1; then
	fail 'runner accepted an invalid Codex runtime state path'
fi
jq -e 'all(.identity_ledger[]; .task_id != "denied-runtime")' "$registry_path" >/dev/null || fail 'runtime permission failure burned a task reservation'

"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id rejected-launch-staging --scope 'reject launch after prompt staging' >/dev/null
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id rejected-launch-staging --scope 'reject launch after prompt staging' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/rejected-launch-staging.out" 2>&1; then
	fail 'reservation-conflict launch unexpectedly succeeded'
fi
for staged_prompt_path in "$registry_dir"/artifacts/.prompt-*; do
	[[ -e "$staged_prompt_path" || -L "$staged_prompt_path" ]] || continue
	fail 'rejected launch left a staged prompt copy'
done
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id rejected-launch-staging --status interrupted --evidence 'rejected launch staging cleanup test complete' >/dev/null

printf '%s\n' 'runner retry task' >"$PROMPT_FILE"
if FAKE_FAIL_HANDSHAKE=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id failed-runner --scope 'runner retry scope' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/failed-runner.out" 2>&1; then
	fail 'failed handshake unexpectedly succeeded'
fi
jq -e 'any(.identity_ledger[]; .task_id == "failed-runner" and .session_id == null and .status == "retired" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'failed pre-bind launch was not atomically retired'
failed_runner_artifact_dir="$registry_dir/artifacts/failed-runner"
[[ -f "$failed_runner_artifact_dir/.task-prompt" && -f "$failed_runner_artifact_dir/launch.jsonl" && -f "$failed_runner_artifact_dir/launch.stderr.log" ]] || fail 'failed launch artifacts were not below exact project-local registry authority'
[[ ! -e "$REPO_ROOT/artifacts" && ! -L "$REPO_ROOT/artifacts" ]] || fail 'failed launch created repository-root artifacts'
retry_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id failed-runner-retry --scope 'runner retry scope' --retry-of failed-runner --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/retry.err")"
jq -e '.outcome == "completed"' <<<"$retry_output" >/dev/null || fail 'runner retry did not complete'

printf '%s\n' 'reject launch before claim publication' >"$PROMPT_FILE"
launch_pre_reservation_task_id='launch-pre-reservation-claim'
launch_pre_reservation_scope='reject launch before claim publication'
launch_pre_reservation_artifacts_backup="$TEST_ROOT/launch-pre-reservation-artifacts"
mv "$registry_dir/artifacts" "$launch_pre_reservation_artifacts_backup"
ln -s "$launch_pre_reservation_artifacts_backup" "$registry_dir/artifacts"
launch_pre_reservation_status=0
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id "$launch_pre_reservation_task_id" --scope "$launch_pre_reservation_scope" --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/launch-pre-reservation.out" 2>&1 || launch_pre_reservation_status=$?
rm "$registry_dir/artifacts"
mv "$launch_pre_reservation_artifacts_backup" "$registry_dir/artifacts"
[[ "$launch_pre_reservation_status" -ne 0 ]] || fail 'pre-reservation launch failure fixture unexpectedly succeeded'
launch_pre_reservation_claim_root="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)/.luna-cross-path-claims"
launch_pre_reservation_claim_path=''
for launch_pre_reservation_candidate in "$launch_pre_reservation_claim_root"/*; do
	[[ -f "$launch_pre_reservation_candidate" && ! -L "$launch_pre_reservation_candidate" ]] || continue
	if rg -q "^token=task-$launch_pre_reservation_task_id$" "$launch_pre_reservation_candidate"; then
		launch_pre_reservation_claim_path="$launch_pre_reservation_candidate"
		break
	fi
done
[[ -z "$launch_pre_reservation_claim_path" ]] || fail 'preflight rejection published a stable task claim'
jq -e --arg task_id "$launch_pre_reservation_task_id" 'all(.workers[]; .task_id != $task_id) and all(.identity_ledger[]; .task_id != $task_id)' "$registry_path" >/dev/null || fail 'preflight rejection reserved fallback registry state'

invalid_retry_scope='release launcher-created claim after invalid retry sandbox'
invalid_retry_parent='invalid-retry-sandbox-parent'
invalid_retry_task='invalid-retry-sandbox-child'
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id "$invalid_retry_parent" --scope "$invalid_retry_scope" --sandbox read-only >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id "$invalid_retry_parent" --status failed --evidence 'invalid sandbox retry fixture parent' >/dev/null
invalid_retry_status=0
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id "$invalid_retry_task" --scope "$invalid_retry_scope" --retry-of "$invalid_retry_parent" --sandbox workspace-write --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-retry-sandbox.out" 2>&1 || invalid_retry_status=$?
[[ "$invalid_retry_status" -eq 6 ]] || fail "invalid explicit retry sandbox returned $invalid_retry_status instead of conflict"
jq -e --arg task_id "$invalid_retry_task" 'all(.workers[]; .task_id != $task_id) and all(.identity_ledger[]; .task_id != $task_id)' "$registry_path" >/dev/null || fail 'invalid explicit retry sandbox reserved registry state'
for invalid_retry_candidate in "$launch_pre_reservation_claim_root"/*; do
	[[ -f "$invalid_retry_candidate" && ! -L "$invalid_retry_candidate" ]] || continue
	if rg -q "^token=task-$invalid_retry_task$" "$invalid_retry_candidate"; then
		fail 'launcher-created claim survived rejected retry reservation'
	fi
done

parent_claim_scope='preserve parent-held claim after invalid retry sandbox'
parent_claim_task='parent-held-invalid-retry-sandbox'
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id "$parent_claim_task-parent" --scope "$parent_claim_scope" --sandbox read-only >/dev/null
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id "$parent_claim_task-parent" --status failed --evidence 'parent-held claim fixture parent' >/dev/null
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$parent_claim_scope" --token "task-$parent_claim_task" >/dev/null
parent_claim_status=0
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id "$parent_claim_task" --scope "$parent_claim_scope" --retry-of "$parent_claim_task-parent" --sandbox workspace-write --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/parent-held-invalid-retry-sandbox.out" 2>&1 || parent_claim_status=$?
[[ "$parent_claim_status" -eq 6 ]] || fail "parent-held invalid retry sandbox returned $parent_claim_status instead of conflict"
parent_claim_path=''
for parent_claim_candidate in "$launch_pre_reservation_claim_root"/*; do
	[[ -f "$parent_claim_candidate" && ! -L "$parent_claim_candidate" ]] || continue
	if rg -q "^token=task-$parent_claim_task$" "$parent_claim_candidate"; then
		parent_claim_path="$parent_claim_candidate"
		break
	fi
done
[[ -n "$parent_claim_path" ]] || fail 'parent-held claim was released after rejected retry reservation'
bash "$CLAIM_SCRIPT" release --repo "$REPO_ROOT" --scope "$parent_claim_scope" --token "task-$parent_claim_task" >/dev/null

printf '%s\n' 'blocked worker' >"$PROMPT_FILE"
blocked_output="$(FAKE_BLOCKED_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id blocked-runner --scope 'blocked runner retry scope' --sandbox read-only --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/blocked-runner.err")"
jq -e '.outcome == "blocked"' <<<"$blocked_output" >/dev/null || fail 'runner did not return a blocked result'
jq -e 'any(.identity_ledger[]; .task_id == "blocked-runner" and .status == "retired" and .terminal_status == "blocked")' "$registry_path" >/dev/null || fail 'blocked runner result was not retired as blocked'
blocked_retry_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id blocked-runner-retry --scope 'blocked runner retry scope' --retry-of blocked-runner --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/blocked-retry.err")"
jq -e '.outcome == "completed"' <<<"$blocked_retry_output" >/dev/null || fail 'retired blocked task did not resume through exact-scope retry'
jq -e 'any(.identity_ledger[]; .task_id == "blocked-runner-retry" and .retry_of == "blocked-runner" and .sandbox == "read-only" and .terminal_status == "completed")' "$registry_path" >/dev/null || fail 'blocked retry did not preserve linkage and sandbox'
"$INIT_SCRIPT" --existing-path --repo "$REPO_ROOT" >/dev/null || fail 'init validation rejected a valid blocked retry chain'

if FAKE_FAIL_HANDSHAKE=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id read-only-failed-runner --scope 'read-only runner retry scope' --sandbox read-only --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/read-only-failed.out" 2>&1; then
	fail 'read-only failed handshake unexpectedly succeeded'
fi
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id read-only-escalating-retry --scope 'read-only runner retry scope' --retry-of read-only-failed-runner --sandbox workspace-write --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/read-only-escalating.out" 2>&1; then
	fail 'runner retry escalated read-only task to workspace-write'
fi
read_only_retry_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id read-only-runner-retry --scope 'read-only runner retry scope' --retry-of read-only-failed-runner --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/read-only-retry.err")"
jq -e '.outcome == "completed"' <<<"$read_only_retry_output" >/dev/null || fail 'read-only runner retry did not complete'
jq -e 'any(.identity_ledger[]; .task_id == "read-only-runner-retry" and .sandbox == "read-only" and .terminal_status == "completed")' "$registry_path" >/dev/null || fail 'runner retry did not preserve read-only sandbox'

printf '%s\n' 'workspace-write task after read-only handshake' >"$PROMPT_FILE"
handshake_sandbox_output="$(FAKE_REQUIRE_READ_ONLY_HANDSHAKE=1 FAKE_REQUIRE_WORKSPACE_WRITE_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id handshake-sandbox-contract --scope 'read-only handshake before workspace-write resume' --sandbox workspace-write --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/handshake-sandbox.err")"
jq -e '.outcome == "completed"' <<<"$handshake_sandbox_output" >/dev/null || fail 'workspace-write task did not use read-only handshake and registered resume sandbox'
jq -e 'any(.identity_ledger[]; .task_id == "handshake-sandbox-contract" and .sandbox == "workspace-write" and .terminal_status == "completed")' "$registry_path" >/dev/null || fail 'workspace-write task did not retain its registered resume sandbox'

prompt_race_original='immutable task prompt before handshake'
printf '%s\n' "$prompt_race_original" >"$PROMPT_FILE"
rm -f "$PROMPT_RACE_MARKER" "$PROMPT_RACE_RELEASE" "$CODEX_PROMPT_CAPTURE"
prompt_race_status=0
FAKE_HANDSHAKE_PROMPT_RACE=1 FAKE_REQUIRE_CLOSED_PROMPT_FD=1 FAKE_REQUIRE_WORKSPACE_WRITE_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id prompt-race-worker --scope 'open immutable prompt before workspace-write resume' --sandbox workspace-write --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/prompt-race.out" 2>"$TEST_ROOT/prompt-race.err" &
prompt_race_runner_pid=$!
poll_attempt=0
while [[ ! -e "$PROMPT_RACE_MARKER" && "$poll_attempt" -lt "$PROMPT_RACE_MARKER_WAIT_ATTEMPTS" ]] && process_is_live_non_zombie "$prompt_race_runner_pid"; do
	sleep 0.01
	poll_attempt=$((poll_attempt + 1))
done
if [[ ! -e "$PROMPT_RACE_MARKER" ]]; then
	process_is_live_non_zombie "$prompt_race_runner_pid" && kill -TERM "$prompt_race_runner_pid" 2>/dev/null || true
	prompt_race_status=0
	wait "$prompt_race_runner_pid" || prompt_race_status=$?
	prompt_race_runner_pid=''
	prompt_race_error="$(cat "$TEST_ROOT/prompt-race.err" 2>/dev/null || true)"
	fail "prompt race handshake did not reach its controlled pause (runner status: $prompt_race_status; stderr: ${prompt_race_error:-empty})"
fi
prompt_snapshot_path="$registry_dir/artifacts/prompt-race-worker/.task-prompt"
[[ -f "$prompt_snapshot_path" && ! -L "$prompt_snapshot_path" ]] || fail 'launch did not create a private prompt snapshot before handshake'
prompt_snapshot_contents="$(cat "$prompt_snapshot_path")"
[[ "$prompt_snapshot_contents" == "$WORKER_BOUNDARY_INSTRUCTION"*"$prompt_race_original"*"$WORKER_BOUNDARY_INSTRUCTION" ]] || fail 'prompt snapshot did not preserve validated prompt contents and worker boundary before handshake'
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
captured_prompt_contents="$(cat "$CODEX_PROMPT_CAPTURE")"
[[ "$captured_prompt_contents" == "$WORKER_BOUNDARY_INSTRUCTION"*"$prompt_race_original"*"$WORKER_BOUNDARY_INSTRUCTION" ]] || fail 'first workspace-write resume consumed a task-artifact replacement or lost the worker boundary'
snapshot_link_count="$(stat -c '%h' "$prompt_snapshot_path" 2>/dev/null || stat -f '%l' "$prompt_snapshot_path" 2>/dev/null)"
[[ "$snapshot_link_count" == '1' ]] || fail 'prompt snapshot did not retain single-link ownership'

relative_codex_output="$(cd "$TEST_ROOT" && PATH="bin:$PATH" CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id relative-codex-worker --scope 'canonicalize relative codex path' --prompt-file task.txt 2>"$TEST_ROOT/relative-codex.err")"
jq -e '.outcome == "completed"' <<<"$relative_codex_output" >/dev/null || fail 'runner did not canonicalize a Codex executable found through a relative PATH entry'

relative_codex_home="$TEST_ROOT/relative-codex-home"
mkdir "$relative_codex_home"
relative_codex_home_output="$(cd "$TEST_ROOT" && PATH="bin:$PATH" CODEX_HOME='relative-codex-home' CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id relative-codex-home-worker --scope 'preserve relative Codex home across repository-directory changes' --prompt-file task.txt 2>"$TEST_ROOT/relative-codex-home.err")"
jq -e '.outcome == "completed"' <<<"$relative_codex_home_output" >/dev/null || fail 'runner did not complete with a relative CODEX_HOME'
relative_codex_home_real="$(cd -P "$relative_codex_home" && pwd -P)"
rg -F "codex_home=$relative_codex_home_real" "$CODEX_CALLS" >/dev/null || fail 'runner did not preserve relative CODEX_HOME as an absolute physical path after changing to --repo'

slow_ps_marker="$TEST_ROOT/slow-ps.ready"
slow_tracker_output="$(PATH="$SLOW_BIN_DIR:$PATH" LUNA_TEST_SLOW_PS=1 SLOW_PS_MARKER="$slow_ps_marker" CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id slow-tracker-worker --scope 'wait for slow tracker readiness' --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/slow-tracker.err")"
jq -e '.outcome == "completed"' <<<"$slow_tracker_output" >/dev/null || fail 'runner imposed a fixed deadline on tracker readiness'
[[ -e "$slow_ps_marker" ]] || fail 'slow tracker fixture did not delay its initial process snapshot'

rm -f "$TRACKER_PS_COUNT_FILE" "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE"
printf '%s\n' 'stable tracker cadence' >"$PROMPT_FILE"
FAKE_BLOCK_RESUME=1 PATH="$SLOW_BIN_DIR:$PATH" CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id adaptive-tracker-worker --scope 'use adaptive ancestry tracker cadence' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/adaptive-tracker.out" 2>"$TEST_ROOT/adaptive-tracker.err" &
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

runner_output="$(cd "$TEST_ROOT" && CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id fast-worker --scope 'one fast task' --prompt-file task.txt 2>"$TEST_ROOT/runner.err")"
jq -e '.outcome == "completed" and .summary == "worker concise result" and (.validators | length == 1) and .validators[0].status == "passed"' <<<"$runner_output" >/dev/null || fail 'runner did not return concise structured output with valid completion evidence'
"$REGISTRY_SCRIPT" assert-no-active --repo "$REPO_ROOT" >/dev/null || fail 'completed worker was not atomically retired'
jq -e 'any(.identity_ledger[]; .task_id == "fast-worker" and (.session_id | startswith("01fake-session-")) and .status == "retired" and .terminal_status == "completed")' "$registry_path" >/dev/null || fail 'fast worker identity/result was not retained'

printf '%s\n' 'legacy claimless continuation' >"$PROMPT_FILE"
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id legacy-claimless-continuation --scope 'legacy claimless continuation' >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id legacy-claimless-continuation --session-id 01legacy-session >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id legacy-claimless-continuation --session-id 01legacy-session >/dev/null
mkdir -m 0700 "$registry_dir/artifacts/legacy-claimless-continuation"
legacy_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --task-id legacy-claimless-continuation --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/legacy-continue.err")"
jq -e '.outcome == "completed" and .summary == "worker concise result" and (.validators | length == 1) and .validators[0].status == "passed"' <<<"$legacy_output" >/dev/null || fail 'legacy claimless continuation did not complete through the shared claim'
jq -e 'any(.identity_ledger[]; .task_id == "legacy-claimless-continuation" and .status == "retired" and .terminal_status == "completed") and (.workers | length == 0)' "$registry_path" >/dev/null || fail 'legacy claimless continuation did not retire atomically'

printf '%s\n' 'legacy continuation loses invocation race' >"$PROMPT_FILE"
legacy_race_task_id='legacy-claimless-invocation-race'
legacy_race_scope='retain claim when legacy continuation loses invocation race'
legacy_race_unrelated_scope='preserve unrelated claim during legacy invocation race'
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id "$legacy_race_task_id" --scope "$legacy_race_scope" >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id "$legacy_race_task_id" --session-id 01legacy-race-session >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id "$legacy_race_task_id" --session-id 01legacy-race-session >/dev/null
mkdir -m 0700 "$registry_dir/artifacts/$legacy_race_task_id"
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$legacy_race_unrelated_scope" --token legacy-race-unrelated >/dev/null
# Legacy controller that won registry invocation has no cross-path claim. The
# continuation under test acquires the previously absent claim, then loses
# claim-invocation. Its failure cleanup must retain that new claim until
# explicit registry recovery/retirement protects the old controller.
sleep 30 &
legacy_race_owner_pid=$!
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id "$legacy_race_task_id" --pid "$legacy_race_owner_pid" --token legacy-race-winner >/dev/null
legacy_race_status=0
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --task-id "$legacy_race_task_id" --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/legacy-race.out" 2>&1 || legacy_race_status=$?
[[ "$legacy_race_status" -ne 0 ]] || fail 'legacy continuation unexpectedly bypassed competing invocation ownership'
jq -e --arg pid "$legacy_race_owner_pid" 'any(.workers[]; .task_id == "legacy-claimless-invocation-race" and .status == "active" and .invocation_token == "legacy-race-winner" and .invocation_pid == $pid)' "$registry_path" >/dev/null || fail 'competing registry invocation owner was not preserved'
legacy_race_claim_root="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)/.luna-cross-path-claims"
legacy_race_claim_present=0
legacy_race_unrelated_present=0
for legacy_race_candidate in "$legacy_race_claim_root"/*; do
	[[ -f "$legacy_race_candidate" && ! -L "$legacy_race_candidate" ]] || continue
	if rg -q '^token=task-legacy-claimless-invocation-race$' "$legacy_race_candidate"; then
		legacy_race_claim_present=1
	fi
	if rg -q '^token=legacy-race-unrelated$' "$legacy_race_candidate"; then
		legacy_race_unrelated_present=1
	fi
done
[[ "$legacy_race_claim_present" -eq 1 ]] || fail 'legacy invocation-race cleanup released newly-created claim'
[[ "$legacy_race_unrelated_present" -eq 1 ]] || fail 'legacy invocation-race cleanup removed unrelated claim'
"$REGISTRY_SCRIPT" release-invocation --repo "$REPO_ROOT" --task-id "$legacy_race_task_id" --token legacy-race-winner >/dev/null
kill "$legacy_race_owner_pid" 2>/dev/null || true
wait "$legacy_race_owner_pid" 2>/dev/null || true
legacy_race_owner_pid=''
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id "$legacy_race_task_id" --status interrupted --evidence 'legacy invocation-race claim retention test complete' >/dev/null
bash "$CLAIM_SCRIPT" release --repo "$REPO_ROOT" --scope "$legacy_race_scope" --token "task-$legacy_race_task_id" >/dev/null
bash "$CLAIM_SCRIPT" release --repo "$REPO_ROOT" --scope "$legacy_race_unrelated_scope" --token legacy-race-unrelated >/dev/null

printf '%s\n' 'legacy finish loses invocation race' >"$PROMPT_FILE"
finish_race_task_id='legacy-finish-invocation-race'
finish_race_scope='retain claim when legacy finish loses invocation race'
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id "$finish_race_task_id" --scope "$finish_race_scope" >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id "$finish_race_task_id" --session-id 01legacy-finish-race-session >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id "$finish_race_task_id" --session-id 01legacy-finish-race-session >/dev/null
# A legacy controller can own the registry invocation without owning a
# cross-path claim. Finish recovery must retain its newly acquired claim when
# it loses the invocation race, so a later native/fallback path cannot enter.
sleep 30 &
finish_race_owner_pid=$!
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id "$finish_race_task_id" --pid "$finish_race_owner_pid" --token legacy-finish-race-winner >/dev/null
finish_race_status=0
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id "$finish_race_task_id" --status interrupted --evidence 'finish invocation race must retain claim' >"$TEST_ROOT/finish-race.out" 2>&1 || finish_race_status=$?
[[ "$finish_race_status" -ne 0 ]] || fail 'legacy finish unexpectedly bypassed competing invocation ownership'
jq -e --arg pid "$finish_race_owner_pid" --arg task_id "$finish_race_task_id" 'any(.workers[]; .task_id == $task_id and .status == "active" and .invocation_token == "legacy-finish-race-winner" and .invocation_pid == $pid)' "$registry_path" >/dev/null || fail 'finish race did not preserve competing registry invocation owner'
finish_race_claim_root="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)/.luna-cross-path-claims"
finish_race_claim_present=0
for finish_race_candidate in "$finish_race_claim_root"/*; do
	[[ -f "$finish_race_candidate" && ! -L "$finish_race_candidate" ]] || continue
	if rg -q "^token=task-$finish_race_task_id$" "$finish_race_candidate"; then
		finish_race_claim_present=1
		break
	fi
done
[[ "$finish_race_claim_present" -eq 1 ]] || fail 'legacy finish invocation-race cleanup released newly-created claim'
"$REGISTRY_SCRIPT" release-invocation --repo "$REPO_ROOT" --task-id "$finish_race_task_id" --token legacy-finish-race-winner >/dev/null
kill "$finish_race_owner_pid" 2>/dev/null || true
wait "$finish_race_owner_pid" 2>/dev/null || true
finish_race_owner_pid=''
"$REGISTRY_SCRIPT" complete-and-retire --repo "$REPO_ROOT" --task-id "$finish_race_task_id" --status interrupted --evidence 'legacy finish invocation-race claim retention test complete' >/dev/null
bash "$CLAIM_SCRIPT" release --repo "$REPO_ROOT" --scope "$finish_race_scope" --token "task-$finish_race_task_id" >/dev/null

printf '%s\n' 'needs parent after re-entered claim' >"$PROMPT_FILE"
reentered_retirement_task_id='reentered-claim-retirement'
reentered_retirement_scope='release re-entered claim after terminal cleanup'
"$REGISTRY_SCRIPT" reserve --repo "$REPO_ROOT" --task-id "$reentered_retirement_task_id" --scope "$reentered_retirement_scope" >/dev/null
"$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id "$reentered_retirement_task_id" --session-id 01reentered-retirement-session >/dev/null
"$REGISTRY_SCRIPT" activate --repo "$REPO_ROOT" --task-id "$reentered_retirement_task_id" --session-id 01reentered-retirement-session >/dev/null
mkdir -m 0700 "$registry_dir/artifacts/$reentered_retirement_task_id"
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$reentered_retirement_scope" --token "task-$reentered_retirement_task_id" >/dev/null
reentered_retirement_status=0
FAKE_INVALID_PARENT_ACTION=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --task-id "$reentered_retirement_task_id" --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/reentered-retirement.out" 2>&1 || reentered_retirement_status=$?
[[ "$reentered_retirement_status" -ne 0 ]] || fail 're-entered claim launcher failure unexpectedly succeeded'
jq -e --arg task_id "$reentered_retirement_task_id" 'any(.identity_ledger[]; .task_id == $task_id and .status == "retired" and .terminal_status == "failed") and all(.workers[]; .task_id != $task_id)' "$registry_path" >/dev/null || fail 're-entered claim launcher failure did not retire the task'
reentered_retirement_claim_present=0
for reentered_retirement_candidate in "$finish_race_claim_root"/*; do
	[[ -f "$reentered_retirement_candidate" && ! -L "$reentered_retirement_candidate" ]] || continue
	if rg -q "^token=task-$reentered_retirement_task_id$" "$reentered_retirement_candidate"; then
		reentered_retirement_claim_present=1
		break
	fi
done
[[ "$reentered_retirement_claim_present" -eq 0 ]] || fail 'terminal cleanup leaked a re-entered claim'

printf '%s\n' 'needs parent' >"$PROMPT_FILE"
needs_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id continued-worker --scope 'one continued task' --sandbox read-only --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/needs.err")"
jq -e '.outcome == "needs_parent_action"' <<<"$needs_output" >/dev/null || fail 'parent-action result was not returned'
jq -e 'any(.workers[]; .task_id == "continued-worker" and .status == "active" and .sandbox == "read-only" and (.session_id | startswith("01fake-session-")))' "$registry_path" >/dev/null || fail 'parent-action worker was not retained as an active read-only session'

jq --arg pid "$$" '
  .workers |= map(if .task_id == "continued-worker"
    then .invocation_pid = $pid | .invocation_token = "reused-pid-stale-owner" | .invocation_instance = "ps:Thu Jan 1 00:00:00 1970"
    else .
    end)
' "$registry_path" >"$registry_path.tmp"
mv "$registry_path.tmp" "$registry_path"
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id continued-worker --pid "$$" --token reused-pid-current-owner >/dev/null
jq -e 'any(.workers[]; .task_id == "continued-worker" and .invocation_pid == $pid and .invocation_token == "reused-pid-current-owner" and (.invocation_instance | type == "string" and length > 0 and . != "ps:Thu Jan 1 00:00:00 1970"))' --arg pid "$$" "$registry_path" >/dev/null || fail 'PID reuse simulation did not replace stale invocation process identity'
"$REGISTRY_SCRIPT" release-invocation --repo "$REPO_ROOT" --task-id continued-worker --token reused-pid-current-owner >/dev/null

sleep 30 &
stale_owner_pid=$!
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id continued-worker --pid "$stale_owner_pid" --token stale-owner >/dev/null
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
if "$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id continued-worker --pid "$$" --token missing-tracker-reclaimer >"$TEST_ROOT/missing-stale-tracker.out" 2>&1; then
	fail 'stale invocation reclaim accepted a recorded child after its tracker artifact disappeared'
fi
printf '%s\n' '{"status":"active","root_pid":99999999,"processes":[]}' >"$stale_tracker"
if "$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id continued-worker --pid "$$" --token premature-reclaimer >"$TEST_ROOT/active-stale-tracker.out" 2>&1; then
	fail 'stale invocation reclaim ignored an active tracker from the previous token'
fi
printf '%s\n' '{"status":"clean","root_pid":99999999,"processes":[{"pid":99999999,"instance":"ps:recorded-process"}]}' >"$stale_tracker"
if "$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id continued-worker --pid "$$" --token dirty-clean-reclaimer >"$TEST_ROOT/dirty-clean-tracker.out" 2>&1; then
	fail 'stale invocation reclaim accepted a clean tracker that retained process identities'
fi
printf '%s\n' '{"status":"clean","root_pid":99999999,"processes":[]}' >"$stale_tracker"
if "$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id continued-worker --pid "$$" --token mismatched-root-reclaimer >"$TEST_ROOT/mismatched-root-tracker.out" 2>&1; then
	fail 'stale invocation reclaim accepted cleanup evidence for a different process-tree root'
fi
printf '%s\n' "{\"status\":\"clean\",\"root_pid\":$$,\"processes\":[]}" >"$stale_tracker"
sleep 30 &
claim_owner_a=$!
sleep 30 &
claim_owner_b=$!
claim_status_a=0
claim_status_b=0
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id continued-worker --pid "$claim_owner_a" --token contender-a >"$TEST_ROOT/claim-a.out" 2>&1 &
claim_command_a=$!
"$REGISTRY_SCRIPT" claim-invocation --repo "$REPO_ROOT" --task-id continued-worker --pid "$claim_owner_b" --token contender-b >"$TEST_ROOT/claim-b.out" 2>&1 &
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
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --task-id continued-worker --prompt-file "$CONTINUE_FILE" >"$TEST_ROOT/concurrent.out" 2>&1; then
	fail 'concurrent continuation bypassed the registry-backed invocation claim'
fi
if ! jq -e 'any(.workers[]; .task_id == "continued-worker" and .status == "active")' "$registry_path" >/dev/null; then
	fail 'rejected concurrent continuation retired the live worker'
fi
"$REGISTRY_SCRIPT" release-invocation --repo "$REPO_ROOT" --task-id continued-worker --token "$winning_claim_token" >/dev/null
kill "$claim_owner_a" "$claim_owner_b" 2>/dev/null || true
wait "$claim_owner_a" 2>/dev/null || true
wait "$claim_owner_b" 2>/dev/null || true
claim_owner_a=''
claim_owner_b=''
continue_output="$(CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" continue --repo "$REPO_ROOT" --task-id continued-worker --prompt-file "$CONTINUE_FILE" 2>"$TEST_ROOT/continue.err")"
jq -e '.outcome == "completed"' <<<"$continue_output" >/dev/null || fail 'exact-session continuation did not complete'
"$REGISTRY_SCRIPT" assert-empty --repo "$REPO_ROOT" >/dev/null || fail 'continued worker was not retired'

printf '%s\n' 'needs parent' >"$PROMPT_FILE"
if FAKE_INVALID_PARENT_ACTION=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id invalid-parent-action --scope 'invalid parent action contract' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-parent.out" 2>&1; then
	fail 'runner accepted needs_parent_action with a null parentAction'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-parent-action" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'invalid structured result was not retired as failed'

printf '%s\n' 'complete only with valid evidence' >"$PROMPT_FILE"
if FAKE_FAILED_COMPLETED=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id invalid-completed-validator --scope 'reject completed result with failed validation' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-validator.out" 2>&1; then
	fail 'runner retired a completed result with failed validation'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-validator" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'failed completed-validator result was not left retryable as failed'
if FAKE_UNRESOLVED_COMPLETED=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id invalid-completed-unresolved --scope 'reject completed result with unresolved work' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-unresolved.out" 2>&1; then
	fail 'runner retired a completed result with unresolved work'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-unresolved" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'unresolved completed result was not left retryable as failed'
if FAKE_EMPTY_COMPLETED_VALIDATORS=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id invalid-completed-empty-validators --scope 'reject completed result without validators' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-empty-validators.out" 2>&1; then
	fail 'runner retired a completed result without validators'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-empty-validators" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'empty completed validators were not left retryable as failed'
if FAKE_BLANK_COMPLETED_COMMAND=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id invalid-completed-blank-command --scope 'reject completed result with blank validator command' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-blank-command.out" 2>&1; then
	fail 'runner retired a completed result with a blank validator command'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-blank-command" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'blank completed validator command was not left retryable as failed'
if FAKE_BLANK_COMPLETED_EVIDENCE=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id invalid-completed-blank-evidence --scope 'reject completed result with blank validator evidence' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/invalid-completed-blank-evidence.out" 2>&1; then
	fail 'runner retired a completed result with blank validator evidence'
fi
jq -e 'any(.identity_ledger[]; .task_id == "invalid-completed-blank-evidence" and .terminal_status == "failed")' "$registry_path" >/dev/null || fail 'blank completed validator evidence was not left retryable as failed'

if "$REGISTRY_SCRIPT" bind --repo "$REPO_ROOT" --task-id missing --session-id nope --handle process-123 >/dev/null 2>&1; then
	fail 'ambiguous process handle argument was accepted'
fi
if rg -- '--ephemeral' "$CODEX_CALLS" >/dev/null; then fail 'runner used --ephemeral'; fi
if rg -- '-maxdepth' "$RUNNER_SCRIPT" >/dev/null; then fail 'runner used GNU-only find arguments'; fi
# The rewritten fixture adds local-runner (one resume), the old-Codex
# read-only task (one resume), the legacy claimless continuation (one resume),
# the re-entered-claim failure (one resume), and the continuation-runner
# launch/continue pair (two resumes), while removing the old
# sparse-continuation resume: 20 - 1 + 1 + 1 + 1 + 1 + 2 = 25.
resume_count="$(rg -c 'exec resume .* -- (01fake-session-[0-9]+|01sparse-continuation|01legacy-session|01reentered-retirement-session) -' "$CODEX_CALLS")"
[[ "$resume_count" -eq 25 ]] || fail "expected twenty-five exact-session resumes, got $resume_count"
ignore_count="$(rg -c -- '--ignore-user-config' "$CODEX_CALLS")"
[[ "$ignore_count" -eq 48 ]] || fail "expected unrelated user MCP config disabled on every Codex call, got $ignore_count"
read_only_count="$(rg -c -- '-s read-only' "$CODEX_CALLS")"
[[ "$read_only_count" -eq 23 ]] || fail "expected every handshake to use read-only sandbox, got $read_only_count"
resume_sandbox_count="$(rg -c -- 'exec resume .*sandbox_mode=' "$CODEX_CALLS")"
[[ "$resume_sandbox_count" -eq 25 ]] || fail "expected every resume to reapply its registered sandbox, got $resume_sandbox_count"
read_only_resume_count="$(rg -c -- 'exec resume .*sandbox_mode="read-only"' "$CODEX_CALLS")"
[[ "$read_only_resume_count" -eq 6 ]] || fail "expected read-only sandbox on retry, blocked retry, and both continued-session resumes, got $read_only_resume_count"
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
detached_output="$(FAKE_DETACH_RESUME=1 CODEX_DETACHED_TRACKER_DIR="$detached_tracker_dir" CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id detached-worker --scope 'drain detached worker descendant' --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/detached.err")" || detached_status=$?
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
	CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id detached-worker --status interrupted --evidence 'non-procfs descendant required explicit cleanup' >"$TEST_ROOT/detached-finish.out"
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
fast_reparent_output="$(PATH="$SLOW_BIN_DIR:$PATH" LUNA_TEST_DELAY_REPARENT_PS=1 FAST_REPARENT_PS_MARKER="$fast_reparent_ps_marker" FAKE_FAST_REPARENT_RESUME=1 CODEX_BIN=codex "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id fast-reparent-worker --scope 'drain a fast-reparented worker descendant' --prompt-file "$PROMPT_FILE" 2>"$TEST_ROOT/fast-reparent.err")" || fast_reparent_status=$?
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
	CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id fast-reparent-worker --status interrupted --evidence 'non-procfs fast-reparented descendant required explicit cleanup' >"$TEST_ROOT/fast-reparent-finish.out"
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
FAKE_BLOCK_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id unproven-signal-worker --scope 'preserve active state when lease cleanup is unproven' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/unproven-signal.out" 2>"$TEST_ROOT/unproven-signal.err" &
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
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id unproven-signal-worker --status interrupted --evidence 'lease evidence still requires explicit cleanup' >"$TEST_ROOT/unproven-signal-finish.out" 2>&1; then
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
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id unproven-signal-worker --status interrupted --evidence 'lease evidence explicitly cleaned' >"$TEST_ROOT/unproven-signal-finish-clean.out"

printf '%s\n' 'terminate child safely' >"$PROMPT_FILE"
rm -f "$CODEX_CHILD_PID_FILE" "$CODEX_DESCENDANT_PID_FILE"
FAKE_BLOCK_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id terminated-worker --scope 'terminate child before retirement' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/terminated.out" 2>"$TEST_ROOT/terminated.err" &
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
FAKE_BLOCK_RESUME=1 CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" launch --repo "$REPO_ROOT" --task-id hard-killed-worker --scope 'retain hard-killed child identity' --prompt-file "$PROMPT_FILE" >"$TEST_ROOT/hard-killed.out" 2>"$TEST_ROOT/hard-killed.err" &
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
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id hard-killed-worker --status interrupted --evidence 'must not retire live child' >"$TEST_ROOT/live-child-finish.out" 2>&1; then
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
if CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id hard-killed-worker --status interrupted --evidence 'missing tracker must block retirement' >"$TEST_ROOT/missing-tracker-finish.out" 2>&1; then
	fail 'recovery retired a recorded child after its tracker artifact disappeared'
fi
mv "$hard_killed_tracker.saved" "$hard_killed_tracker"
CODEX_BIN="$BIN_DIR/codex" "$RUNNER_SCRIPT" finish --repo "$REPO_ROOT" --task-id hard-killed-worker --status interrupted --evidence 'child stopped and identity verified' >"$TEST_ROOT/hard-kill-finish.out"
jq -e 'any(.identity_ledger[]; .task_id == "hard-killed-worker" and .status == "retired" and .terminal_status == "interrupted") and all(.workers[]; .task_id != "hard-killed-worker")' "$registry_path" >/dev/null || fail 'hard-kill recovery did not retire after child exit'
hard_killed_child_pgid=''

missing_repo="$TEST_ROOT/missing-skills"
git init -q "$missing_repo"
if "$INIT_SCRIPT" --repo "$missing_repo" >"$TEST_ROOT/missing.out" 2>&1; then
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
if "$INIT_SCRIPT" --repo "$symlink_repo" >"$TEST_ROOT/symlink.out" 2>&1; then
	fail 'init accepted a symlinked project skill ancestor'
fi

mv "$REPO_ROOT/.agents/skills" "$REPO_ROOT/.agents/skills.off"
"$REGISTRY_SCRIPT" active --repo "$REPO_ROOT" >/dev/null || fail 'registry recovery required launch-only project skills'
mv "$REPO_ROOT/.agents/skills.off" "$REPO_ROOT/.agents/skills"

printf '%s\n' 'PASS: safe project-local registry, single-child retries, serialized resumes, recovery-only access, strict result contract, and atomic retirement'
