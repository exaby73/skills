#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_RUNTIME_STATE=11
readonly EXIT_WORKER=12

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly REGISTRY_SCRIPT="$SCRIPT_DIR/registry.sh"
readonly RESULT_SCHEMA="$SCRIPT_DIR/../references/worker-result.schema.json"

MODE='launch'
REPO_INPUT='.'
REPO_ROOT=''
STATE_ROOT_INPUT="${LUNA_REGISTRY_ROOT:-${TMPDIR:-/tmp}/luna-local-review-loop}"
TASK_ID=''
SCOPE=''
RETRY_OF=''
PROMPT_FILE=''
TASK_SANDBOX=''
MODEL='gpt-5.6-luna'
REASONING_EFFORT='max'
CODEX_BIN="${CODEX_BIN:-codex}"
FINISHED=0
SESSION_ID=''
INVOCATION_TOKEN=''
INVOCATION_CLAIMED=0
ACTIVE_CODEX_PID=''
ACTIVE_CODEX_PGID=''
ACTIVE_HELPER_PID=''
ACTIVE_TRACKER_PID=''
ACTIVE_TRACKER_STATE=''

usage() {
	local exit_code="${1:-0}"
	cat <<'EOF'
Usage:
  run-worker.sh launch --task-id ID --scope TEXT --prompt-file FILE [--retry-of ID] [--sandbox read-only|workspace-write] [--repo PATH] [--state-root PATH]
  run-worker.sh continue --task-id ID --prompt-file FILE [--repo PATH] [--state-root PATH]
  run-worker.sh finish --task-id ID --status failed|blocked|interrupted --evidence TEXT [--repo PATH] [--state-root PATH]

Launch atomically reserves, creates and binds a resumable Codex session,
activates it, and sends the task without a PTY or manual EOF. Continue resumes
the exact registered session. Structured final output is printed to stdout;
streaming logs stay in the external registry state directory.
EOF
	exit "$exit_code"
}

die() {
	local exit_code="$1"
	shift
	printf 'luna-local-review-loop: ERROR [%s] %s\n' "$exit_code" "$*" >&2
	exit "$exit_code"
}

runtime_state_is_writable() {
	local codex_home="${CODEX_HOME:-${HOME:-}/.codex}"
	local probe=''
	[[ -n "$codex_home" && -d "$codex_home" && -w "$codex_home" ]] || die "$EXIT_RUNTIME_STATE" "Codex runtime state is not writable: ${codex_home:-unknown}. The parent must allow the owning Codex state directory separately from the worker repository sandbox, then retry."
	probe="$(mktemp "$codex_home/.luna-runtime-probe.XXXXXX" 2>/dev/null)" || die "$EXIT_RUNTIME_STATE" "Codex runtime state denied a real write probe: $codex_home. The parent must allow that exact runtime directory separately from the worker repository sandbox, then retry."
	rm -f "$probe" || die "$EXIT_RUNTIME_STATE" "Codex runtime write probe could not be removed: $probe. Inspect it before retrying."
}

validate_common() {
	local codex_discovered=''
	local codex_parent=''
	local codex_name=''
	local prompt_parent=''
	local prompt_name=''
	codex_discovered="$(command -v "$CODEX_BIN" 2>/dev/null)" || die "$EXIT_PREREQUISITE" "Codex CLI not found: $CODEX_BIN."
	case "$codex_discovered" in /*) ;; *) codex_discovered="$PWD/$codex_discovered" ;; esac
	codex_parent="${codex_discovered%/*}"
	codex_name="${codex_discovered##*/}"
	codex_parent="$(cd -P "$codex_parent" 2>/dev/null && pwd -P)" || die "$EXIT_PREREQUISITE" "cannot resolve Codex CLI parent: $codex_discovered."
	CODEX_BIN="$codex_parent/$codex_name"
	[[ -f "$CODEX_BIN" && -x "$CODEX_BIN" ]] || die "$EXIT_PREREQUISITE" "Codex CLI is not an executable file: $CODEX_BIN."
	[[ -f "$RESULT_SCHEMA" ]] || die "$EXIT_PREREQUISITE" "worker result schema not found: $RESULT_SCHEMA."
	[[ -d "$REPO_INPUT" ]] || die "$EXIT_USAGE" "repository path does not exist or is not a directory: $REPO_INPUT."
	REPO_ROOT="$(git -C "$REPO_INPUT" rev-parse --show-toplevel 2>/dev/null)" || die "$EXIT_USAGE" "repository path is not inside a Git repository: $REPO_INPUT."
	REPO_ROOT="$(cd -P "$REPO_ROOT" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve repository root: $REPO_INPUT."
	[[ "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "$EXIT_USAGE" 'task-id must contain only letters, numbers, dot, underscore, or hyphen.'
	[[ -f "$PROMPT_FILE" && ! -L "$PROMPT_FILE" ]] || die "$EXIT_USAGE" "prompt-file must be a regular non-symlink file: $PROMPT_FILE."
	case "$PROMPT_FILE" in /*) ;; *) PROMPT_FILE="$PWD/$PROMPT_FILE" ;; esac
	prompt_parent="${PROMPT_FILE%/*}"
	prompt_name="${PROMPT_FILE##*/}"
	prompt_parent="$(cd -P "$prompt_parent" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve prompt-file parent: $PROMPT_FILE."
	PROMPT_FILE="$prompt_parent/$prompt_name"
	case "$TASK_SANDBOX" in '' | read-only | workspace-write) ;; *) die "$EXIT_USAGE" 'sandbox must be read-only or workspace-write.' ;; esac
	runtime_state_is_writable
}

finish_on_error() {
	local exit_code=$?
	if [[ "$FINISHED" -eq 0 && -n "$TASK_ID" && -n "$INVOCATION_TOKEN" ]]; then
		"$REGISTRY_SCRIPT" complete-and-retire --task-id "$TASK_ID" --status failed --evidence "worker launcher exited $exit_code before a structured terminal result" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" >/dev/null 2>&1 || true
	fi
	INVOCATION_CLAIMED=0
	exit "$exit_code"
}

prepare_invocation() {
	[[ -n "$INVOCATION_TOKEN" ]] || INVOCATION_TOKEN="invocation-$$-${RANDOM:-0}-$(date -u '+%Y%m%dT%H%M%S')"
}

claim_invocation() {
	prepare_invocation
	local claim_args=(claim-invocation --task-id "$TASK_ID" --pid "$$" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT")
	[[ "$MODE" != continue ]] || claim_args+=(--require-status active)
	run_registry_quiet "${claim_args[@]}"
	INVOCATION_CLAIMED=1
}

release_invocation() {
	if [[ "$INVOCATION_CLAIMED" -eq 1 ]]; then
		run_registry_quiet release-invocation --task-id "$TASK_ID" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
		INVOCATION_CLAIMED=0
	fi
}

stop_active_child_and_exit() {
	local signal_name="$1"
	local exit_code="$2"
	if [[ -n "$ACTIVE_HELPER_PID" ]] && kill -0 "$ACTIVE_HELPER_PID" 2>/dev/null; then
		kill -s "$signal_name" "$ACTIVE_HELPER_PID" 2>/dev/null || true
		wait "$ACTIVE_HELPER_PID" 2>/dev/null || true
	fi
	stop_codex_process_group "$signal_name" || true
	stop_tracked_worker_processes "$signal_name" || true
	ACTIVE_HELPER_PID=''
	ACTIVE_CODEX_PID=''
	ACTIVE_CODEX_PGID=''
	exit "$exit_code"
}

write_descendant_state() {
	local status="$1"
	local root_pid="$2"
	local known_file="$3"
	local state_path="$4"
	local temp_path
	temp_path="$(mktemp "${state_path}.tmp.XXXXXX")" || return 1
	if ! jq -Rn --arg status "$status" --arg root "$root_pid" '
      [inputs
        | capture("^(?<pid>[1-9][0-9]*)[|](?<instance>.+)$")
        | {pid:(.pid | tonumber), instance:.instance}]
      | {status:$status, root_pid:($root | tonumber), processes:.}
    ' <"$known_file" >"$temp_path"; then
		rm -f "$temp_path"
		return 1
	fi
	mv "$temp_path" "$state_path"
}

process_instance_identity() {
	local pid="$1"
	local start=''
	case "$pid" in '' | 0 | *[!0-9]*) return 1 ;; esac
	if [[ -r "/proc/$pid/stat" ]]; then
		start="$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk 'NF >= 20 {print $20; exit}')" || return 1
		[[ "$start" =~ ^[0-9]+$ ]] || return 1
		printf 'proc:%s\n' "$start"
		return 0
	fi
	start="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | awk 'NF {$1=$1; print; exit}')" || return 1
	[[ -n "$start" ]] || return 1
	printf 'ps:%s\n' "$start"
}

process_instance_matches() {
	local pid="$1"
	local expected="$2"
	local current=''
	local process_state=''
	current="$(process_instance_identity "$pid")" || return 1
	[[ "$current" == "$expected" ]] || return 1
	process_state="$(ps -p "$pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"
	case "$process_state" in '' | Z*) return 1 ;; esac
	return 0
}

record_process_instance() {
	local pid="$1"
	local destination="$2"
	local instance=''
	instance="$(process_instance_identity "$pid")" || return 1
	printf '%s|%s\n' "$pid" "$instance" >>"$destination"
}

monitor_descendant_tree() {
	local root_pid="$1"
	local state_path="$2"
	local known_file
	local snapshot
	local additions
	local live_count
	local root_live
	local root_instance
	local pid
	local instance
	local recorded_count
	known_file="$(mktemp "${state_path}.known.XXXXXX")" || exit 1
	snapshot="$(mktemp "${state_path}.snapshot.XXXXXX")" || exit 1
	additions="$(mktemp "${state_path}.additions.XXXXXX")" || exit 1
	trap 'rm -f "$known_file" "$snapshot" "$additions"' EXIT
	root_instance="$(process_instance_identity "$root_pid")" || exit 1
	printf '%s|%s\n' "$root_pid" "$root_instance" >"$known_file"
	while true; do
		ps -ax -o pid=,ppid=,stat= 2>/dev/null | awk 'NF >= 3 {print $1 "|" $2 "|" $3}' >"$snapshot" || exit 1
		while true; do
			awk -F '|' 'NR == FNR { known[$1] = 1; next } $3 !~ /^Z/ && known[$2] && !known[$1] { print $1 }' "$known_file" "$snapshot" >"$additions"
			[[ -s "$additions" ]] || break
			recorded_count=0
			while IFS= read -r pid; do
				if record_process_instance "$pid" "$known_file"; then
					recorded_count=$((recorded_count + 1))
				fi
			done <"$additions"
			[[ "$recorded_count" -gt 0 ]] || break
			sort -t '|' -k1,1n -u -o "$known_file" "$known_file"
		done
		: >"$additions"
		while IFS='|' read -r pid instance; do
			process_instance_matches "$pid" "$instance" && printf '%s|%s\n' "$pid" "$instance" >>"$additions"
		done <"$known_file"
		mv "$additions" "$known_file"
		additions="$(mktemp "${state_path}.additions.XXXXXX")" || exit 1
		live_count="$(awk 'END { print NR + 0 }' "$known_file")"
		root_live=0
		process_instance_matches "$root_pid" "$root_instance" && root_live=1
		if [[ "$root_live" -eq 0 && "$live_count" -eq 0 ]]; then
			write_descendant_state clean "$root_pid" "$known_file" "$state_path" || exit 1
			exit 0
		fi
		write_descendant_state active "$root_pid" "$known_file" "$state_path" || exit 1
		sleep 0.01
	done
}

tracked_worker_processes() {
	local state_path="$1"
	[[ -f "$state_path" && ! -L "$state_path" ]] || return 1
	jq -r '.processes[] | "\(.pid)|\(.instance)"' "$state_path" 2>/dev/null
}

tracked_worker_processes_are_empty() {
	local state_path="$1"
	local pid
	local instance
	while IFS='|' read -r pid instance; do
		process_instance_matches "$pid" "$instance" && return 1
	done < <(tracked_worker_processes "$state_path") || return 1
	return 0
}

tracker_process_is_live() {
	local tracker_pid="$1"
	local process_state=''
	process_state="$(ps -p "$tracker_pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"
	case "$process_state" in '' | Z*) return 1 ;; *) return 0 ;; esac
}

stop_tracked_worker_processes() {
	local signal_name="$1"
	local attempt=0
	local kill_attempt=0
	local pid
	local instance
	[[ -n "$ACTIVE_TRACKER_STATE" ]] || return 0
	while [[ -n "$ACTIVE_TRACKER_PID" ]] && tracker_process_is_live "$ACTIVE_TRACKER_PID" && [[ "$attempt" -lt 100 ]]; do
		while IFS='|' read -r pid instance; do
			process_instance_matches "$pid" "$instance" && kill -s "$signal_name" "$pid" 2>/dev/null || true
		done < <(tracked_worker_processes "$ACTIVE_TRACKER_STATE")
		sleep 0.05
		attempt=$((attempt + 1))
	done
	while [[ -n "$ACTIVE_TRACKER_PID" ]] && tracker_process_is_live "$ACTIVE_TRACKER_PID" && [[ "$kill_attempt" -lt 50 ]]; do
		while IFS='|' read -r pid instance; do
			process_instance_matches "$pid" "$instance" && kill -KILL "$pid" 2>/dev/null || true
		done < <(tracked_worker_processes "$ACTIVE_TRACKER_STATE")
		sleep 0.05
		kill_attempt=$((kill_attempt + 1))
	done
	if [[ -n "$ACTIVE_TRACKER_PID" ]]; then
		tracker_process_is_live "$ACTIVE_TRACKER_PID" && return 1
		wait "$ACTIVE_TRACKER_PID" 2>/dev/null || return 1
	fi
	tracked_worker_processes_are_empty "$ACTIVE_TRACKER_STATE" || return 1
	jq -e '.status == "clean"' "$ACTIVE_TRACKER_STATE" >/dev/null 2>&1 || return 1
	ACTIVE_TRACKER_PID=''
}

process_group_is_empty() {
	local pgid="$1"
	local live_count=''
	case "$pgid" in '' | 0 | *[!0-9]*) return 1 ;; esac
	live_count="$(ps -ax -o pgid=,stat= 2>/dev/null | awk -v target="$pgid" '$1 == target && $2 !~ /^Z/ {count++} END {print count + 0}')" || return 1
	[[ "$live_count" -eq 0 ]]
}

wait_for_process_group_exit() {
	local pgid="$1"
	local attempt=0
	while ! process_group_is_empty "$pgid" && [[ "$attempt" -lt 50 ]]; do
		sleep 0.05
		attempt=$((attempt + 1))
	done
	process_group_is_empty "$pgid"
}

stop_codex_process_group() {
	local signal_name="$1"
	local pgid="$ACTIVE_CODEX_PGID"
	local leader_pid="$ACTIVE_CODEX_PID"
	[[ -n "$pgid" ]] || return 0
	if ! process_group_is_empty "$pgid"; then
		kill -s "$signal_name" -- "-$pgid" 2>/dev/null || true
		if ! wait_for_process_group_exit "$pgid"; then
			kill -KILL -- "-$pgid" 2>/dev/null || true
			wait_for_process_group_exit "$pgid" || return 1
		fi
	fi
	[[ -z "$leader_pid" ]] || wait "$leader_pid" 2>/dev/null || true
	ACTIVE_CODEX_PID=''
	ACTIVE_CODEX_PGID=''
}

wait_for_helper() {
	local child_status=0
	wait "$ACTIVE_HELPER_PID" || child_status=$?
	ACTIVE_HELPER_PID=''
	return "$child_status"
}

run_registry_quiet() {
	"$REGISTRY_SCRIPT" "$@" >/dev/null &
	ACTIVE_HELPER_PID=$!
	wait_for_helper
}

create_real_child_directory() {
	local parent="$1"
	local name="$2"
	local label="$3"
	local parent_real
	local path
	local resolved
	parent_real="$(cd -P "$parent" 2>/dev/null && pwd -P)" || die "$EXIT_RUNTIME_STATE" "cannot resolve $label parent directory: $parent."
	path="$parent/$name"
	[[ ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "$label must be a real directory, not a symlink: $path."
	if [[ ! -e "$path" ]]; then
		if ! mkdir "$path" 2>/dev/null; then
			[[ -d "$path" && ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "cannot create $label: $path."
		fi
	fi
	[[ -d "$path" && ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "$label must be a real directory: $path."
	resolved="$(cd -P "$path" 2>/dev/null && pwd -P)" || die "$EXIT_RUNTIME_STATE" "cannot resolve $label: $path."
	[[ "$resolved" == "$parent_real/$name" ]] || die "$EXIT_RUNTIME_STATE" "$label resolved outside its parent: $path -> $resolved."
	chmod 0700 "$resolved" || die "$EXIT_RUNTIME_STATE" "cannot restrict $label permissions: $resolved."
	printf '%s\n' "$resolved"
}

require_real_child_directory() {
	local parent="$1"
	local name="$2"
	local label="$3"
	local parent_real
	local path
	local resolved
	parent_real="$(cd -P "$parent" 2>/dev/null && pwd -P)" || die "$EXIT_RUNTIME_STATE" "cannot resolve $label parent directory: $parent."
	path="$parent/$name"
	[[ -d "$path" && ! -L "$path" ]] || die "$EXIT_WORKER" "$label is missing or symlinked: $path."
	resolved="$(cd -P "$path" 2>/dev/null && pwd -P)" || die "$EXIT_RUNTIME_STATE" "cannot resolve $label: $path."
	[[ "$resolved" == "$parent_real/$name" ]] || die "$EXIT_RUNTIME_STATE" "$label resolved outside its parent: $path -> $resolved."
	printf '%s\n' "$resolved"
}

artifact_link_count() {
	local path="$1"
	local count=''
	if count="$(stat -f '%l' "$path" 2>/dev/null)"; then
		:
	elif count="$(stat -c '%h' "$path" 2>/dev/null)"; then
		:
	else
		return 1
	fi
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$count"
}

require_owned_artifact_file() {
	local path="$1"
	local label="$2"
	local link_count=''
	[[ -f "$path" && ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "$label must be a real regular file: $path."
	link_count="$(artifact_link_count "$path")" || die "$EXIT_RUNTIME_STATE" "cannot inspect $label link count: $path."
	[[ "$link_count" -eq 1 ]] || die "$EXIT_RUNTIME_STATE" "$label must have exactly one hard link: $path."
}

create_owned_artifact_file() {
	local path="$1"
	local label="$2"
	[[ ! -e "$path" && ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "$label already exists; refusing to overwrite it: $path."
	if ! (set -o noclobber; : >"$path") 2>/dev/null; then
		die "$EXIT_RUNTIME_STATE" "cannot exclusively create $label: $path."
	fi
	require_owned_artifact_file "$path" "$label"
}

run_gated_codex() {
	local artifact_dir="$1"
	local stream_log="$2"
	local stream_stderr="$3"
	local stdin_path="$4"
	local codex_cwd="$5"
	shift 5
	local gate_path="$artifact_dir/.start-$INVOCATION_TOKEN"
	local parent_pid="$$"
	local child_status=0
	local child_pid
	local child_pgid
	require_owned_artifact_file "$stream_log" 'Codex JSONL artifact'
	require_owned_artifact_file "$stream_stderr" 'Codex stderr artifact'
	rm -f "$gate_path"
	set -m
	(
		export LUNA_WORKER_PROCESS_TOKEN="$INVOCATION_TOKEN"
		cd "$codex_cwd" || exit 126
		while [[ ! -f "$gate_path" ]]; do
			kill -0 "$parent_pid" 2>/dev/null || exit 125
			sleep 0.05
		done
		if [[ -n "$stdin_path" ]]; then
			exec "$@" <"$stdin_path"
		else
			exec "$@" </dev/null
		fi
		) >>"$stream_log" 2>>"$stream_stderr" &
	set +m
	ACTIVE_CODEX_PID=$!
	child_pid="$ACTIVE_CODEX_PID"
	child_pgid="$(ps -p "$child_pid" -o pgid= 2>/dev/null | awk 'NF {print $1; exit}')"
	ACTIVE_CODEX_PGID="$child_pgid"
	if [[ "$child_pgid" != "$child_pid" ]]; then
		kill -TERM "$child_pid" 2>/dev/null || true
		wait "$child_pid" 2>/dev/null || true
		ACTIVE_CODEX_PID=''
		ACTIVE_CODEX_PGID=''
		return 1
	fi
	ACTIVE_TRACKER_STATE="$artifact_dir/.descendants-$INVOCATION_TOKEN.json"
	[[ ! -L "$ACTIVE_TRACKER_STATE" ]] || die "$EXIT_RUNTIME_STATE" "descendant tracker state must not be a symlink: $ACTIVE_TRACKER_STATE."
	[[ ! -e "$ACTIVE_TRACKER_STATE" || -f "$ACTIVE_TRACKER_STATE" ]] || die "$EXIT_RUNTIME_STATE" "descendant tracker state must be a regular file target: $ACTIVE_TRACKER_STATE."
	rm -f "$ACTIVE_TRACKER_STATE"
	monitor_descendant_tree "$child_pid" "$ACTIVE_TRACKER_STATE" &
	ACTIVE_TRACKER_PID=$!
	while [[ ! -s "$ACTIVE_TRACKER_STATE" ]]; do
		kill -0 "$ACTIVE_TRACKER_PID" 2>/dev/null || break
		sleep 0.01
	done
	jq -e '.status == "active"' "$ACTIVE_TRACKER_STATE" >/dev/null 2>&1 || {
		stop_codex_process_group TERM || true
		return 1
	}
	if ! run_registry_quiet record-child --task-id "$TASK_ID" --pgid "$child_pgid" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"; then
		stop_codex_process_group TERM || true
		return 1
	fi
	if ! : >"$gate_path"; then
		stop_codex_process_group TERM || true
		return 1
	fi
	wait "$child_pid" || child_status=$?
	ACTIVE_CODEX_PID=''
	rm -f "$gate_path"
	if ! process_group_is_empty "$child_pgid"; then
		ACTIVE_CODEX_PGID="$child_pgid"
		stop_codex_process_group TERM || return 1
	fi
	stop_tracked_worker_processes TERM || return 1
	require_owned_artifact_file "$stream_log" 'Codex JSONL artifact'
	require_owned_artifact_file "$stream_stderr" 'Codex stderr artifact'
	if ! run_registry_quiet clear-child --task-id "$TASK_ID" --pgid "$child_pgid" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"; then
		ACTIVE_CODEX_PGID=''
		return 1
	fi
	ACTIVE_CODEX_PGID=''
	return "$child_status"
}

trap 'stop_active_child_and_exit INT 130' INT
trap 'stop_active_child_and_exit TERM 143' TERM

extract_session_id() {
	local log_path="$1"
	jq -r 'select(.type == "thread.started") | (.thread_id // .threadId // empty)' "$log_path" 2>/dev/null | head -n 1
}

validate_result() {
	local result_path="$1"
	jq -e '
    type == "object"
    and (.outcome == "completed" or .outcome == "blocked" or .outcome == "needs_parent_action")
    and (.summary | type == "string" and length > 0)
    and (.changedFiles | type == "array" and all(.[]; type == "string"))
    and (.validators | type == "array" and all(.[]; (.command | type == "string") and (.status == "passed" or .status == "failed" or .status == "not_run") and (.evidence | type == "string")))
    and (.unresolved | type == "array" and all(.[]; type == "string"))
    and (if .outcome == "needs_parent_action"
         then (.parentAction | type == "string" and length > 0)
         else .parentAction == null
         end)
  ' "$result_path" >/dev/null
}

resume_task() {
	local artifact_dir="$1"
	local attempt
	local stream_log
	local stream_stderr
	local result_path
	local existing_artifact
	attempt=0
	for existing_artifact in "$artifact_dir"/stream-*.jsonl "$artifact_dir"/stream-*.stderr.log "$artifact_dir"/result-*.json; do
		[[ -e "$existing_artifact" || -L "$existing_artifact" ]] || continue
		require_owned_artifact_file "$existing_artifact" 'existing worker artifact'
		if [[ "${existing_artifact##*/}" =~ ^(stream|result)-([0-9]+)(\.jsonl|\.stderr\.log|\.json)$ ]]; then
			[[ "${BASH_REMATCH[2]}" -le "$attempt" ]] || attempt="${BASH_REMATCH[2]}"
		fi
	done
	attempt=$((attempt + 1))
	stream_log="$artifact_dir/stream-$attempt.jsonl"
	stream_stderr="$artifact_dir/stream-$attempt.stderr.log"
	result_path="$artifact_dir/result-$attempt.json"
	create_owned_artifact_file "$stream_log" 'Codex JSONL artifact'
	create_owned_artifact_file "$stream_stderr" 'Codex stderr artifact'
	create_owned_artifact_file "$result_path" 'worker result artifact'

	local codex_status=0
	run_gated_codex "$artifact_dir" "$stream_log" "$stream_stderr" "$PROMPT_FILE" "$REPO_ROOT" "$CODEX_BIN" exec resume \
		--ignore-user-config \
		-m "$MODEL" \
		-c "model_reasoning_effort=$REASONING_EFFORT" \
		-c "sandbox_mode=\"$TASK_SANDBOX\"" \
		--json \
		--output-schema "$RESULT_SCHEMA" \
		--output-last-message "$result_path" \
		-- "$SESSION_ID" - || codex_status=$?
	if [[ "$codex_status" -ne 0 ]]; then
		die "$EXIT_WORKER" "Codex resume failed for task $TASK_ID. Logs: $stream_log and $stream_stderr"
	fi
	validate_result "$result_path" || die "$EXIT_WORKER" "worker returned invalid structured output: $result_path."
	require_owned_artifact_file "$result_path" 'worker result artifact'

	local outcome
	local evidence
	outcome="$(jq -r '.outcome' "$result_path")"
	evidence="$(jq -r '.summary' "$result_path")"
	case "$outcome" in
	completed)
		run_registry_quiet complete-and-retire --task-id "$TASK_ID" --status completed --evidence "$evidence" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
		FINISHED=1
		INVOCATION_CLAIMED=0
		;;
	blocked)
		run_registry_quiet complete-and-retire --task-id "$TASK_ID" --status blocked --evidence "$evidence" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
		FINISHED=1
		INVOCATION_CLAIMED=0
		;;
	needs_parent_action)
		run_registry_quiet checkpoint --task-id "$TASK_ID" --evidence "$evidence" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
		release_invocation
		FINISHED=1
		;;
	esac
	cat "$result_path"
	printf '\nWorker artifacts: %s\n' "$artifact_dir" >&2
}

launch_worker() {
	[[ -n "$SCOPE" ]] || die "$EXIT_USAGE" 'launch requires non-empty --scope.'
	validate_common
	local registry_path
	registry_path="$($REGISTRY_SCRIPT init --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" --print-path)"
	prepare_invocation
	trap finish_on_error EXIT
	local reserve_args=(reserve --task-id "$TASK_ID" --scope "$SCOPE" --pid "$$" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT")
	[[ -z "$RETRY_OF" ]] || reserve_args+=(--retry-of "$RETRY_OF")
	[[ -z "$TASK_SANDBOX" ]] || reserve_args+=(--sandbox "$TASK_SANDBOX")
	run_registry_quiet "${reserve_args[@]}"
	INVOCATION_CLAIMED=1
	TASK_SANDBOX="$("$REGISTRY_SCRIPT" query --task-id "$TASK_ID" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" | jq -r '.sandbox')"
	case "$TASK_SANDBOX" in read-only | workspace-write) ;; *) die "$EXIT_RUNTIME_STATE" "registry returned invalid sandbox for task $TASK_ID." ;; esac

	local registry_dir
	local artifact_root
	local artifact_dir
	local launch_log
	local launch_stderr
	registry_dir="$(dirname "$registry_path")"
	artifact_root="$(create_real_child_directory "$registry_dir" artifacts 'artifact root')"
	artifact_dir="$(create_real_child_directory "$artifact_root" "$TASK_ID" 'task artifact directory')"
	launch_log="$artifact_dir/launch.jsonl"
	launch_stderr="$artifact_dir/launch.stderr.log"
	create_owned_artifact_file "$launch_log" 'handshake JSONL artifact'
	create_owned_artifact_file "$launch_stderr" 'handshake stderr artifact'

	local codex_status=0
	run_gated_codex "$artifact_dir" "$launch_log" "$launch_stderr" '' "$REPO_ROOT" "$CODEX_BIN" exec \
		--ignore-user-config \
		-m "$MODEL" \
		-c "model_reasoning_effort=$REASONING_EFFORT" \
		-s "$TASK_SANDBOX" \
		-C "$REPO_ROOT" \
		--json \
		'Handshake only. Do not inspect or modify the repository. Reply exactly READY_TO_BIND.' || codex_status=$?
	if [[ "$codex_status" -ne 0 ]]; then
		SESSION_ID="$(extract_session_id "$launch_log")"
		[[ -z "$SESSION_ID" ]] || run_registry_quiet bind --task-id "$TASK_ID" --session-id "$SESSION_ID" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
		die "$EXIT_WORKER" "Codex handshake failed for task $TASK_ID. Logs: $launch_log and $launch_stderr"
	fi
	SESSION_ID="$(extract_session_id "$launch_log")"
	[[ -n "$SESSION_ID" ]] || die "$EXIT_WORKER" "Codex handshake emitted no thread.started session ID. Log: $launch_log"
	run_registry_quiet bind --task-id "$TASK_ID" --session-id "$SESSION_ID" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
	run_registry_quiet activate --task-id "$TASK_ID" --session-id "$SESSION_ID" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
	resume_task "$artifact_dir"
}

continue_worker() {
	validate_common
	local registry_path
	local registry_dir
	local artifact_root
	local artifact_dir
	local worker
	registry_path="$($REGISTRY_SCRIPT path --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT")"
	registry_dir="$(dirname "$registry_path")"
	artifact_root="$(require_real_child_directory "$registry_dir" artifacts 'artifact root')"
	artifact_dir="$(require_real_child_directory "$artifact_root" "$TASK_ID" 'task artifact directory')"
	trap finish_on_error EXIT
	claim_invocation
	worker="$($REGISTRY_SCRIPT query --task-id "$TASK_ID" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT")"
	SESSION_ID="$(jq -r '.session_id' <<<"$worker")"
	TASK_SANDBOX="$(jq -r '.sandbox' <<<"$worker")"
	case "$TASK_SANDBOX" in read-only | workspace-write) ;; *) die "$EXIT_RUNTIME_STATE" "registry returned invalid sandbox for task $TASK_ID." ;; esac
	resume_task "$artifact_dir"
}

finish_worker() {
	[[ -n "$TASK_ID" && -n "$FINISH_STATUS" && -n "$FINISH_EVIDENCE" ]] || die "$EXIT_USAGE" 'finish requires --task-id, --status, and --evidence.'
	case "$FINISH_STATUS" in failed | blocked | interrupted) ;; *) die "$EXIT_USAGE" 'finish status must be failed, blocked, or interrupted.' ;; esac
	trap finish_on_error EXIT
	claim_invocation
	run_registry_quiet complete-and-retire --task-id "$TASK_ID" --status "$FINISH_STATUS" --evidence "$FINISH_EVIDENCE" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
	FINISHED=1
	INVOCATION_CLAIMED=0
}

[[ $# -gt 0 ]] || usage "$EXIT_USAGE"
case "$1" in launch | continue | finish)
	MODE="$1"
	shift
	;;
--help | -h) usage "$EXIT_OK" ;; esac
FINISH_STATUS=''
FINISH_EVIDENCE=''
while [[ $# -gt 0 ]]; do
	case "$1" in
	--task-id)
		TASK_ID="${2:-}"
		shift 2
		;;
	--scope)
		SCOPE="${2:-}"
		shift 2
		;;
	--retry-of)
		RETRY_OF="${2:-}"
		shift 2
		;;
	--prompt-file)
		PROMPT_FILE="${2:-}"
		shift 2
		;;
	--sandbox)
		TASK_SANDBOX="${2:-}"
		shift 2
		;;
	--repo | -C)
		REPO_INPUT="${2:-}"
		shift 2
		;;
	--state-root)
		STATE_ROOT_INPUT="${2:-}"
		shift 2
		;;
	--status)
		FINISH_STATUS="${2:-}"
		shift 2
		;;
	--evidence)
		FINISH_EVIDENCE="${2:-}"
		shift 2
		;;
	--help | -h) usage "$EXIT_OK" ;;
	*) die "$EXIT_USAGE" "unknown argument: $1." ;;
	esac
done

case "$MODE" in
launch) launch_worker ;;
continue) continue_worker ;;
finish) finish_worker ;;
esac
