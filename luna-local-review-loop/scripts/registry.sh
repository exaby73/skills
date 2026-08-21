#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC1091 # jq uses literal variables; sourced lock helpers consume shared globals.
set -euo pipefail
umask 077

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_CONFLICT=6
readonly EXIT_NOT_FOUND=7
readonly EXIT_LOCK=9
readonly EXIT_FILESYSTEM=10

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR='.'
[[ -n "$SCRIPT_DIR" ]] || SCRIPT_DIR='/'
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd -P)"
readonly SCRIPT_DIR
readonly INIT_SCRIPT="$SCRIPT_DIR/init.sh"

REPO_INPUT='.'
REGISTRY_PATH=''
REGISTRY_DIR=''
LOCK_DIR=''
LOCK_HELD=0
PARSE_SHIFT=0
PREFLIGHT_READY_FILE=''
PREFLIGHT_RELEASE_FILE=''
PREFLIGHT_ERROR_FILE=''
PREFLIGHT_READY_TOKEN=''
PREFLIGHT_RELEASE_TOKEN=''
PREFLIGHT_PARENT_PID=''
PREFLIGHT_PARENT_INSTANCE=''

readonly TRANSITION_SCHEMA_FILTER='
  def nonempty: type == "string" and length > 0;
  def safe_scope: type == "string" and length > 0 and (test("[\\r\\n]") | not);
  def safe_identity: type == "string" and test("^[A-Za-z0-9._:/-]+$");
  def safe_task_id: type == "string" and test("^[A-Za-z0-9._-]+$") and . != "." and . != "..";
  def safe_session: type == "string" and length > 0 and (startswith("-") | not);
  def positive_pid: type == "string" and test("^[1-9][0-9]*$");
  def process_instance: type == "string" and test("^(proc:[0-9]+|ps:[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4})$");
  def valid_retry_chain($ledger):
    all($ledger | to_entries[];
      . as $entry
      | $entry.value as $row
      | if $row.retry_of == null then true
        else any($ledger | to_entries[];
          .key < $entry.key
          and .value.task_id == $row.retry_of
          and .value.scope == $row.scope
          and .value.sandbox == $row.sandbox
          and .value.status == "retired"
          and (.value.terminal_status == "failed" or .value.terminal_status == "blocked" or .value.terminal_status == "interrupted")
        )
        end
    );
  . as $root
  | (.schema_version == 3 and .registry == "luna-local-review-loop")
  and (.repository_root | nonempty)
  and (.repository_identity | nonempty)
  and (.repository_checkout_identity | type == "string" and test("^gitdir:[0-9]+:[0-9]+:seal:[0-9a-f]{64}:seal-file:[0-9]+:[0-9]+$"))
  and (.identity_ledger | type == "array")
  and (.workers | type == "array")
  and all($root.identity_ledger[];
    . as $row
    | (.task_id | safe_task_id) and (.scope | safe_scope)
    and (($row.retry_of == null) or ($row.retry_of | safe_task_id))
    and ($row.sandbox == "read-only" or $row.sandbox == "workspace-write")
    and (["reserved", "bound", "active", "retired"] | index($row.status) != null)
    and (if $row.status == "reserved" then $row.session_id == null
         elif $row.status == "bound" or $row.status == "active" then ($row.session_id | safe_session)
         else ($row.terminal_status == "completed" or $row.terminal_status == "failed" or $row.terminal_status == "blocked" or $row.terminal_status == "interrupted")
              and ($row.terminal_evidence | nonempty) and ($row.retired_at | nonempty)
         end)
  )
  and all($root.workers[];
    . as $worker
    | (.task_id | safe_task_id) and (.scope | safe_scope)
      and ($worker.sandbox == "read-only" or $worker.sandbox == "workspace-write")
      and (($worker.retry_of == null) or ($worker.retry_of | safe_task_id))
      and (.status == "reserved" or .status == "bound" or .status == "active")
      and (($worker.invocation_pid == null and $worker.invocation_token == null and $worker.invocation_instance == null)
           or (($worker.invocation_pid | positive_pid) and ($worker.invocation_token | safe_identity) and ($worker.invocation_instance | process_instance)))
      and (($worker.active_child_pgid == null and $worker.active_child_instance == null)
           or (($worker.active_child_pgid | positive_pid) and ($worker.active_child_instance | process_instance) and ($worker.invocation_pid | positive_pid) and ($worker.invocation_token | safe_identity) and ($worker.invocation_instance | process_instance)))
      and any($root.identity_ledger[];
        .task_id == $worker.task_id
        and .scope == $worker.scope
        and .sandbox == $worker.sandbox
        and .session_id == $worker.session_id
        and .status == $worker.status
      )
  )
  and all($root.identity_ledger[];
    . as $row
    | if .status == "retired" then true
      else any($root.workers[];
        .task_id == $row.task_id
        and .scope == $row.scope
        and .sandbox == $row.sandbox
        and .session_id == $row.session_id
        and .status == $row.status
      )
      end
  )
  and (([$root.identity_ledger[].task_id] | length) == ([$root.identity_ledger[].task_id] | unique | length))
  and (([$root.workers[].scope] | length) == ([$root.workers[].scope] | unique | length))
  and (([$root.identity_ledger[] | select(.session_id != null) | .session_id] | length) == ([$root.identity_ledger[] | select(.session_id != null) | .session_id] | unique | length))
  and (([$root.identity_ledger[] | select(.retry_of != null) | .retry_of] | length) == ([$root.identity_ledger[] | select(.retry_of != null) | .retry_of] | unique | length))
  and (([$root.identity_ledger[] | select(.retry_of == null) | .scope] | length) == ([$root.identity_ledger[] | select(.retry_of == null) | .scope] | unique | length))
  and valid_retry_chain($root.identity_ledger)
'

usage() {
	local exit_code="${1:-0}"
	cat <<'EOF'
Usage:
  registry.sh init|path|preflight [--repo PATH]
  registry.sh preflight-lock --repo PATH --ready-file PATH --release-file PATH --parent-pid PID --parent-instance INSTANCE
  registry.sh reserve --task-id ID --scope TEXT [--retry-of ID] [--sandbox read-only|workspace-write] [--pid PID --token TOKEN] [--repo PATH]
  registry.sh bind --task-id ID --session-id ID [--invocation-token TOKEN] [--repo PATH]
  registry.sh activate --task-id ID --session-id ID [--invocation-token TOKEN] [--repo PATH]
  registry.sh checkpoint --task-id ID --evidence TEXT [--repo PATH]
  registry.sh claim-invocation --task-id ID --pid PID --token TOKEN [--require-status active] [--repo PATH]
  registry.sh release-invocation --task-id ID --token TOKEN [--repo PATH]
  registry.sh record-child --task-id ID --pgid PGID --token TOKEN [--repo PATH]
  registry.sh clear-child --task-id ID --pgid PGID --token TOKEN [--repo PATH]
  registry.sh complete-and-retire --task-id ID --status completed|failed|blocked|interrupted --evidence TEXT [--invocation-token TOKEN] [--repo PATH]
  registry.sh query --task-id ID [--repo PATH]
  registry.sh active [--repo PATH]
  registry.sh assert-no-active|assert-empty [--repo PATH]

The durable identity is the Codex session ID. Process handles and outer tool-cell
IDs are transient orchestration details and are never accepted by this registry.
Exact-scope retries may name retired failed, blocked, or interrupted attempts;
the retry inherits or matches the parent sandbox. Registry state is always under
the canonical repository's .agents/agent-registry boundary.
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

pid_is_confirmed_nonexistent() {
	local owner_pid="$1"
	local kill_error=''
	local process_state=''

	if process_state="$(ps -p "$owner_pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"; then
		case "$process_state" in
		Z* | '') return 0 ;;
		?*) return 1 ;;
		esac
	fi
	if kill_error="$(LC_ALL=C kill -0 "$owner_pid" 2>&1)"; then
		return 1
	fi
	case "$kill_error" in
	*[Nn]o\ such\ process* | *[Nn]o\ such\ file* | *[Nn]o\ process*) return 0 ;;
	*) return 1 ;;
	esac
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

recorded_process_instance_blocks_recovery() {
	local pid="$1"
	local expected="$2"
	local current=''
	local process_state=''
	[[ -n "$expected" ]] || return 0
	if ! current="$(process_instance_identity "$pid")"; then
		pid_is_confirmed_nonexistent "$pid" && return 1
		return 0
	fi
	[[ "$current" == "$expected" ]] || return 1
	if ! process_state="$(ps -p "$pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"; then
		pid_is_confirmed_nonexistent "$pid" && return 1
		return 0
	fi
	case "$process_state" in
	Z*) return 1 ;;
	'') pid_is_confirmed_nonexistent "$pid" && return 1 ;;
	esac
	return 0
}

process_group_is_confirmed_empty() {
	local pgid="$1"
	local live_count=''
	case "$pgid" in '' | 0 | *[!0-9]*) return 1 ;; esac
	live_count="$(ps -ax -o pgid=,stat= 2>/dev/null | awk -v target="$pgid" '$1 == target && $2 !~ /^Z/ {count++} END {print count + 0}')" || return 1
	[[ "$live_count" -eq 0 ]]
}

recorded_process_group_blocks_recovery() {
	local pgid="$1"
	local expected_instance="$2"
	local current_instance=''
	[[ -n "$expected_instance" ]] || return 0
	if ! current_instance="$(process_instance_identity "$pgid")"; then
		pid_is_confirmed_nonexistent "$pgid" && return 1
		return 0
	fi
	[[ "$current_instance" == "$expected_instance" ]] || return 1
	process_group_is_confirmed_empty "$pgid" && return 1
	return 0
}

require_invocation_authority() {
	local task_id="$1"
	local provided_token="$2"
	local owner_pid=''
	local owner_token=''
	local owner_instance=''
	owner_pid="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .invocation_pid // empty' "$REGISTRY_PATH")"
	owner_token="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .invocation_token // empty' "$REGISTRY_PATH")"
	owner_instance="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .invocation_instance // empty' "$REGISTRY_PATH")"
	if [[ -z "$owner_token" ]]; then
		[[ -z "$provided_token" ]] || die "$EXIT_CONFLICT" "task has no invocation owner for the supplied token: $task_id."
		return 0
	fi
	if [[ -n "$provided_token" ]]; then
		[[ "$provided_token" == "$owner_token" ]] || die "$EXIT_CONFLICT" "invocation token does not own task: $task_id."
		return 0
	fi
	if [[ -z "$owner_pid" ]] || recorded_process_instance_blocks_recovery "$owner_pid" "$owner_instance"; then
		die "$EXIT_CONFLICT" "task has a live invocation owner; supply its exact token: $task_id."
	fi
}

descendant_state_path() {
	local task_id="$1"
	local token="$2"
	printf '%s/artifacts/%s/.descendants-%s.json\n' "$REGISTRY_DIR" "$task_id" "$token"
}

descendant_state_is_confirmed_clean() {
	local task_id="$1"
	local token="$2"
	local expected_root_pid="${3:-}"
	local state_path
	state_path="$(descendant_state_path "$task_id" "$token")"
	[[ -f "$state_path" && ! -L "$state_path" ]] || return 1
	if [[ -n "$expected_root_pid" ]]; then
		case "$expected_root_pid" in '' | 0 | *[!0-9]*) return 1 ;; esac
		jq -e --argjson expected_root_pid "$expected_root_pid" '
		    .status == "clean"
		    and .root_pid == $expected_root_pid
		    and .processes == []
		  ' "$state_path" >/dev/null 2>&1
		return
	fi
	jq -e '
	    .status == "clean"
	    and (.root_pid | type == "number" and . > 0 and floor == .)
	    and .processes == []
	  ' "$state_path" >/dev/null 2>&1
}

# shellcheck source=registry-lock.sh
source "$SCRIPT_DIR/registry-lock.sh"

resolve_registry() {
	REGISTRY_PATH="$($INIT_SCRIPT --repo "$REPO_INPUT" --existing-path)" || exit $?
	[[ -n "$REGISTRY_PATH" ]] || die "$EXIT_FILESYSTEM" 'init returned an empty registry path.'
	REGISTRY_DIR="$(dirname "$REGISTRY_PATH")"
	LOCK_DIR="$REGISTRY_DIR/.lock"
}

resolve_preflight_registry() {
	local repo_candidate=''
	local repo_root=''
	[[ -d "$REPO_INPUT" ]] || die "$EXIT_USAGE" "repository path is not a directory: $REPO_INPUT."
	repo_candidate="$(cd -P "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve repository path: $REPO_INPUT."
	repo_root="$(git -C "$repo_candidate" rev-parse --show-toplevel 2>/dev/null)" || die "$EXIT_USAGE" "repository path is not inside a Git repository: $REPO_INPUT."
	repo_root="$(cd -P "$repo_root" 2>/dev/null && pwd -P)" || die "$EXIT_FILESYSTEM" 'cannot resolve Git checkout root.'
	case "$repo_candidate" in
	"$repo_root" | "$repo_root"/*) ;;
	*) die "$EXIT_USAGE" "Git recorded a different checkout root than the supplied path: $repo_candidate -> $repo_root." ;;
	esac
	REGISTRY_DIR="$repo_root/.agents/agent-registry"
	REGISTRY_PATH="$REGISTRY_DIR/registry.json"
	LOCK_DIR="$REGISTRY_DIR/.lock"
}

preflight_control_file_is_private() {
	local path="$1"
	local owner=''
	local mode=''
	local links=''
	if owner="$(stat -c '%u' "$path" 2>/dev/null)"; then :
	elif owner="$(stat -f '%u' "$path" 2>/dev/null)"; then :
	else return 1; fi
	if mode="$(stat -c '%a' "$path" 2>/dev/null)"; then :
	elif mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then :
	else return 1; fi
	if links="$(stat -c '%h' "$path" 2>/dev/null)"; then :
	elif links="$(stat -f '%l' "$path" 2>/dev/null)"; then :
	else return 1; fi
	[[ "$owner" == "$UID" && "$mode" == 600 && "$links" == 1 ]]
}

preflight_control_state_read() {
	local path="$1"
	local state=''
	preflight_control_file_is_private "$path" || return 1
	exec 8<"$path" || return 1
	if ! IFS= read -r state <&8; then
		exec 8<&-
		return 1
	fi
	if IFS= read -r <&8; then
		exec 8<&-
		return 1
	fi
	exec 8<&-
	printf '%s\n' "$state"
}

preflight_control_state_is_valid() {
	local path="$1"
	local expected="$2"
	local state=''
	state="$(preflight_control_state_read "$path")" || return 1
	[[ "$state" == "$expected" ]]
}

preflight_parent_is_live() {
	local parent_pid="$1"
	local parent_instance="$2"
	local current_instance=''
	local process_state=''
	local process_owner=''
	process_owner="$(ps -p "$parent_pid" -o uid= 2>/dev/null | awk 'NF {print $1; exit}')" || return 1
	[[ "$process_owner" == "$UID" ]] || return 1
	current_instance="$(process_instance_identity "$parent_pid" 2>/dev/null)" || return 1
	[[ "$current_instance" == "$parent_instance" ]] || return 1
	process_state="$(ps -p "$parent_pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"
	case "$process_state" in '' | Z*) return 1 ;; esac
}

publish_preflight_ready() {
	local ready_value="$1"
	local ready_parent=''
	local temp_path=''
	ready_parent="${PREFLIGHT_READY_FILE%/*}"
	temp_path="$(mktemp "$ready_parent/.registry-preflight-ready.XXXXXX")" || return 1
	if ! printf '%s:%s\n' "$ready_value" "$PREFLIGHT_READY_TOKEN" >"$temp_path" || ! chmod 0600 "$temp_path" || ! preflight_control_file_is_private "$temp_path"; then
		rm -f "$temp_path"
		return 1
	fi
	if ! mv -f "$temp_path" "$PREFLIGHT_READY_FILE"; then
		rm -f "$temp_path"
		return 1
	fi
	preflight_control_state_is_valid "$PREFLIGHT_READY_FILE" "$ready_value:$PREFLIGHT_READY_TOKEN"
}

remove_preflight_control_file() {
	local path="$1"
	[[ -n "$path" ]] || return 0
	if [[ ! -e "$path" && ! -L "$path" ]]; then
		return 0
	fi
	preflight_control_file_is_private "$path" || return 1
	rm "$path" || return 1
	[[ ! -e "$path" && ! -L "$path" ]]
}

release_preflight_lock_checked() {
	local lock_was_held="$LOCK_HELD"
	release_lock
	if [[ "$lock_was_held" -eq 1 && ( -e "$LOCK_DIR" || -L "$LOCK_DIR" ) ]]; then
		return 1
	fi
	return 0
}

preflight_lock_cleanup() {
	local exit_code=$?
	local cleanup_status=0
	local parent_live=0
	trap - EXIT
	if preflight_parent_is_live "$PREFLIGHT_PARENT_PID" "$PREFLIGHT_PARENT_INSTANCE"; then
		parent_live=1
	fi
	release_preflight_lock_checked || cleanup_status=1
	if [[ "$parent_live" -eq 0 ]]; then
		remove_preflight_control_file "$PREFLIGHT_READY_FILE" || cleanup_status=1
		remove_preflight_control_file "$PREFLIGHT_RELEASE_FILE" || cleanup_status=1
		remove_preflight_control_file "$PREFLIGHT_ERROR_FILE" || cleanup_status=1
	fi
	if [[ -n "$PREFLIGHT_ERROR_FILE" && -f "$PREFLIGHT_ERROR_FILE" && ! -L "$PREFLIGHT_ERROR_FILE" ]] && preflight_control_file_is_private "$PREFLIGHT_ERROR_FILE"; then
		printf 'preflight-lock exit=%s cleanup=%s parent-live=%s lock-held=%s\n' "$exit_code" "$cleanup_status" "$parent_live" "$LOCK_HELD" >>"$PREFLIGHT_ERROR_FILE" || true
	fi
	if [[ "$cleanup_status" -ne 0 ]]; then
		exit_code="$EXIT_LOCK"
	fi
	exit "$exit_code"
}

command_preflight_lock() {
	local ready_file=''
	local release_file=''
	local error_file=''
	local ready_token=''
	local release_token=''
	local parent_pid=''
	local parent_instance=''
	local release_parent=''
	local ready_value=''
	local release_state=''
	while [[ $# -gt 0 ]]; do
		if parse_common "$@"; then
			shift "$PARSE_SHIFT"
			continue
		fi
		case "$1" in
		--ready-file)
			ready_file="${2:-}"
			shift 2
			;;
		--release-file)
			release_file="${2:-}"
			shift 2
			;;
		--error-file)
			error_file="${2:-}"
			shift 2
			;;
		--ready-token)
			ready_token="${2:-}"
			shift 2
			;;
		--release-token)
			release_token="${2:-}"
			shift 2
			;;
		--parent-pid)
			parent_pid="${2:-}"
			shift 2
			;;
		--parent-instance)
			parent_instance="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown preflight-lock argument: $1." ;;
		esac
	done
	[[ -n "$ready_file" && -n "$release_file" && -n "$error_file" && -n "$ready_token" && -n "$release_token" && -n "$parent_pid" && -n "$parent_instance" ]] || die "$EXIT_USAGE" 'preflight-lock requires ready/release/error files, ready/release tokens, and parent PID/instance.'
	case "$parent_pid" in '' | 0 | *[!0-9]*) die "$EXIT_USAGE" "preflight parent PID must be a positive integer: $parent_pid." ;; esac
	[[ "$parent_instance" =~ ^(proc:[0-9]+|ps:[A-Z][a-z]{2}[[:space:]][A-Z][a-z]{2}[[:space:]][0-9]{1,2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]][0-9]{4})$ ]] || die "$EXIT_USAGE" "preflight parent process instance is invalid: $parent_instance."
	[[ "$ready_token" =~ ^[0-9a-f]{64}$ && "$release_token" =~ ^[0-9a-f]{64}$ ]] || die "$EXIT_USAGE" 'preflight control tokens must be lowercase SHA-256 digests.'
	case "$ready_file" in /*) ;; *) die "$EXIT_USAGE" "preflight ready file must be absolute: $ready_file." ;; esac
	case "$release_file" in /*) ;; *) die "$EXIT_USAGE" "preflight release file must be absolute: $release_file." ;; esac
	case "$error_file" in /*) ;; *) die "$EXIT_USAGE" "preflight error file must be absolute: $error_file." ;; esac
	[[ -f "$ready_file" && ! -L "$ready_file" ]] || die "$EXIT_FILESYSTEM" "preflight ready file must be an existing regular file: $ready_file."
	preflight_control_file_is_private "$ready_file" || die "$EXIT_FILESYSTEM" "preflight ready file must be a private single-link file: $ready_file."
	[[ -f "$release_file" && ! -L "$release_file" ]] || die "$EXIT_FILESYSTEM" "preflight release file must be an existing regular file: $release_file."
	preflight_control_file_is_private "$release_file" || die "$EXIT_FILESYSTEM" "preflight release file must be a private single-link file: $release_file."
	[[ -f "$error_file" && ! -L "$error_file" ]] || die "$EXIT_FILESYSTEM" "preflight error file must be an existing regular file: $error_file."
	preflight_control_file_is_private "$error_file" || die "$EXIT_FILESYSTEM" "preflight error file must be a private single-link file: $error_file."
	preflight_control_state_is_valid "$ready_file" "pending:$ready_token" || die "$EXIT_FILESYSTEM" 'preflight ready file has an invalid initial state.'
	preflight_control_state_is_valid "$release_file" "hold:$release_token" || die "$EXIT_FILESYSTEM" 'preflight release file has an invalid initial state.'
	release_parent="${release_file%/*}"
	[[ -d "$release_parent" && ! -L "$release_parent" ]] || die "$EXIT_FILESYSTEM" "preflight release-file parent must be a real directory: $release_parent."
	preflight_parent_is_live "$parent_pid" "$parent_instance" || die "$EXIT_RUNTIME_STATE" 'preflight parent process is not a live process owned by the current user.'

	PREFLIGHT_READY_FILE="$ready_file"
	PREFLIGHT_RELEASE_FILE="$release_file"
	PREFLIGHT_ERROR_FILE="$error_file"
	PREFLIGHT_READY_TOKEN="$ready_token"
	PREFLIGHT_RELEASE_TOKEN="$release_token"
	PREFLIGHT_PARENT_PID="$parent_pid"
	PREFLIGHT_PARENT_INSTANCE="$parent_instance"
	trap preflight_lock_cleanup EXIT

	resolve_preflight_registry
	if [[ -d "$REGISTRY_DIR" && ! -L "$REGISTRY_DIR" ]]; then
		acquire_lock
	fi
	"$INIT_SCRIPT" --repo "$REPO_INPUT" --preflight --registry-lock-held >/dev/null || die "$EXIT_FILESYSTEM" 'registry preflight failed while holding the registry lock; preserve state and retry.'
	if [[ "$LOCK_HELD" -eq 1 ]]; then
		ready_value='locked'
	else
		ready_value='unlocked'
	fi
	publish_preflight_ready "ready=$ready_value" || die "$EXIT_FILESYSTEM" "cannot publish preflight readiness: $ready_file."
	while true; do
		preflight_parent_is_live "$parent_pid" "$parent_instance" || die "$EXIT_RUNTIME_STATE" 'preflight parent exited or changed identity before registry lock release.'
		if ! release_state="$(preflight_control_state_read "$release_file")"; then
			die "$EXIT_FILESYSTEM" 'preflight release file was replaced with an invalid state.'
		fi
		case "$release_state" in
		"release:$release_token") break ;;
		"hold:$release_token") ;;
		*) die "$EXIT_FILESYSTEM" 'preflight release file was replaced with an invalid state.' ;;
		esac
		sleep 0.01
	done
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

validate_task_id() {
	local label="$1"
	local value="$2"
	[[ -n "$value" ]] || die "$EXIT_USAGE" "$label must not be empty."
	case "$value" in
	. | ..) die "$EXIT_USAGE" "$label must not be dot or dot-dot: $value." ;;
	*[!A-Za-z0-9._-]*) die "$EXIT_USAGE" "$label contains unsupported artifact-name characters: $value." ;;
	esac
}

validate_session_id() {
	local value="$1"
	validate_identity 'session-id' "$value"
	case "$value" in
	-*) die "$EXIT_USAGE" "session-id must not begin with a hyphen: $value." ;;
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
	local sandbox=''
	local owner_pid=''
	local token=''
	local owner_instance=''
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
		--sandbox)
			sandbox="${2:-}"
			shift 2
			;;
		--pid)
			owner_pid="${2:-}"
			shift 2
			;;
		--token)
			token="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown reserve argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$scope" ]] || die "$EXIT_USAGE" 'reserve requires non-empty --task-id and --scope.'
	validate_task_id 'task-id' "$task_id"
	validate_scope "$scope"
	[[ -z "$retry_of" ]] || validate_task_id 'retry-of' "$retry_of"
	case "$sandbox" in '' | read-only | workspace-write) ;; *) die "$EXIT_USAGE" 'sandbox must be read-only or workspace-write.' ;; esac
	if [[ -n "$owner_pid" || -n "$token" ]]; then
		[[ -n "$owner_pid" && -n "$token" ]] || die "$EXIT_USAGE" 'reserve requires both --pid and --token when claiming the initial invocation.'
		case "$owner_pid" in '' | 0 | *[!0-9]*) die "$EXIT_USAGE" "invocation PID must be a positive integer: $owner_pid." ;; esac
		validate_identity 'invocation-token' "$token"
		owner_instance="$(process_instance_identity "$owner_pid")" || die "$EXIT_CONFLICT" "cannot identify invocation process instance for PID $owner_pid."
	fi
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" 'all(.identity_ledger[]; .task_id != $task_id)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "task-id is permanently reserved: $task_id."
	if [[ -n "$retry_of" ]]; then
		local retry_sandbox
		retry_sandbox="$(jq -r --arg retry_of "$retry_of" --arg scope "$scope" '
      .identity_ledger[]
      | select(.task_id == $retry_of and .scope == $scope and .status == "retired" and (.terminal_status == "failed" or .terminal_status == "blocked" or .terminal_status == "interrupted"))
      | .sandbox
    ' "$REGISTRY_PATH")"
		[[ -n "$retry_sandbox" && "$retry_sandbox" != null ]] || die "$EXIT_CONFLICT" "retry-of must name a retired failed/blocked/interrupted task with the exact same scope: $retry_of."
		if [[ -z "$sandbox" ]]; then
			sandbox="$retry_sandbox"
		else
			[[ "$sandbox" == "$retry_sandbox" ]] || die "$EXIT_CONFLICT" "retry sandbox must match parent task $retry_of: expected $retry_sandbox, got $sandbox."
		fi
		jq -e --arg scope "$scope" 'all(.workers[]; .scope != $scope)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" 'another live task already owns this retry scope.'
		jq -e --arg retry_of "$retry_of" 'all(.identity_ledger[]; .retry_of != $retry_of)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "retry attempt already has a child; retry the latest failed/blocked/interrupted child instead: $retry_of."
	else
		sandbox="${sandbox:-workspace-write}"
		jq -e --arg scope "$scope" 'all(.identity_ledger[]; .scope != $scope)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" 'scope is already reserved; use --retry-of with the failed/blocked/interrupted task ID to retry the exact scope.'
	fi
	local timestamp
	timestamp="$(now_utc)"
	atomic_write '
    .updated_at = $timestamp
    | .identity_ledger += [{task_id: $task_id, scope: $scope, sandbox: $sandbox, retry_of: (($retry_of | select(length > 0)) // null), session_id: null, status: "reserved", reserved_at: $timestamp, bound_at: null, activated_at: null, terminal_at: null, retired_at: null, terminal_status: null, terminal_evidence: ""}]
    | .workers += [{task_id: $task_id, scope: $scope, sandbox: $sandbox, retry_of: (($retry_of | select(length > 0)) // null), session_id: null, status: "reserved", created_at: $timestamp, updated_at: $timestamp, bound_at: null, activated_at: null, checkpoint_evidence: "", invocation_pid: (($owner_pid | select(length > 0)) // null), invocation_token: (($token | select(length > 0)) // null), invocation_instance: (($owner_instance | select(length > 0)) // null), active_child_pgid: null, active_child_instance: null}]
  ' --arg task_id "$task_id" --arg scope "$scope" --arg sandbox "$sandbox" --arg retry_of "${retry_of:-}" --arg owner_pid "${owner_pid:-}" --arg token "${token:-}" --arg owner_instance "${owner_instance:-}" --arg timestamp "$timestamp"
	printf 'Reserved task=%s\n' "$task_id"
}

# Internal locked read used by launch cleanup. It proves whether a reserve
# outcome was rejected before allowing a launcher-acquired cross-path claim to
# be released.
command_reservation_status() {
	local task_id=''
	local scope=''
	local token=''
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
		--scope)
			scope="${2:-}"
			shift 2
			;;
		--token)
			token="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown reservation-status argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$scope" && -n "$token" ]] || die "$EXIT_USAGE" 'reservation-status requires --task-id, --scope, and --token.'
	validate_task_id 'task-id' "$task_id"
	validate_scope "$scope"
	validate_identity 'invocation-token' "$token"
	resolve_registry
	acquire_lock
	if jq -e --arg task_id "$task_id" --arg scope "$scope" --arg token "$token" 'any(.workers[]; .task_id == $task_id and .scope == $scope and .invocation_token == $token)' "$REGISTRY_PATH" >/dev/null; then
		printf 'committed\n'
		return 0
	fi
	if jq -e --arg task_id "$task_id" --arg scope "$scope" '
      any(.workers[]; .task_id == $task_id and .scope == $scope and .status == "reserved" and (.invocation_token == null or .invocation_token == ""))
      and any(.identity_ledger[]; .task_id == $task_id and .scope == $scope and .status == "reserved")
    ' "$REGISTRY_PATH" >/dev/null; then
		printf 'not-committed\n'
		return 0
	fi
	if jq -e --arg task_id "$task_id" 'any(.workers[]; .task_id == $task_id) or any(.identity_ledger[]; .task_id == $task_id and (.status == "reserved" or .status == "bound" or .status == "active"))' "$REGISTRY_PATH" >/dev/null; then
		die "$EXIT_CONFLICT" "reservation status is ambiguous for task $task_id; preserve registry state and cross-path claim for explicit recovery."
	fi
	printf 'not-committed\n'
}

command_bind() {
	local task_id=''
	local session_id=''
	local invocation_token=''
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
		--invocation-token)
			invocation_token="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown bind argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$session_id" ]] || die "$EXIT_USAGE" 'bind requires --task-id and --session-id.'
	validate_task_id 'task-id' "$task_id"
	validate_session_id "$session_id"
	[[ -z "$invocation_token" ]] || validate_identity 'invocation-token' "$invocation_token"
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" 'any(.workers[]; .task_id == $task_id and .status == "reserved" and .session_id == null)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "task is not an unbound reservation: $task_id."
	require_invocation_authority "$task_id" "$invocation_token"
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
	local invocation_token=''
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
		--invocation-token)
			invocation_token="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown activate argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$session_id" ]] || die "$EXIT_USAGE" 'activate requires --task-id and --session-id.'
	validate_task_id 'task-id' "$task_id"
	validate_session_id "$session_id"
	[[ -z "$invocation_token" ]] || validate_identity 'invocation-token' "$invocation_token"
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" --arg session_id "$session_id" 'any(.workers[]; .task_id == $task_id and .session_id == $session_id and .status == "bound")' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" 'activation requires the exact bound task and Codex session.'
	require_invocation_authority "$task_id" "$invocation_token"
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
	validate_task_id 'task-id' "$task_id"
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" 'any(.workers[]; .task_id == $task_id and .status == "active")' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "checkpoint requires an active task: $task_id."
	local timestamp
	timestamp="$(now_utc)"
	atomic_write '.updated_at = $timestamp | .workers |= map(if .task_id == $task_id then .checkpoint_evidence = $evidence | .updated_at = $timestamp else . end)' --arg task_id "$task_id" --arg evidence "$evidence" --arg timestamp "$timestamp"
	printf 'Checkpointed task=%s\n' "$task_id"
}

command_claim_invocation() {
	local task_id=''
	local owner_pid=''
	local token=''
	local current_pid=''
	local current_token=''
	local current_instance=''
	local current_child_pid=''
	local current_child_instance=''
	local required_status=''
	local owner_instance=''
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
		--pid)
			owner_pid="${2:-}"
			shift 2
			;;
		--token)
			token="${2:-}"
			shift 2
			;;
		--require-status)
			required_status="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown claim-invocation argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$owner_pid" && -n "$token" ]] || die "$EXIT_USAGE" 'claim-invocation requires --task-id, --pid, and --token.'
	validate_task_id 'task-id' "$task_id"
	validate_identity 'invocation-token' "$token"
	case "$required_status" in '' | active) ;; *) die "$EXIT_USAGE" 'require-status must be active when provided.' ;; esac
	case "$owner_pid" in '' | 0 | *[!0-9]*) die "$EXIT_USAGE" "invocation PID must be a positive integer: $owner_pid." ;; esac
	owner_instance="$(process_instance_identity "$owner_pid")" || die "$EXIT_CONFLICT" "cannot identify invocation process instance for PID $owner_pid."
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" 'any(.workers[]; .task_id == $task_id)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_NOT_FOUND" "live task not found: $task_id."
	if [[ -n "$required_status" ]]; then
		jq -e --arg task_id "$task_id" --arg status "$required_status" 'any(.workers[]; .task_id == $task_id and .status == $status)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "task $task_id must be $required_status before claiming an invocation."
	fi
	current_pid="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .invocation_pid // empty' "$REGISTRY_PATH")"
	current_token="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .invocation_token // empty' "$REGISTRY_PATH")"
	current_instance="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .invocation_instance // empty' "$REGISTRY_PATH")"
	current_child_pid="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .active_child_pgid // empty' "$REGISTRY_PATH")"
	current_child_instance="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .active_child_instance // empty' "$REGISTRY_PATH")"
	if [[ -n "$current_pid" ]]; then
		if [[ "$current_pid" == "$owner_pid" && "$current_token" == "$token" && "$current_instance" == "$owner_instance" ]]; then
			printf 'Invocation already claimed task=%s token=%s\n' "$task_id" "$token"
			return "$EXIT_OK"
		fi
		recorded_process_instance_blocks_recovery "$current_pid" "$current_instance" && die "$EXIT_CONFLICT" "another invocation already owns task $task_id with live or unverifiable PID $current_pid."
		if [[ -n "$current_child_pid" ]] && recorded_process_group_blocks_recovery "$current_child_pid" "$current_child_instance"; then
			die "$EXIT_CONFLICT" "Codex process group $current_child_pid remains live for task $task_id; stop and verify that group before reclaiming the invocation."
		fi
		if [[ -n "$current_child_pid" ]] && { [[ -z "$current_token" ]] || ! descendant_state_is_confirmed_clean "$task_id" "$current_token" "$current_child_pid"; }; then
			die "$EXIT_CONFLICT" "Codex descendant tracker has not proved the recorded child process tree stopped for task $task_id; restore or verify its cleanup evidence before reclaiming."
		fi
		if [[ -z "$current_child_pid" && -n "$current_token" && (-e "$(descendant_state_path "$task_id" "$current_token")" || -L "$(descendant_state_path "$task_id" "$current_token")") ]] && ! descendant_state_is_confirmed_clean "$task_id" "$current_token"; then
			die "$EXIT_CONFLICT" "Codex descendant tracker remains active for the previous invocation of task $task_id; stop and verify its recorded processes before reclaiming."
		fi
	fi
	local timestamp
	timestamp="$(now_utc)"
	atomic_write '
    .updated_at = $timestamp
    | .workers |= map(if .task_id == $task_id then .invocation_pid = $owner_pid | .invocation_token = $token | .invocation_instance = $owner_instance | .active_child_pgid = null | .active_child_instance = null | .updated_at = $timestamp else . end)
  ' --arg task_id "$task_id" --arg owner_pid "$owner_pid" --arg token "$token" --arg owner_instance "$owner_instance" --arg timestamp "$timestamp"
	printf 'Claimed invocation task=%s token=%s\n' "$task_id" "$token"
}

command_child_registration() {
	local mode="$1"
	shift
	local task_id=''
	local child_pgid=''
	local child_instance=''
	local token=''
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
		--pgid)
			child_pgid="${2:-}"
			shift 2
			;;
		--token)
			token="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown $mode argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$child_pgid" && -n "$token" ]] || die "$EXIT_USAGE" "$mode requires --task-id, --pgid, and --token."
	validate_task_id 'task-id' "$task_id"
	validate_identity 'invocation-token' "$token"
	case "$child_pgid" in '' | 0 | *[!0-9]*) die "$EXIT_USAGE" "child process-group ID must be a positive integer: $child_pgid." ;; esac
	if [[ "$mode" == record-child ]]; then
		child_instance="$(process_instance_identity "$child_pgid")" || die "$EXIT_CONFLICT" "cannot identify child process-group leader instance for PID $child_pgid."
	fi
	resolve_registry
	acquire_lock
	case "$mode" in
	record-child)
		jq -e --arg task_id "$task_id" --arg token "$token" 'any(.workers[]; .task_id == $task_id and .invocation_token == $token and .active_child_pgid == null and .active_child_instance == null)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "invocation token cannot register a child process group for task $task_id."
		atomic_write '.workers |= map(if .task_id == $task_id then .active_child_pgid = $child_pgid | .active_child_instance = $child_instance else . end)' --arg task_id "$task_id" --arg child_pgid "$child_pgid" --arg child_instance "$child_instance"
		;;
	clear-child)
		child_instance="$(jq -r --arg task_id "$task_id" --arg token "$token" --arg child_pgid "$child_pgid" '.workers[] | select(.task_id == $task_id and .invocation_token == $token and .active_child_pgid == $child_pgid) | .active_child_instance // empty' "$REGISTRY_PATH")"
		[[ -n "$child_instance" ]] || die "$EXIT_CONFLICT" "invocation token does not own child process group $child_pgid for task $task_id."
		recorded_process_group_blocks_recovery "$child_pgid" "$child_instance" && die "$EXIT_CONFLICT" "Codex process group $child_pgid is not confirmed stopped for task $task_id."
		descendant_state_is_confirmed_clean "$task_id" "$token" "$child_pgid" || die "$EXIT_CONFLICT" "Codex descendant tracker has not proved the full process tree stopped for task $task_id."
		atomic_write '.workers |= map(if .task_id == $task_id then .active_child_pgid = null | .active_child_instance = null else . end)' --arg task_id "$task_id"
		;;
	esac
	printf '%s task=%s process-group=%s\n' "$mode" "$task_id" "$child_pgid"
}

command_release_invocation() {
	local task_id=''
	local token=''
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
		--token)
			token="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown release-invocation argument: $1." ;;
		esac
	done
	[[ -n "$task_id" && -n "$token" ]] || die "$EXIT_USAGE" 'release-invocation requires --task-id and --token.'
	validate_task_id 'task-id' "$task_id"
	validate_identity 'invocation-token' "$token"
	resolve_registry
	acquire_lock
	jq -e --arg task_id "$task_id" --arg token "$token" 'any(.workers[]; .task_id == $task_id and .invocation_token == $token and .active_child_pgid == null and .active_child_instance == null)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "invocation token does not own an idle live task $task_id."
	local timestamp
	timestamp="$(now_utc)"
	atomic_write '
    .updated_at = $timestamp
    | .workers |= map(if .task_id == $task_id then .invocation_pid = null | .invocation_token = null | .invocation_instance = null | .updated_at = $timestamp else . end)
  ' --arg task_id "$task_id" --arg timestamp "$timestamp"
	printf 'Released invocation task=%s token=%s\n' "$task_id" "$token"
}

command_complete_and_retire() {
	local task_id=''
	local status=''
	local evidence=''
	local invocation_token=''
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
		--invocation-token)
			invocation_token="${2:-}"
			shift 2
			;;
		*) die "$EXIT_USAGE" "unknown complete-and-retire argument: $1." ;;
		esac
	done
	case "$status" in completed | failed | blocked | interrupted) ;; *) die "$EXIT_USAGE" 'terminal status must be completed, failed, blocked, or interrupted.' ;; esac
	[[ -n "$task_id" && -n "$evidence" ]] || die "$EXIT_USAGE" 'complete-and-retire requires --task-id, --status, and non-empty --evidence.'
	validate_task_id 'task-id' "$task_id"
	[[ -z "$invocation_token" ]] || validate_identity 'invocation-token' "$invocation_token"
	resolve_registry
	acquire_lock
	if [[ "$status" == completed ]]; then
		[[ -n "$invocation_token" ]] || die "$EXIT_CONFLICT" 'completed retirement requires the token-owning active runner and a validated structured result.'
		jq -e --arg task_id "$task_id" --arg token "$invocation_token" 'any(.workers[]; .task_id == $task_id and .status == "active" and .invocation_token == $token)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "completed retirement requires the token-owning active runner for task $task_id."
	fi
	if [[ -n "$invocation_token" ]]; then
		jq -e --arg task_id "$task_id" --arg token "$invocation_token" 'any(.workers[]; .task_id == $task_id and .invocation_token == $token)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_CONFLICT" "invocation token does not own live task $task_id."
	else
		jq -e --arg task_id "$task_id" 'any(.workers[]; .task_id == $task_id)' "$REGISTRY_PATH" >/dev/null || die "$EXIT_NOT_FOUND" "live task not found: $task_id."
		local invocation_pid
		local invocation_instance
		invocation_pid="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .invocation_pid // empty' "$REGISTRY_PATH")"
		invocation_instance="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .invocation_instance // empty' "$REGISTRY_PATH")"
		if [[ -n "$invocation_pid" ]] && recorded_process_instance_blocks_recovery "$invocation_pid" "$invocation_instance"; then
			die "$EXIT_CONFLICT" "invocation PID $invocation_pid remains live or unverifiable for task $task_id; use its invocation token or stop and verify that owner before retirement."
		fi
	fi
	local active_child_pgid
	local active_child_instance
	local stored_invocation_token
	active_child_pgid="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .active_child_pgid // empty' "$REGISTRY_PATH")"
	active_child_instance="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .active_child_instance // empty' "$REGISTRY_PATH")"
	if [[ -n "$active_child_pgid" ]] && recorded_process_group_blocks_recovery "$active_child_pgid" "$active_child_instance"; then
		die "$EXIT_CONFLICT" "Codex process group $active_child_pgid remains live for task $task_id; stop and verify that group before retirement."
	fi
	stored_invocation_token="$(jq -r --arg task_id "$task_id" '.workers[] | select(.task_id == $task_id) | .invocation_token // empty' "$REGISTRY_PATH")"
	if [[ -n "$active_child_pgid" ]] && { [[ -z "$stored_invocation_token" ]] || ! descendant_state_is_confirmed_clean "$task_id" "$stored_invocation_token" "$active_child_pgid"; }; then
		die "$EXIT_CONFLICT" "Codex descendant tracker has not proved the recorded child process tree stopped for task $task_id; restore or verify its cleanup evidence before retirement."
	fi
	if [[ -z "$active_child_pgid" && -n "$stored_invocation_token" && (-e "$(descendant_state_path "$task_id" "$stored_invocation_token")" || -L "$(descendant_state_path "$task_id" "$stored_invocation_token")") ]] && ! descendant_state_is_confirmed_clean "$task_id" "$stored_invocation_token"; then
		die "$EXIT_CONFLICT" "Codex descendant tracker has not proved the full process tree stopped for task $task_id; stop and verify it before retirement."
	fi
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
		validate_task_id 'task-id' "$task_id"
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
	exec "$INIT_SCRIPT" "$@" --existing-path
	;;
preflight)
	exec "$INIT_SCRIPT" "$@" --preflight
	;;
preflight-lock) command_preflight_lock "$@" ;;
reserve) command_reserve "$@" ;;
bind) command_bind "$@" ;;
activate) command_activate "$@" ;;
checkpoint) command_checkpoint "$@" ;;
claim-invocation) command_claim_invocation "$@" ;;
release-invocation) command_release_invocation "$@" ;;
record-child | clear-child) command_child_registration "$command" "$@" ;;
complete-and-retire) command_complete_and_retire "$@" ;;
reservation-status) command_reservation_status "$@" ;;
query | active | assert-no-active | assert-empty) parse_read_args "$command" "$@" ;;
*) die "$EXIT_USAGE" "unknown command: $command. Use --help for usage." ;;
esac
