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
TASK_SANDBOX='workspace-write'
MODEL='gpt-5.6-luna'
REASONING_EFFORT='max'
CODEX_BIN="${CODEX_BIN:-codex}"
FINISHED=0
SESSION_ID=''

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
	case "$TASK_SANDBOX" in read-only | workspace-write) ;; *) die "$EXIT_USAGE" 'sandbox must be read-only or workspace-write.' ;; esac
	runtime_state_is_writable
}

finish_on_error() {
	local exit_code=$?
	if [[ "$FINISHED" -eq 0 && -n "$TASK_ID" ]]; then
		"$REGISTRY_SCRIPT" complete-and-retire --task-id "$TASK_ID" --status failed --evidence "worker launcher exited $exit_code before a structured terminal result" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" >/dev/null 2>&1 || true
	fi
	exit "$exit_code"
}

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
    and ((.parentAction == null) or (.parentAction | type == "string"))
  ' "$result_path" >/dev/null
}

resume_task() {
	local artifact_dir="$1"
	local attempt
	local stream_log
	local result_path
	attempt="$(find "$artifact_dir" -maxdepth 1 -type f -name 'stream-*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
	attempt=$((attempt + 1))
	stream_log="$artifact_dir/stream-$attempt.jsonl"
	result_path="$artifact_dir/result-$attempt.json"

	if ! "$CODEX_BIN" exec resume \
		--ignore-user-config \
		-m "$MODEL" \
		-c "model_reasoning_effort=$REASONING_EFFORT" \
		--json \
		--output-schema "$RESULT_SCHEMA" \
		--output-last-message "$result_path" \
		"$SESSION_ID" - <"$PROMPT_FILE" >"$stream_log" 2>&1; then
		die "$EXIT_WORKER" "Codex resume failed for task $TASK_ID. Streaming log: $stream_log"
	fi
	validate_result "$result_path" || die "$EXIT_WORKER" "worker returned invalid structured output: $result_path."

	local outcome
	local evidence
	outcome="$(jq -r '.outcome' "$result_path")"
	evidence="$(jq -r '.summary' "$result_path")"
	case "$outcome" in
	completed)
		"$REGISTRY_SCRIPT" complete-and-retire --task-id "$TASK_ID" --status completed --evidence "$evidence" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" >/dev/null
		FINISHED=1
		;;
	blocked)
		"$REGISTRY_SCRIPT" complete-and-retire --task-id "$TASK_ID" --status blocked --evidence "$evidence" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" >/dev/null
		FINISHED=1
		;;
	needs_parent_action)
		"$REGISTRY_SCRIPT" checkpoint --task-id "$TASK_ID" --evidence "$evidence" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" >/dev/null
		FINISHED=1
		;;
	esac
	cat "$result_path"
	printf '\nWorker artifacts: %s\n' "$artifact_dir" >&2
}

launch_worker() {
	[[ -n "$SCOPE" ]] || die "$EXIT_USAGE" 'launch requires non-empty --scope.'
	validate_common
	local reserve_args=(reserve --task-id "$TASK_ID" --scope "$SCOPE" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT")
	[[ -z "$RETRY_OF" ]] || reserve_args+=(--retry-of "$RETRY_OF")
	"$REGISTRY_SCRIPT" "${reserve_args[@]}" >/dev/null
	trap finish_on_error EXIT

	local registry_path
	local registry_dir
	local artifact_dir
	local launch_log
	registry_path="$($REGISTRY_SCRIPT path --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT")"
	registry_dir="$(dirname "$registry_path")"
	artifact_dir="$registry_dir/artifacts/$TASK_ID"
	mkdir -p "$artifact_dir"
	chmod 0700 "$registry_dir/artifacts" "$artifact_dir" 2>/dev/null || true
	launch_log="$artifact_dir/launch.jsonl"

	if ! "$CODEX_BIN" exec \
		--ignore-user-config \
		-m "$MODEL" \
		-c "model_reasoning_effort=$REASONING_EFFORT" \
		-s "$TASK_SANDBOX" \
		-C "$REPO_INPUT" \
		--json \
		'Handshake only. Do not inspect or modify the repository. Reply exactly READY_TO_BIND.' >"$launch_log" 2>&1; then
		SESSION_ID="$(extract_session_id "$launch_log")"
		[[ -z "$SESSION_ID" ]] || "$REGISTRY_SCRIPT" bind --task-id "$TASK_ID" --session-id "$SESSION_ID" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" >/dev/null
		die "$EXIT_WORKER" "Codex handshake failed for task $TASK_ID. Log: $launch_log"
	fi
	SESSION_ID="$(extract_session_id "$launch_log")"
	[[ -n "$SESSION_ID" ]] || die "$EXIT_WORKER" "Codex handshake emitted no thread.started session ID. Log: $launch_log"
	"$REGISTRY_SCRIPT" bind --task-id "$TASK_ID" --session-id "$SESSION_ID" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" >/dev/null
	"$REGISTRY_SCRIPT" activate --task-id "$TASK_ID" --session-id "$SESSION_ID" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" >/dev/null
	resume_task "$artifact_dir"
}

continue_worker() {
	validate_common
	local registry_path
	local registry_dir
	local artifact_dir
	local worker
	registry_path="$($REGISTRY_SCRIPT path --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT")"
	worker="$($REGISTRY_SCRIPT query --task-id "$TASK_ID" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT")"
	[[ "$(jq -r '.status' <<<"$worker")" == active ]] || die "$EXIT_WORKER" "continue requires an active registered task: $TASK_ID."
	SESSION_ID="$(jq -r '.session_id' <<<"$worker")"
	registry_dir="$(dirname "$registry_path")"
	artifact_dir="$registry_dir/artifacts/$TASK_ID"
	[[ -d "$artifact_dir" ]] || die "$EXIT_WORKER" "worker artifact directory is missing: $artifact_dir."
	trap finish_on_error EXIT
	resume_task "$artifact_dir"
}

finish_worker() {
	[[ -n "$TASK_ID" && -n "$FINISH_STATUS" && -n "$FINISH_EVIDENCE" ]] || die "$EXIT_USAGE" 'finish requires --task-id, --status, and --evidence.'
	"$REGISTRY_SCRIPT" complete-and-retire --task-id "$TASK_ID" --status "$FINISH_STATUS" --evidence "$FINISH_EVIDENCE" --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT"
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
