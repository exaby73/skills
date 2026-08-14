#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs intentionally use single-quoted $variables.
set -euo pipefail
umask 077

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_CONFLICT=6
readonly EXIT_NOT_FOUND=7
readonly EXIT_LOCK=9
readonly EXIT_FILESYSTEM=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly INIT_SCRIPT="$SCRIPT_DIR/init.sh"

REPO_INPUT='.'
STATE_ROOT_INPUT="${LUNA_REGISTRY_ROOT:-${TMPDIR:-/tmp}/luna-local-review-loop}"
REGISTRY_PATH=''
REGISTRY_DIR=''
LOCK_DIR=''
LOCK_HELD=0
PARSE_SHIFT=0

readonly TRANSITION_SCHEMA_FILTER='
  def nonempty: type == "string" and length > 0;
  . as $root
  | (.schema_version == 2 and .registry == "luna-local-review-loop")
  and (.identity_ledger | type == "array")
  and (.workers | type == "array")
  and all($root.identity_ledger[];
    . as $row
    | (.task_id | nonempty) and (.scope | nonempty)
    and (["reserved", "bound", "active", "retired"] | index($row.status) != null)
    and (if $row.status == "reserved" then $row.session_id == null
         elif $row.status == "bound" or $row.status == "active" then ($row.session_id | nonempty)
         else ($row.terminal_status == "completed" or $row.terminal_status == "failed" or $row.terminal_status == "blocked" or $row.terminal_status == "interrupted")
              and ($row.terminal_evidence | nonempty) and ($row.retired_at | nonempty)
         end)
  )
  and all($root.workers[];
    . as $worker
    | (.task_id | nonempty) and (.scope | nonempty)
      and (.status == "reserved" or .status == "bound" or .status == "active")
      and any($root.identity_ledger[];
        .task_id == $worker.task_id
        and .scope == $worker.scope
        and .session_id == $worker.session_id
        and .status == $worker.status
      )
  )
  and (([$root.identity_ledger[].task_id] | length) == ([$root.identity_ledger[].task_id] | unique | length))
  and (([$root.identity_ledger[] | select(.session_id != null) | .session_id] | length) == ([$root.identity_ledger[] | select(.session_id != null) | .session_id] | unique | length))
'

usage() {
	local exit_code="${1:-0}"
	cat <<'EOF'
Usage:
  registry.sh init|path [--repo PATH] [--state-root PATH]
  registry.sh reserve --task-id ID --scope TEXT [--retry-of ID] [--repo PATH] [--state-root PATH]
  registry.sh bind --task-id ID --session-id ID [--repo PATH] [--state-root PATH]
  registry.sh activate --task-id ID --session-id ID [--repo PATH] [--state-root PATH]
  registry.sh checkpoint --task-id ID --evidence TEXT [--repo PATH] [--state-root PATH]
  registry.sh complete-and-retire --task-id ID --status completed|failed|blocked|interrupted --evidence TEXT [--repo PATH] [--state-root PATH]
  registry.sh query --task-id ID [--repo PATH] [--state-root PATH]
  registry.sh active [--repo PATH] [--state-root PATH]
  registry.sh assert-no-active|assert-empty [--repo PATH] [--state-root PATH]

The durable identity is the Codex session ID. Process handles and outer tool-cell
IDs are transient orchestration details and are never accepted by this registry.
EOF
	exit "$exit_code"
}

die() {
	local exit_code="$1"
	shift
	printf 'luna-local-review-loop: ERROR [%s] %s\n' "$exit_code" "$*" >&2
	exit "$exit_code"
}

now_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
}

release_lock() {
	if [[ "$LOCK_HELD" -eq 1 ]]; then
		rm -f "$LOCK_DIR/pid" 2>/dev/null || true
		rmdir "$LOCK_DIR" 2>/dev/null || true
		LOCK_HELD=0
	fi
}

pid_is_confirmed_nonexistent() {
	local owner_pid="$1"
	local kill_error=''
	local ps_output=''

	if kill_error="$(kill -0 "$owner_pid" 2>&1)"; then
		return 1
	fi
	if ps_output="$(ps -p "$owner_pid" -o pid= 2>/dev/null)" && [[ "$ps_output" == *[![:space:]]* ]]; then
		return 1
	fi
	case "$kill_error" in
	*[Nn]o\ such\ process* | *[Nn]o\ such\ file* | *[Nn]o\ process*) return 0 ;;
	*) return 1 ;;
	esac
}

acquire_lock() {
	local attempt=0
	local owner_pid=''
	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		owner_pid=''
		[[ ! -f "$LOCK_DIR/pid" ]] || IFS= read -r owner_pid <"$LOCK_DIR/pid" || owner_pid=''
		case "$owner_pid" in
		'' | 0 | *[!0-9]*) ;;
		*)
			if pid_is_confirmed_nonexistent "$owner_pid"; then
				rm -f "$LOCK_DIR/pid" 2>/dev/null || true
				if rmdir "$LOCK_DIR" 2>/dev/null; then
					continue
				fi
			fi
			;;
		esac
		attempt=$((attempt + 1))
		[[ "$attempt" -lt 50 ]] || die "$EXIT_LOCK" "registry lock is busy: $LOCK_DIR. Inspect its owner and remove only a confirmed-stale lock."
		sleep 0.1
	done
	LOCK_HELD=1
	printf '%s\n' "$$" >"$LOCK_DIR/pid" || die "$EXIT_FILESYSTEM" "cannot record registry lock owner: $LOCK_DIR/pid."
	trap release_lock EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

resolve_registry() {
	REGISTRY_PATH="$($INIT_SCRIPT --repo "$REPO_INPUT" --state-root "$STATE_ROOT_INPUT" --print-path)" || exit $?
	[[ -n "$REGISTRY_PATH" ]] || die "$EXIT_FILESYSTEM" 'init returned an empty registry path.'
	REGISTRY_DIR="$(dirname "$REGISTRY_PATH")"
	LOCK_DIR="$REGISTRY_DIR/.lock"
}

atomic_write() {
	local filter="$1"
	shift
	local temp_path
	temp_path="$(mktemp "$REGISTRY_DIR/.registry.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create temporary registry in $REGISTRY_DIR."
	if ! jq "$@" "$filter" "$REGISTRY_PATH" >"$temp_path"; then
		rm -f "$temp_path"
		die "$EXIT_FILESYSTEM" 'could not transform registry.'
	fi
	if ! jq -e "$TRANSITION_SCHEMA_FILTER" "$temp_path" >/dev/null 2>&1; then
		rm -f "$temp_path"
		die "$EXIT_FILESYSTEM" 'registry transition failed schema validation; existing registry was preserved.'
	fi
	chmod 0600 "$temp_path" || die "$EXIT_FILESYSTEM" "cannot restrict registry permissions: $temp_path."
	mv "$temp_path" "$REGISTRY_PATH" || die "$EXIT_FILESYSTEM" "cannot publish registry: $REGISTRY_PATH."
}

parse_common() {
	PARSE_SHIFT=0
	case "$1" in
	--repo | -C)
		[[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."
		REPO_INPUT="$2"
		PARSE_SHIFT=2
		return 0
		;;
	--state-root)
		[[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --state-root.'
		STATE_ROOT_INPUT="$2"
		PARSE_SHIFT=2
		return 0
		;;
	esac
	return 1
}

validate_identity() {
	local label="$1"
	local value="$2"
	[[ -n "$value" ]] || die "$EXIT_USAGE" "$label must not be empty."
	case "$value" in
	*[!A-Za-z0-9._:/-]*) die "$EXIT_USAGE" "$label contains unsupported characters: $value." ;;
	esac
}

validate_scope() {
	local scope="$1"
	[[ -n "$scope" ]] || die "$EXIT_USAGE" 'scope must not be empty.'
	case "$scope" in
	*$'\n'* | *$'\r'*) die "$EXIT_USAGE" 'scope must be one line so it can be recovered exactly.' ;;
	esac
}

command_reserve() {
	local task_id=''
	local scope=''
	local retry_of=''
	while [[ $# -gt 0 ]]; do
		if parse_common "$@"; then
			shift "$PARSE_SHIFT"
			continue
		fi
		case "$1" in
		--task-id)
			[[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing task-id.'
			task_id="$2"
			shift 2
			;;
		--scope)
			[[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing scope.'
			scope="$2"
			shift 2
			;;
		--retry-of)
			[[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing retry-of task ID.'
			retry_of="$2"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown reserve argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$scope" ]] || die "$EXIT_USAGE" 'reserve requires non-empty --task-id and --scope.'
	validate_identity 'task-id' "$task_id"
	validate_scope "$scope"
	[[ -z "$retry_of" ]] || validate_identity 'retry-of' "$retry_of"
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" 'all(.identity_ledger[]; .task_id != $task_id)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "task-id is permanently reserved: $task_id."
	if [[ -n "$retry_of" ]]; then
		jq -e --arg retry_of "$retry_of" --arg scope "$scope" '
      any(.identity_ledger[]; .task_id == $retry_of and .scope == $scope and .status == "retired" and (.terminal_status == "failed" or .terminal_status == "interrupted"))
    ' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "retry-of must name a retired failed/interrupted task with the exact same scope: $retry_of."
	else
		jq -e --arg scope "$scope" 'all(.identity_ledger[]; .scope != $scope)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" 'scope is already reserved; use --retry-of with the failed/interrupted task ID to retry the exact scope.'
	fi
	local timestamp
	timestamp="$(now_utc)"
	atomic_write '
    .updated_at = $timestamp
    | .identity_ledger += [{task_id: $task_id, scope: $scope, retry_of: (($retry_of | select(length > 0)) // null), session_id: null, status: "reserved", reserved_at: $timestamp, bound_at: null, activated_at: null, terminal_at: null, retired_at: null, terminal_status: null, terminal_evidence: ""}]
    | .workers += [{task_id: $task_id, scope: $scope, retry_of: (($retry_of | select(length > 0)) // null), session_id: null, status: "reserved", created_at: $timestamp, updated_at: $timestamp, bound_at: null, activated_at: null, checkpoint_evidence: ""}]
  ' --arg task_id "$task_id" --arg scope "$scope" --arg retry_of "${retry_of:-}" --arg timestamp "$timestamp"
	printf 'Reserved task=%s\n' "$task_id"
}

command_bind() {
	local task_id=''
	local session_id=''
	while [[ $# -gt 0 ]]; do
		if parse_common "$@"; then
			shift "$PARSE_SHIFT"
			continue
		fi
		case "$1" in
		--task-id)
			task_id="${2:-}"
			shift 2
			;;
		--session-id)
			session_id="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown bind argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$session_id" ]] || die "$EXIT_USAGE" 'bind requires --task-id and --session-id.'
	validate_identity 'task-id' "$task_id"
	validate_identity 'session-id' "$session_id"
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" 'any(.workers[]; .task_id == $task_id and .status == "reserved" and .session_id == null)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "task is not an unbound reservation: $task_id."
	jq -e --arg session_id "$session_id" 'all(.identity_ledger[]; .session_id != $session_id)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "Codex session is already bound: $session_id."
	local timestamp
	timestamp="$(now_utc)"
	atomic_write '
    .updated_at = $timestamp
    | .identity_ledger |= map(if .task_id == $task_id then .session_id = $session_id | .status = "bound" | .bound_at = $timestamp else . end)
    | .workers |= map(if .task_id == $task_id then .session_id = $session_id | .status = "bound" | .bound_at = $timestamp | .updated_at = $timestamp else . end)
  ' --arg task_id "$task_id" --arg session_id "$session_id" --arg timestamp "$timestamp"
	printf 'Bound task=%s session=%s\n' "$task_id" "$session_id"
}

command_activate() {
	local task_id=''
	local session_id=''
	while [[ $# -gt 0 ]]; do
		if parse_common "$@"; then
			shift "$PARSE_SHIFT"
			continue
		fi
		case "$1" in
		--task-id)
			task_id="${2:-}"
			shift 2
			;;
		--session-id)
			session_id="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown activate argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$session_id" ]] || die "$EXIT_USAGE" 'activate requires --task-id and --session-id.'
	validate_identity 'task-id' "$task_id"
	validate_identity 'session-id' "$session_id"
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" --arg session_id "$session_id" 'any(.workers[]; .task_id == $task_id and .session_id == $session_id and .status == "bound")' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" 'activation requires the exact bound task and Codex session.'
	local timestamp
	timestamp="$(now_utc)"
	atomic_write '
    .updated_at = $timestamp
    | .identity_ledger |= map(if .task_id == $task_id then .status = "active" | .activated_at = $timestamp else . end)
    | .workers |= map(if .task_id == $task_id then .status = "active" | .activated_at = $timestamp | .updated_at = $timestamp else . end)
  ' --arg task_id "$task_id" --arg timestamp "$timestamp"
	printf 'Activated task=%s session=%s\n' "$task_id" "$session_id"
}

command_checkpoint() {
	local task_id=''
	local evidence=''
	while [[ $# -gt 0 ]]; do
		if parse_common "$@"; then
			shift "$PARSE_SHIFT"
			continue
		fi
		case "$1" in
		--task-id)
			task_id="${2:-}"
			shift 2
			;;
		--evidence)
			evidence="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown checkpoint argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$evidence" ]] || die "$EXIT_USAGE" 'checkpoint requires --task-id and non-empty --evidence.'
	validate_identity 'task-id' "$task_id"
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" 'any(.workers[]; .task_id == $task_id and .status == "active")' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "checkpoint requires an active task: $task_id."
	local timestamp
	timestamp="$(now_utc)"
	atomic_write '.updated_at = $timestamp | .workers |= map(if .task_id == $task_id then .checkpoint_evidence = $evidence | .updated_at = $timestamp else . end)' --arg task_id "$task_id" --arg evidence "$evidence" --arg timestamp "$timestamp"
	printf 'Checkpointed task=%s\n' "$task_id"
}

command_complete_and_retire() {
	local task_id=''
	local status=''
	local evidence=''
	while [[ $# -gt 0 ]]; do
		if parse_common "$@"; then
			shift "$PARSE_SHIFT"
			continue
		fi
		case "$1" in
		--task-id)
			task_id="${2:-}"
			shift 2
			;;
		--status)
			status="${2:-}"
			shift 2
			;;
		--evidence)
			evidence="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown complete-and-retire argument: $1." ;;
		esac
	done
	case "$status" in completed | failed | blocked | interrupted) ;; *) die "$EXIT_USAGE" 'terminal status must be completed, failed, blocked, or interrupted.' ;; esac
	[[ -n "$task_id" && -n "$evidence" ]] || die "$EXIT_USAGE" 'complete-and-retire requires --task-id, --status, and non-empty --evidence.'
	validate_identity 'task-id' "$task_id"
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" 'any(.workers[]; .task_id == $task_id)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_NOT_FOUND" "live task not found: $task_id."
	local timestamp
	timestamp="$(now_utc)"
	atomic_write '
    .updated_at = $timestamp
    | .identity_ledger |= map(if .task_id == $task_id then .status = "retired" | .terminal_status = $status | .terminal_evidence = $evidence | .terminal_at = $timestamp | .retired_at = $timestamp else . end)
    | .workers |= map(select(.task_id != $task_id))
  ' --arg task_id "$task_id" --arg status "$status" --arg evidence "$evidence" --arg timestamp "$timestamp"
	printf 'Completed and retired task=%s status=%s\n' "$task_id" "$status"
}

parse_read_args() {
	local mode="$1"
	shift
	local task_id=''
	while [[ $# -gt 0 ]]; do
		if parse_common "$@"; then
			shift "$PARSE_SHIFT"
			continue
		fi
		case "$1" in
		--task-id)
			task_id="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown $mode argument: $1." ;;
		esac
	done
	resolve_registry
	case "$mode" in
	query)
		[[ -n "$task_id" ]] || die "$EXIT_USAGE" 'query requires --task-id.'
		validate_identity 'task-id' "$task_id"
		jq -e --arg task_id "$task_id" '.identity_ledger[] | select(.task_id == $task_id)' "$REGISTRY_PATH" || die "$EXIT_NOT_FOUND" "task not found: $task_id."
		;;
	active) jq '.workers' "$REGISTRY_PATH" ;;
	assert-no-active | assert-empty)
		jq -e '.workers | length == 0' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" 'registry still contains a reserved, bound, or active worker.'
		printf 'Registry has no live workers.\n'
		;;
	esac
}

[[ $# -gt 0 ]] || usage "$EXIT_USAGE"
command="$1"
shift
case "$command" in
--help | -h) usage "$EXIT_OK" ;;
init)
	exec "$INIT_SCRIPT" "$@"
	;;
path)
	exec "$INIT_SCRIPT" "$@" --print-path
	;;
reserve) command_reserve "$@" ;;
bind) command_bind "$@" ;;
activate) command_activate "$@" ;;
checkpoint) command_checkpoint "$@" ;;
complete-and-retire) command_complete_and_retire "$@" ;;
query | active | assert-no-active | assert-empty) parse_read_args "$command" "$@" ;;
*) die "$EXIT_USAGE" "unknown command: $command. Use --help for usage." ;;
esac
