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
	command -v "$CODEX_BIN" >/dev/null 2>&1 || die "$EXIT_PREREQUISITE" "Codex CLI not found: $CODEX_BIN."
	[[ -f "$RESULT_SCHEMA" ]] || die "$EXIT_PREREQUISITE" "worker result schema not found: $RESULT_SCHEMA."
	[[ "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "$EXIT_USAGE" 'task-id must contain only letters, numbers, dot, underscore, or hyphen.'
	[[ -f "$PROMPT_FILE" && ! -L "$PROMPT_FILE" ]] || die "$EXIT_USAGE" "prompt-file must be a regular non-symlink file: $PROMPT_FILE."
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
	ACTIVE_HELPER_PID=''
	ACTIVE_CODEX_PID=''
	ACTIVE_CODEX_PGID=''
	exit "$exit_code"
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

run_gated_codex() {
	local artifact_dir="$1"
	local stream_log="$2"
	local stream_stderr="$3"
	local stdin_path="$4"
	shift 4
	local gate_path="$artifact_dir/.start-$INVOCATION_TOKEN"
	local parent_pid="$$"
	local child_status=0
	local child_pid
	local child_pgid
	rm -f "$gate_path"
	set -m
	(
		while [[ ! -f "$gate_path" ]]; do
			kill -0 "$parent_pid" 2>/dev/null || exit 125
			sleep 0.05
		done
		if [[ -n "$stdin_path" ]]; then
			exec "$@" <"$stdin_path"
		else
			exec "$@" </dev/null
		fi
	) >"$stream_log" 2>"$stream_stderr" &
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
	local existing_stream
	attempt=0
	for existing_stream in "$artifact_dir"/stream-*.jsonl; do
		[[ -f "$existing_stream" ]] || continue
		attempt=$((attempt + 1))
	done
	attempt=$((attempt + 1))
	stream_log="$artifact_dir/stream-$attempt.jsonl"
	stream_stderr="$artifact_dir/stream-$attempt.stderr.log"
	result_path="$artifact_dir/result-$attempt.json"

	local codex_status=0
	run_gated_codex "$artifact_dir" "$stream_log" "$stream_stderr" "$PROMPT_FILE" "$CODEX_BIN" exec resume \
		--ignore-user-config \
		-m "$MODEL" \
		-c "model_reasoning_effort=$REASONING_EFFORT" \
		--json \
		--output-schema "$RESULT_SCHEMA" \
		--output-last-message "$result_path" \
		"$SESSION_ID" - || codex_status=$?
	if [[ "$codex_status" -ne 0 ]]; then
		die "$EXIT_WORKER" "Codex resume failed for task $TASK_ID. Logs: $stream_log and $stream_stderr"
	fi
	validate_result "$result_path" || die "$EXIT_WORKER" "worker returned invalid structured output: $result_path."

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

	local codex_status=0
	run_gated_codex "$artifact_dir" "$launch_log" "$launch_stderr" '' "$CODEX_BIN" exec \
		--ignore-user-config \
		-m "$MODEL" \
		-c "model_reasoning_effort=$REASONING_EFFORT" \
		-s "$TASK_SANDBOX" \
		-C "$REPO_INPUT" \
		--json \
		'Handshake only. Do not inspect or modify the repository. Reply exactly READY_TO_BIND.' || codex_status=$?
	if [[ "$codex_status" -ne 0 ]]; then
		SESSION_ID="$(extract_session_id "$launch_log")"
		[[ -z "$SESSION_ID" ]] || run_registry_quiet bind --task-id "$TASK_ID" --session-id "$SESSION_ID" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
		die "$EXIT_WORKER" "Codex handshake failed for task $TASK_ID. Logs: $launch_log and $launch_stderr"
	fi
	SESSION_ID="$(extract_session_id "$launch_log")"
	[[ -n "$SESSION_ID" ]] || die "$EXIT_WORKER" "Codex handshake emitted no thread.started session ID. Log: $launch_log"
	run_registry_quiet bind --task-id "$TASK_ID" --session-id "$SESSION_ID" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
	run_registry_quiet activate --task-id "$TASK_ID" --session-id "$SESSION_ID" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
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
