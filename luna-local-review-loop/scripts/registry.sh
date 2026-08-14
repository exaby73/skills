#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs intentionally use single-quoted $variables.
set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_REPOSITORY=4
readonly EXIT_SCHEMA=5
readonly EXIT_CONFLICT=6
readonly EXIT_NOT_FOUND=7
readonly EXIT_ACTIVE=8
readonly EXIT_LOCK=9
readonly EXIT_FILESYSTEM=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly INIT_SCRIPT="$SCRIPT_DIR/init.sh"

REPO_INPUT='.'
REPO_ROOT=''
REGISTRY_DIR=''
REGISTRY_PATH=''
LOCK_DIR=''
LOCK_HELD=0

readonly SCHEMA_FILTER='
  def nonempty_string: type == "string" and length > 0;
  def valid_status($status): ["reserved", "bound", "active", "stopping", "completed", "failed", "blocked", "interrupted", "retired"] | index($status) != null;
  def terminal_status($status): ["completed", "failed", "blocked", "interrupted", "retired"] | index($status) != null;
  def valid_handle_kind($kind): ["launch", "resume"] | index($kind) != null;
  def nullable_string: . == null or (. | nonempty_string);
  . as $root
  | try (
      (.schema_version == 1)
      and (.registry == "luna-local-review-loop")
      and (.repository_root | nonempty_string)
      and (.created_at | nonempty_string)
      and (.updated_at | nonempty_string)
      and (.identity_ledger | type == "array")
      and (.workers | type == "array")
      and all($root.identity_ledger[];
        (.task_id | nonempty_string)
        and (.scope | nonempty_string)
        and (.session_id | nullable_string)
        and (.handle | nullable_string)
        and (.handle_history | type == "array")
        and (.reserved_at | nonempty_string)
        and ((.bound_at == null) or (.bound_at | nonempty_string))
        and all(.handle_history[];
          (.handle | nonempty_string)
          and (.recorded_at | nonempty_string)
          and (.kind | type == "string" and valid_handle_kind(.))
        )
        and ((.session_id == null) == (.handle == null))
        and ((.session_id == null) == ((.handle_history | length) == 0))
        and (if .session_id == null
             then (.handle == null and .handle_history == [])
             else (.handle != null
                   and (.handle_history | length > 0)
                   and (.handle_history[0].kind == "launch")
                   and (.handle_history[-1].handle == .handle)
                   and all(.handle_history[1:][]?; .kind == "resume"))
             end)
      )
      and all($root.workers[];
        (.task_id | nonempty_string)
        and (.scope | nonempty_string)
        and (.session_id | nullable_string)
        and (.handle | nullable_string)
        and (valid_status(.status))
        and (.created_at | nonempty_string)
        and (.updated_at | nonempty_string)
        and ((.bound_at == null) or (.bound_at | nonempty_string))
        and ((.activated_at == null) or (.activated_at | nonempty_string))
        and ((.terminal_at == null) or (.terminal_at | nonempty_string))
        and ((.retired_at == null) or (.retired_at | nonempty_string))
        and ((.terminal_evidence | type) == "string")
        and ((.terminal_notes | type) == "string")
        and ((.notes | type) == "string")
        and ((.session_id == null) == (.handle == null))
        and ((.session_id == null) == (.bound_at == null))
        and (if .status == "reserved" then (.session_id == null and .bound_at == null and .activated_at == null)
             elif .status == "bound" then (.session_id != null and .bound_at != null and .activated_at == null)
             elif .status == "active" then (.session_id != null and .bound_at != null and .activated_at != null)
             elif .status == "stopping" then (.session_id != null and .bound_at != null)
             else true end)
        and (if terminal_status(.status)
             then (.terminal_at | nonempty_string) and (.terminal_evidence | nonempty_string)
             else (.terminal_at == null and .terminal_status == null and .terminal_evidence == "") end)
        and (if .status == "retired" then (.retired_at | nonempty_string) else .retired_at == null end)
        and (if terminal_status(.status) then (terminal_status(.terminal_status)) else .terminal_status == null end)
      )
      and (([$root.identity_ledger[].task_id] | length) == ([$root.identity_ledger[].task_id] | unique | length))
      and (([$root.identity_ledger[].scope] | length) == ([$root.identity_ledger[].scope] | unique | length))
      and (([$root.identity_ledger[] | select(.session_id != null) | .session_id] | length) == ([$root.identity_ledger[] | select(.session_id != null) | .session_id] | unique | length))
      and (([$root.identity_ledger[] | .handle_history[] | .handle] | length) == ([$root.identity_ledger[] | .handle_history[] | .handle] | unique | length))
      and (([$root.workers[].task_id] | length) == ([$root.workers[].task_id] | unique | length))
      and (([$root.workers[].scope] | length) == ([$root.workers[].scope] | unique | length))
      and (([$root.workers[] | select(.session_id != null) | .session_id] | length) == ([$root.workers[] | select(.session_id != null) | .session_id] | unique | length))
      and (([$root.workers[] | select(.handle != null) | .handle] | length) == ([$root.workers[] | select(.handle != null) | .handle] | unique | length))
      and all($root.workers[];
        . as $worker
        | any($root.identity_ledger[];
          .task_id == $worker.task_id
          and .scope == $worker.scope
          and .session_id == $worker.session_id
          and .handle == $worker.handle
          and .bound_at == $worker.bound_at
        )
      )
    ) catch false
  | .
'

usage() {
  local exit_code="${1:-0}"
  cat <<'EOF'
Usage:
  registry.sh init [--repo PATH] [--skills-root PATH]
  registry.sh reserve|register --task-id ID --scope TEXT [--notes TEXT] [--repo PATH]
  registry.sh bind|attach --task-id ID --session-id ID --handle ID [--repo PATH]
  registry.sh record-resume-handle --task-id ID --session-id ID --handle ID [--repo PATH]
  registry.sh activate --task-id ID --session-id ID [--handle ID] [--repo PATH]
  registry.sh list [--active] [--repo PATH]
  registry.sh active [--repo PATH]
  registry.sh query --task-id ID|--session-id ID|--handle ID [--active-only] [--repo PATH]
  registry.sh update --task-id ID --status STATE [--session-id ID] [--handle ID] [--evidence TEXT] [--notes TEXT] [--repo PATH]
  registry.sh retire --task-id ID [--session-id ID] [--handle ID] [--evidence TEXT] [--notes TEXT] [--repo PATH]
  registry.sh prune|clear [--task-id ID] [--repo PATH]
  registry.sh assert-no-active [--repo PATH]
  registry.sh assert-empty [--repo PATH]

Reserve before launching. Bind exactly once after codex exec emits the session
and process/agent handle, then activate. Terminal entries must be retired
before pruning.
EOF
  exit "$exit_code"
}

die() {
  local exit_code="$1"
  shift
  printf 'luna-local-review-loop: ERROR [%s] %s\n' "$exit_code" "$*" >&2
  exit "$exit_code"
}

require_commands() {
  local missing=''
  local command_name
  local required_commands=(bash git jq mktemp mkdir mv rm rmdir date kill ps sleep)

  for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing="${missing}${missing:+, }${command_name}"
    fi
  done

  if [[ -n "$missing" ]]; then
    die "$EXIT_PREREQUISITE" "missing runtime prerequisite(s): $missing. Check with 'command -v <name>'; install them through the repository/host-approved mechanism, then retry. This script never performs network installs."
  fi
}

resolve_repo_root() {
  local candidate
  if [[ ! -d "$REPO_INPUT" ]]; then
    die "$EXIT_REPOSITORY" "repository path does not exist or is not a directory: $REPO_INPUT. Pass --repo PATH for an existing Git repository."
  fi

  candidate="$(cd "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot access repository path: $REPO_INPUT. Check its permissions or pass a readable Git repository with --repo PATH."
  if ! REPO_ROOT="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)"; then
    die "$EXIT_REPOSITORY" "path is not inside a Git repository: $candidate. Change to a repository or pass --repo PATH."
  fi
  REPO_ROOT="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot resolve the Git repository root for: $candidate."
  REGISTRY_DIR="$REPO_ROOT/.agents/agent-registry"
  REGISTRY_PATH="$REGISTRY_DIR/registry.json"
  LOCK_DIR="$REGISTRY_DIR/.lock"
}

ensure_registry() {
  [[ -f "$REGISTRY_PATH" ]] || die "$EXIT_REPOSITORY" "worker registry is not initialized: $REGISTRY_PATH. Run '$INIT_SCRIPT --repo \"$REPO_ROOT\" --skills-root PATH' or invoke '\$luna-local-review-loop init' through the skill first."
  if ! jq -e "$SCHEMA_FILTER" "$REGISTRY_PATH" >/dev/null 2>&1; then
    die "$EXIT_SCHEMA" "registry fails schema version 1 validation: $REGISTRY_PATH. Preserve it for investigation and repair the valid registry before retrying."
  fi
  if [[ "$(jq -r '.repository_root' "$REGISTRY_PATH")" != "$REPO_ROOT" ]]; then
    die "$EXIT_SCHEMA" "registry repository_root does not match target Git root $REPO_ROOT: $REGISTRY_PATH. Do not reuse a registry from another repository."
  fi
}

now_utc() {
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || die "$EXIT_FILESYSTEM" 'could not produce a UTC timestamp.'
  [[ -n "$timestamp" ]] || die "$EXIT_FILESYSTEM" 'the date command returned an empty UTC timestamp.'
  printf '%s' "$timestamp"
}

release_lock() {
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
}

acquire_lock() {
  local attempt=0
  local owner_pid=''

  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner_pid=''
    if [[ -f "$LOCK_DIR/pid" ]]; then
      IFS= read -r owner_pid < "$LOCK_DIR/pid" || owner_pid=''
      case "$owner_pid" in
        ''|0|*[!0-9]*) ;;
        *)
          if ! kill -0 "$owner_pid" 2>/dev/null; then
            rm -f "$LOCK_DIR/pid" 2>/dev/null || true
            if rmdir "$LOCK_DIR" 2>/dev/null; then
              continue
            fi
          fi
          ;;
      esac
    fi

    attempt=$((attempt + 1))
    if [[ "$attempt" -ge 300 ]]; then
      die "$EXIT_LOCK" "registry lock is busy: $LOCK_DIR. Wait for the other registry command; if no command is running, inspect the lock owner and remove only the stale .lock directory before retrying."
    fi
    sleep 0.1
  done

  if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    die "$EXIT_LOCK" "cannot record the registry lock owner at $LOCK_DIR/pid. Check permissions and retry."
  fi
  LOCK_HELD=1
  trap release_lock EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

validate_identity() {
  local label="$1"
  local value="$2"
  [[ -n "$value" ]] || die "$EXIT_USAGE" "$label must not be empty."
  case "$value" in
    *[!A-Za-z0-9._:/-]*)
      die "$EXIT_USAGE" "$label contains unsupported characters: $value. Use letters, digits, '.', '_', ':', '/', or '-' only."
      ;;
  esac
}

validate_scope() {
  local scope="$1"
  [[ -n "$scope" ]] || die "$EXIT_USAGE" 'scope must not be empty; provide the exact one-task scope and owned paths.'
  case "$scope" in
    *$'\n'*|*$'\r'*)
      die "$EXIT_USAGE" 'scope must be one line so it can be recovered exactly from the registry.'
      ;;
  esac
}

write_registry_with_filter() {
  local filter="$1"
  local temp_path
  shift

  temp_path="$(mktemp "$REGISTRY_DIR/registry.json.tmp.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create an atomic registry temporary file under $REGISTRY_DIR. Check repository permissions."
  if ! jq "$@" "$filter" "$REGISTRY_PATH" > "$temp_path"; then
    rm -f "$temp_path"
    die "$EXIT_FILESYSTEM" "jq could not apply the requested registry transition. The existing registry was left unchanged: $REGISTRY_PATH"
  fi
  if ! jq -e "$SCHEMA_FILTER" "$temp_path" >/dev/null 2>&1; then
    rm -f "$temp_path"
    die "$EXIT_SCHEMA" "requested transition would violate registry schema version 1. The existing registry was left unchanged: $REGISTRY_PATH"
  fi
  if ! mv -f "$temp_path" "$REGISTRY_PATH"; then
    rm -f "$temp_path"
    die "$EXIT_FILESYSTEM" "cannot atomically install updated registry: $REGISTRY_PATH. The existing registry was left unchanged if the rename failed."
  fi
}

require_task_entry() {
  local task_id="$1"
  local task_count
  local ledger_count

  task_count="$(jq -r --arg task_id "$task_id" '[.workers[] | select(.task_id == $task_id)] | length' "$REGISTRY_PATH")"
  if [[ "$task_count" -eq 0 ]]; then
    ledger_count="$(jq -r --arg task_id "$task_id" '[.identity_ledger[] | select(.task_id == $task_id)] | length' "$REGISTRY_PATH")"
    if [[ "$ledger_count" -gt 0 ]]; then
      die "$EXIT_CONFLICT" "refusing operation for task-id $task_id: its reservation remains in the append-only ledger but its worker entry was pruned. Never reuse or recreate a reserved task identity."
    fi
    die "$EXIT_NOT_FOUND" "worker task-id not found: $task_id. Reserve the exact new task before using it."
  fi
}

ledger_owner_for_session() {
  local session_id="$1"
  jq -r --arg session_id "$session_id" '[.identity_ledger[] | select(.session_id == $session_id) | .task_id][0] // ""' "$REGISTRY_PATH"
}

ledger_owner_for_handle() {
  local handle="$1"
  jq -r --arg handle "$handle" '[.identity_ledger[] | select(.handle == $handle or any(.handle_history[]?; .handle == $handle)) | .task_id][0] // ""' "$REGISTRY_PATH"
}

current_worker_field() {
  local task_id="$1"
  local field="$2"
  jq -r --arg task_id "$task_id" ".workers[] | select(.task_id == \$task_id) | .$field // \"\"" "$REGISTRY_PATH"
}

require_bound_identity() {
  local task_id="$1"
  local session_id="$2"
  local handle="$3"
  local current_session
  local expected_session
  local expected_handle
  local session_owner
  local handle_owner

  require_task_entry "$task_id"
  [[ -n "$session_id" ]] || die "$EXIT_USAGE" 'session-id is required for a bound worker operation.'
  current_session="$(current_worker_field "$task_id" 'session_id')"
  if [[ -z "$current_session" ]]; then
    die "$EXIT_CONFLICT" "worker task-id $task_id is still reserved with null session-id and handle. Bind the emitted session and handle exactly once before activation or repository work."
  fi

  session_owner="$(ledger_owner_for_session "$session_id")"
  if [[ -n "$session_owner" && "$session_owner" != "$task_id" ]]; then
    die "$EXIT_CONFLICT" "refusing operation for task-id $task_id: supplied session-id $session_id belongs to task-id $session_owner. A session may continue only its original task; use the captured session for this task."
  fi
  expected_session="$current_session"
  if [[ "$expected_session" != "$session_id" ]]; then
    die "$EXIT_CONFLICT" "refusing operation for task-id $task_id: exact session mismatch (recorded $expected_session, supplied $session_id). A session may continue only its original task; do not launch a replacement for this task."
  fi

  if [[ -n "$handle" ]]; then
    handle_owner="$(ledger_owner_for_handle "$handle")"
    if [[ -n "$handle_owner" && "$handle_owner" != "$task_id" ]]; then
      die "$EXIT_CONFLICT" "refusing operation for task-id $task_id: supplied handle $handle belongs to task-id $handle_owner. Never reuse a worker handle for another task."
    fi
    expected_handle="$(current_worker_field "$task_id" 'handle')"
    if [[ "$expected_handle" != "$handle" ]]; then
      die "$EXIT_CONFLICT" "refusing operation for task-id $task_id: exact handle mismatch (recorded $expected_handle, supplied $handle). Verify the live worker handle before continuing."
    fi
  fi
}

require_bound_session() {
  local task_id="$1"
  local session_id="$2"
  local current_session
  local session_owner
  local current_status

  require_task_entry "$task_id"
  [[ -n "$session_id" ]] || die "$EXIT_USAGE" 'session-id is required for a same-task resume-handle operation.'
  current_session="$(current_worker_field "$task_id" 'session_id')"
  if [[ -z "$current_session" ]]; then
    die "$EXIT_CONFLICT" "worker task-id $task_id is still reserved with null session-id and handle. Record a resume handle only after initial bind records the launch session and handle."
  fi

  session_owner="$(ledger_owner_for_session "$session_id")"
  if [[ -n "$session_owner" && "$session_owner" != "$task_id" ]]; then
    die "$EXIT_CONFLICT" "refusing resume handle for task-id $task_id: supplied session-id $session_id belongs to task-id $session_owner. A session may continue only its original task."
  fi
  if [[ "$current_session" != "$session_id" ]]; then
    die "$EXIT_CONFLICT" "refusing resume handle for task-id $task_id: exact session mismatch (recorded $current_session, supplied $session_id). Preserve the original session and task."
  fi

  current_status="$(current_worker_field "$task_id" 'status')"
  case "$current_status" in
    bound|active) ;;
    stopping)
      die "$EXIT_CONFLICT" "refusing resume handle for task-id $task_id: worker is stopping. Finish shutdown and retire it; do not restart a stopping worker."
      ;;
    completed|failed|blocked|interrupted|retired)
      die "$EXIT_CONFLICT" "refusing resume handle for task-id $task_id: worker is terminal ($current_status). Record resume handles only for bound or active same-session tasks."
      ;;
    reserved)
      die "$EXIT_CONFLICT" "refusing resume handle for task-id $task_id: worker is reserved without a bound session. Bind and activate the launch identity first."
      ;;
    *)
      die "$EXIT_SCHEMA" "worker task-id $task_id has unknown status: $current_status. Preserve the registry and repair it before retrying."
      ;;
  esac
}

require_mutation_identity() {
  local task_id="$1"
  local session_id="$2"
  local handle="$3"
  local current_session

  require_task_entry "$task_id"
  current_session="$(current_worker_field "$task_id" 'session_id')"
  if [[ -z "$current_session" ]]; then
    if [[ -n "$session_id" || -n "$handle" ]]; then
      die "$EXIT_CONFLICT" "worker task-id $task_id is still reserved with null identity. Bind the emitted session-id and handle exactly once; do not attach identity through an update or retirement command."
    fi
    return "$EXIT_OK"
  fi
  [[ -n "$handle" ]] || die "$EXIT_USAGE" 'handle is required for a bound update or retirement; use the current handle recorded in the worker entry after each same-session resume.'
  require_bound_identity "$task_id" "$session_id" "$handle"
}

command_reserve() {
  local task_id=''
  local scope=''
  local notes=''
  local timestamp
  local count

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --task-id.'; task_id="$2"; shift 2 ;;
      --scope) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --scope.'; scope="$2"; shift 2 ;;
      --notes|--note) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; notes="$2"; shift 2 ;;
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown reserve argument: $1. Use --help for usage." ;;
    esac
  done

  validate_identity task-id "$task_id"
  validate_scope "$scope"
  resolve_repo_root
  ensure_registry
  acquire_lock

  count="$(jq -r --arg task_id "$task_id" '[.identity_ledger[] | select(.task_id == $task_id)] | length' "$REGISTRY_PATH")"
  [[ "$count" -eq 0 ]] || die "$EXIT_CONFLICT" "task-id $task_id is already permanently reserved in the append-only ledger. Start a fresh task with a new identity."
  count="$(jq -r --arg scope "$scope" '[.identity_ledger[] | select(.scope == $scope)] | length' "$REGISTRY_PATH")"
  [[ "$count" -eq 0 ]] || die "$EXIT_CONFLICT" "scope is already permanently reserved in the append-only ledger. A scope may belong to only one task; write a fresh exact one-task scope."

  timestamp="$(now_utc)"
  write_registry_with_filter \
    '.identity_ledger += [{task_id: $task_id, scope: $scope, session_id: null, handle: null, handle_history: [], reserved_at: $timestamp, bound_at: null}]
     | .workers += [{task_id: $task_id, scope: $scope, session_id: null, handle: null, status: "reserved", created_at: $timestamp, updated_at: $timestamp, bound_at: null, activated_at: null, terminal_at: null, retired_at: null, terminal_status: null, terminal_evidence: "", terminal_notes: "", notes: $notes}]
     | .updated_at = $timestamp' \
    --arg task_id "$task_id" \
    --arg scope "$scope" \
    --arg timestamp "$timestamp" \
    --arg notes "$notes"

  printf 'Reserved worker task=%s status=reserved session-id=null handle=null\n' "$task_id"
}

command_bind() {
  local task_id=''
  local session_id=''
  local handle=''
  local timestamp
  local current_status
  local owner

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --task-id.'; task_id="$2"; shift 2 ;;
      --session-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --session-id.'; session_id="$2"; shift 2 ;;
      --handle) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --handle.'; handle="$2"; shift 2 ;;
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown bind argument: $1. Use --help for usage." ;;
    esac
  done

  validate_identity task-id "$task_id"
  validate_identity session-id "$session_id"
  validate_identity handle "$handle"
  resolve_repo_root
  ensure_registry
  acquire_lock
  require_task_entry "$task_id"
  current_status="$(current_worker_field "$task_id" 'status')"

  if [[ "$current_status" != reserved ]]; then
    die "$EXIT_CONFLICT" "binding for task-id $task_id was already attempted or recorded (status=$current_status). Binding is exactly once; do not bind a second session or handle."
  fi

  owner="$(ledger_owner_for_session "$session_id")"
  [[ -z "$owner" ]] || die "$EXIT_CONFLICT" "refusing bind for task-id $task_id: session-id $session_id is already permanently bound to task-id $owner. Never reuse a session across tasks."
  owner="$(ledger_owner_for_handle "$handle")"
  [[ -z "$owner" ]] || die "$EXIT_CONFLICT" "refusing bind for task-id $task_id: handle $handle is already permanently bound to task-id $owner. Never reuse a handle across tasks."

  timestamp="$(now_utc)"
  write_registry_with_filter \
    '.identity_ledger |= map(if .task_id == $task_id then .session_id = $session_id | .handle = $handle | .handle_history = [{handle: $handle, recorded_at: $timestamp, kind: "launch"}] | .bound_at = $timestamp else . end)
     | .workers |= map(if .task_id == $task_id then .session_id = $session_id | .handle = $handle | .status = "bound" | .bound_at = $timestamp | .updated_at = $timestamp else . end)
     | .updated_at = $timestamp' \
    --arg task_id "$task_id" \
    --arg session_id "$session_id" \
    --arg handle "$handle" \
    --arg timestamp "$timestamp"

  printf 'Bound worker task=%s session=%s handle=%s status=bound\n' "$task_id" "$session_id" "$handle"
}

command_record_resume_handle() {
  local task_id=''
  local session_id=''
  local handle=''
  local timestamp
  local owner
  local current_status

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --task-id.'; task_id="$2"; shift 2 ;;
      --session-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --session-id.'; session_id="$2"; shift 2 ;;
      --handle) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --handle.'; handle="$2"; shift 2 ;;
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown record-resume-handle argument: $1. Use --help for usage." ;;
    esac
  done

  validate_identity task-id "$task_id"
  validate_identity session-id "$session_id"
  validate_identity handle "$handle"
  resolve_repo_root
  ensure_registry
  acquire_lock
  require_bound_session "$task_id" "$session_id"

  owner="$(ledger_owner_for_handle "$handle")"
  if [[ -n "$owner" ]]; then
    if [[ "$owner" == "$task_id" ]]; then
      die "$EXIT_CONFLICT" "refusing resume handle for task-id $task_id: handle $handle is already recorded in this task's immutable handle history. Supply a fresh globally unused handle."
    fi
    die "$EXIT_CONFLICT" "refusing resume handle for task-id $task_id: handle $handle is already recorded for task-id $owner. Never reuse a worker handle across tasks."
  fi

  current_status="$(current_worker_field "$task_id" 'status')"
  timestamp="$(now_utc)"
  write_registry_with_filter \
    '.identity_ledger |= map(if .task_id == $task_id then .handle = $handle | .handle_history += [{handle: $handle, recorded_at: $timestamp, kind: "resume"}] else . end)
     | .workers |= map(if .task_id == $task_id then .handle = $handle | .updated_at = $timestamp else . end)
     | .updated_at = $timestamp' \
    --arg task_id "$task_id" \
    --arg handle "$handle" \
    --arg timestamp "$timestamp"

  printf 'Recorded resume handle task=%s session=%s handle=%s kind=resume status=%s\n' "$task_id" "$session_id" "$handle" "$current_status"
}

command_activate() {
  local task_id=''
  local session_id=''
  local handle=''
  local timestamp
  local current_status

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --task-id.'; task_id="$2"; shift 2 ;;
      --session-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --session-id.'; session_id="$2"; shift 2 ;;
      --handle) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --handle.'; handle="$2"; shift 2 ;;
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown activate argument: $1. Use --help for usage." ;;
    esac
  done

  validate_identity task-id "$task_id"
  validate_identity session-id "$session_id"
  [[ -z "$handle" ]] || validate_identity handle "$handle"
  resolve_repo_root
  ensure_registry
  acquire_lock
  require_bound_identity "$task_id" "$session_id" "$handle"
  current_status="$(current_worker_field "$task_id" 'status')"

  case "$current_status" in
    bound)
      timestamp="$(now_utc)"
      write_registry_with_filter \
        '.workers |= map(if .task_id == $task_id then .status = "active" | .activated_at = (.activated_at // $timestamp) | .updated_at = $timestamp else . end) | .updated_at = $timestamp' \
        --arg task_id "$task_id" \
        --arg timestamp "$timestamp"
      printf 'Activated worker task=%s session=%s status=active\n' "$task_id" "$session_id"
      ;;
    active)
      printf 'Worker task=%s session=%s is already active; no state change.\n' "$task_id" "$session_id"
      ;;
    reserved)
      die "$EXIT_CONFLICT" "cannot activate task-id $task_id while it is reserved with null identity. Bind the emitted session and handle first."
      ;;
    stopping|completed|failed|blocked|interrupted|retired)
      die "$EXIT_CONFLICT" "cannot activate task-id $task_id from terminal or stopping state $current_status. Continue only the original task/session or reserve a fresh task with a new identity."
      ;;
    *)
      die "$EXIT_SCHEMA" "worker task-id $task_id has unknown status: $current_status. Preserve the registry and repair it before retrying."
      ;;
  esac
}

command_update() {
  local task_id=''
  local session_id=''
  local handle=''
  local status=''
  local evidence=''
  local notes=''
  local evidence_set=0
  local notes_set=0
  local timestamp
  local current_status

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --task-id.'; task_id="$2"; shift 2 ;;
      --session-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --session-id.'; session_id="$2"; shift 2 ;;
      --handle) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --handle.'; handle="$2"; shift 2 ;;
      --status) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --status.'; status="$2"; shift 2 ;;
      --evidence|--terminal-evidence) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; evidence="$2"; evidence_set=1; shift 2 ;;
      --notes|--terminal-notes) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; notes="$2"; notes_set=1; shift 2 ;;
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown update argument: $1. Use --help for usage." ;;
    esac
  done

  validate_identity task-id "$task_id"
  [[ -z "$session_id" ]] || validate_identity session-id "$session_id"
  [[ -z "$handle" ]] || validate_identity handle "$handle"
  [[ -n "$status" ]] || die "$EXIT_USAGE" 'status is required. Use reserved, bound, active, stopping, completed, failed, blocked, or interrupted; use retire for retired state.'
  case "$status" in
    reserved|bound|active|stopping|completed|failed|blocked|interrupted) ;;
    retired) die "$EXIT_USAGE" 'use the retire command for retired state so retirement evidence and timestamps are recorded.' ;;
    *) die "$EXIT_USAGE" "unsupported status: $status. Use reserved, bound, active, stopping, completed, failed, blocked, or interrupted." ;;
  esac
  case "$status" in
    completed|failed|blocked|interrupted)
      [[ "$evidence_set" -eq 1 && -n "$evidence" ]] || die "$EXIT_USAGE" "terminal status $status requires non-empty --evidence. Record the validator, orchestration result, or other terminal evidence."
      ;;
    *)
      [[ "$evidence_set" -eq 0 ]] || die "$EXIT_USAGE" '--evidence is only valid when moving a worker to a terminal status.'
      ;;
  esac

  resolve_repo_root
  ensure_registry
  acquire_lock
  require_mutation_identity "$task_id" "$session_id" "$handle"
  current_status="$(current_worker_field "$task_id" 'status')"

  case "$current_status:$status" in
    reserved:reserved|reserved:failed|reserved:blocked|reserved:interrupted|bound:bound|bound:active|bound:stopping|bound:completed|bound:failed|bound:blocked|bound:interrupted|active:active|active:stopping|active:completed|active:failed|active:blocked|active:interrupted|stopping:stopping|stopping:completed|stopping:failed|stopping:blocked|stopping:interrupted) ;;
    reserved:*) die "$EXIT_CONFLICT" "invalid state transition for task-id $task_id: $current_status -> $status. Bind before activation and use retire for final retirement." ;;
    bound:*) die "$EXIT_CONFLICT" "invalid state transition for task-id $task_id: $current_status -> $status. Bind before activation and use retire for final retirement." ;;
    active:*) die "$EXIT_CONFLICT" "invalid state transition for task-id $task_id: $current_status -> $status." ;;
    stopping:*) die "$EXIT_CONFLICT" "invalid state transition for task-id $task_id: $current_status -> $status." ;;
    completed:*|failed:*|blocked:*|interrupted:*|retired:*) die "$EXIT_CONFLICT" "worker task-id $task_id is already terminal ($current_status). Terminal state is immutable; retire it and start a fresh task for later work." ;;
    *) die "$EXIT_SCHEMA" "worker task-id $task_id has unknown status: $current_status. Preserve the registry and repair it before retrying." ;;
  esac

  timestamp="$(now_utc)"
  write_registry_with_filter \
    '.workers |= map(if .task_id == $task_id then .status = $status | .updated_at = $timestamp | (if $status == "active" then .activated_at = (.activated_at // $timestamp) else . end) | (if $terminal then .terminal_at = $timestamp | .terminal_status = $status | .terminal_evidence = $evidence | .terminal_notes = (if $notes_set == 1 then $notes else .terminal_notes end) else . end) | (if $notes_set == 1 then .notes = $notes else . end) else . end) | .updated_at = $timestamp' \
    --arg task_id "$task_id" \
    --arg status "$status" \
    --arg timestamp "$timestamp" \
    --arg evidence "$evidence" \
    --arg notes "$notes" \
    --argjson terminal "$([[ "$status" == completed || "$status" == failed || "$status" == blocked || "$status" == interrupted ]] && printf true || printf false)" \
    --argjson notes_set "$notes_set"

  printf 'Updated worker task=%s status=%s\n' "$task_id" "$status"
}

command_retire() {
  local task_id=''
  local session_id=''
  local handle=''
  local evidence=''
  local notes=''
  local evidence_set=0
  local notes_set=0
  local current_status
  local current_evidence
  local timestamp

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --task-id.'; task_id="$2"; shift 2 ;;
      --session-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --session-id.'; session_id="$2"; shift 2 ;;
      --handle) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --handle.'; handle="$2"; shift 2 ;;
      --evidence|--terminal-evidence) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; evidence="$2"; evidence_set=1; shift 2 ;;
      --notes|--terminal-notes) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; notes="$2"; notes_set=1; shift 2 ;;
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown retire argument: $1. Use --help for usage." ;;
    esac
  done

  validate_identity task-id "$task_id"
  [[ -z "$session_id" ]] || validate_identity session-id "$session_id"
  [[ -z "$handle" ]] || validate_identity handle "$handle"
  if [[ "$evidence_set" -eq 1 && -z "$evidence" ]]; then
    die "$EXIT_USAGE" '--evidence must not be empty when supplied.'
  fi
  resolve_repo_root
  ensure_registry
  acquire_lock
  require_mutation_identity "$task_id" "$session_id" "$handle"
  current_status="$(current_worker_field "$task_id" 'status')"
  current_evidence="$(current_worker_field "$task_id" 'terminal_evidence')"

  if [[ "$current_status" == retired ]]; then
    printf 'Worker task=%s is already retired; no state change.\n' "$task_id"
    return "$EXIT_OK"
  fi
  case "$current_status" in
    reserved|bound|active|stopping)
      [[ "$evidence_set" -eq 1 && -n "$evidence" ]] || die "$EXIT_USAGE" 'retiring a non-terminal worker requires --evidence describing interruption, termination, or another terminal result.'
      ;;
    completed|failed|blocked|interrupted)
      [[ -n "$current_evidence" || ("$evidence_set" -eq 1 && -n "$evidence") ]] || die "$EXIT_USAGE" 'retiring this worker requires --evidence because no terminal evidence is recorded yet.'
      ;;
    *) die "$EXIT_SCHEMA" "worker task-id $task_id has unknown status: $current_status. Preserve the registry and repair it before retrying." ;;
  esac

  timestamp="$(now_utc)"
  write_registry_with_filter \
    '.workers |= map(if .task_id == $task_id then .status = "retired" | .retired_at = (.retired_at // $timestamp) | .terminal_at = (.terminal_at // $timestamp) | .terminal_status = (.terminal_status // "retired") | .terminal_evidence = (if $evidence_set == 1 then (if .terminal_evidence == "" then $evidence else .terminal_evidence + "\n" + $evidence end) else .terminal_evidence end) | .terminal_notes = (if $notes_set == 1 then (if .terminal_notes == "" then $notes else .terminal_notes + "\n" + $notes end) else .terminal_notes end) | .updated_at = $timestamp else . end) | .updated_at = $timestamp' \
    --arg task_id "$task_id" \
    --arg timestamp "$timestamp" \
    --arg evidence "$evidence" \
    --arg notes "$notes" \
    --argjson evidence_set "$evidence_set" \
    --argjson notes_set "$notes_set"

  printf 'Retired worker task=%s\n' "$task_id"
}

command_list() {
  local active_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --active) active_only=1; shift ;;
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown list argument: $1. Use --help for usage." ;;
    esac
  done
  resolve_repo_root
  ensure_registry
  if [[ "$active_only" -eq 1 ]]; then
    jq '.workers | map(select(.status == "reserved" or .status == "bound" or .status == "active" or .status == "stopping"))' "$REGISTRY_PATH"
  else
    jq '.workers' "$REGISTRY_PATH"
  fi
}

command_query() {
  local task_id=''
  local session_id=''
  local handle=''
  local active_only=0
  local count

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --task-id.'; task_id="$2"; shift 2 ;;
      --session-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --session-id.'; session_id="$2"; shift 2 ;;
      --handle) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --handle.'; handle="$2"; shift 2 ;;
      --active-only) active_only=1; shift ;;
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown query argument: $1. Use --help for usage." ;;
    esac
  done

  [[ -n "$task_id" || -n "$session_id" || -n "$handle" ]] || die "$EXIT_USAGE" 'query requires --task-id, --session-id, or --handle.'
  [[ -z "$task_id" ]] || validate_identity task-id "$task_id"
  [[ -z "$session_id" ]] || validate_identity session-id "$session_id"
  [[ -z "$handle" ]] || validate_identity handle "$handle"
  resolve_repo_root
  ensure_registry

  count="$(jq -r \
    --arg task_id "$task_id" \
    --arg session_id "$session_id" \
    --arg handle "$handle" \
    --argjson active_only "$active_only" \
    '[.workers[] | select(($task_id == "" or .task_id == $task_id) and ($session_id == "" or .session_id == $session_id) and ($handle == "" or .handle == $handle) and ($active_only == 0 or .status == "reserved" or .status == "bound" or .status == "active" or .status == "stopping"))] | length' \
    "$REGISTRY_PATH")"
  [[ "$count" -gt 0 ]] || die "$EXIT_NOT_FOUND" 'no matching current worker entry. Query the append-only ledger with jq and continue only the exact original task/session; never reuse a pruned identity.'
  jq \
    --arg task_id "$task_id" \
    --arg session_id "$session_id" \
    --arg handle "$handle" \
    --argjson active_only "$active_only" \
    '[.workers[] | select(($task_id == "" or .task_id == $task_id) and ($session_id == "" or .session_id == $session_id) and ($handle == "" or .handle == $handle) and ($active_only == 0 or .status == "reserved" or .status == "bound" or .status == "active" or .status == "stopping"))]' \
    "$REGISTRY_PATH"
}

command_prune() {
  local task_id=''
  local count
  local status
  local active_count
  local unretired_terminal_count
  local entry_word

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) [[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --task-id.'; task_id="$2"; shift 2 ;;
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown prune argument: $1. Use --help for usage." ;;
    esac
  done

  [[ -z "$task_id" ]] || validate_identity task-id "$task_id"
  resolve_repo_root
  ensure_registry
  acquire_lock

  if [[ -n "$task_id" ]]; then
    count="$(jq -r --arg task_id "$task_id" '[.workers[] | select(.task_id == $task_id)] | length' "$REGISTRY_PATH")"
    [[ "$count" -gt 0 ]] || die "$EXIT_NOT_FOUND" "worker task-id not found in current entries: $task_id. The identity ledger is intentionally retained after pruning."
    status="$(current_worker_field "$task_id" 'status')"
    case "$status" in
      reserved|bound|active|stopping)
        die "$EXIT_ACTIVE" "refusing to prune non-terminal worker task-id $task_id (status=$status). Stop or retire the exact worker first."
        ;;
      completed|failed|blocked|interrupted)
        die "$EXIT_ACTIVE" "refusing to prune terminal worker task-id $task_id before permanent retirement. Run retire with the exact bound identity first."
        ;;
      retired) ;;
      *) die "$EXIT_SCHEMA" "worker task-id $task_id has unknown status: $status. Preserve the registry and repair it before retrying." ;;
    esac
    write_registry_with_filter \
      '.workers |= map(select(.task_id != $task_id)) | .updated_at = $timestamp' \
      --arg task_id "$task_id" \
      --arg timestamp "$(now_utc)"
    printf 'Pruned retired worker task=%s; identity ledger retained.\n' "$task_id"
    return "$EXIT_OK"
  fi

  active_count="$(jq -r '[.workers[] | select(.status == "reserved" or .status == "bound" or .status == "active" or .status == "stopping")] | length' "$REGISTRY_PATH")"
  [[ "$active_count" -eq 0 ]] || die "$EXIT_ACTIVE" "refusing to prune while $active_count non-terminal worker entry remains. Stop, wait, record terminal state, and permanently retire every exact session first."
  unretired_terminal_count="$(jq -r '[.workers[] | select(.status == "completed" or .status == "failed" or .status == "blocked" or .status == "interrupted")] | length' "$REGISTRY_PATH")"
  [[ "$unretired_terminal_count" -eq 0 ]] || die "$EXIT_ACTIVE" "refusing to prune $unretired_terminal_count terminal worker entry before permanent retirement. Retire each exact bound identity first."

  count="$(jq -r '[.workers[] | select(.status == "retired")] | length' "$REGISTRY_PATH")"
  write_registry_with_filter \
    '.workers |= map(select(.status != "retired")) | .updated_at = $timestamp' \
    --arg timestamp "$(now_utc)"
  entry_word='entries'
  [[ "$count" -eq 1 ]] && entry_word='entry'
  printf 'Pruned %s retired worker %s; identity ledger retained.\n' "$count" "$entry_word"
}

command_assert_no_active() {
  local count
  local entry_word
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown assert-no-active argument: $1. Use --help for usage." ;;
    esac
  done
  resolve_repo_root
  ensure_registry
  count="$(jq -r '[.workers[] | select(.status == "reserved" or .status == "bound" or .status == "active" or .status == "stopping")] | length' "$REGISTRY_PATH")"
  if [[ "$count" -gt 0 ]]; then
    printf 'Active registry entries remain:\n' >&2
    jq '.workers | map(select(.status == "reserved" or .status == "bound" or .status == "active" or .status == "stopping"))' "$REGISTRY_PATH" >&2
    entry_word='entries'
    [[ "$count" -eq 1 ]] && entry_word='entry'
    die "$EXIT_ACTIVE" "registry still contains $count non-terminal worker $entry_word; collect evidence, stop/wait, record terminal state, and permanently retire each exact session before pruning."
  fi
  printf 'No reserved, bound, active, or stopping workers remain in %s\n' "$REGISTRY_PATH"
}

command_assert_empty() {
  local count
  local entry_word
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
      --help|-h) usage "$EXIT_OK" ;;
      *) die "$EXIT_USAGE" "unknown assert-empty argument: $1. Use --help for usage." ;;
    esac
  done
  resolve_repo_root
  ensure_registry
  count="$(jq -r '.workers | length' "$REGISTRY_PATH")"
  if [[ "$count" -gt 0 ]]; then
    printf 'Registry entries remain:\n' >&2
    jq '.workers' "$REGISTRY_PATH" >&2
    entry_word='entries'
    [[ "$count" -eq 1 ]] && entry_word='entry'
    die "$EXIT_ACTIVE" "registry is not empty ($count worker $entry_word); permanently retire terminal sessions and run prune before completion or blocked status."
  fi
  printf 'Registry is empty; append-only identity ledger remains for no-reuse safety.\n'
}

command_name="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$command_name" in
  init)
    exec "$INIT_SCRIPT" "$@"
    ;;
  reserve|register)
    require_commands
    command_reserve "$@"
    ;;
  bind|attach)
    require_commands
    command_bind "$@"
    ;;
  record-resume-handle)
    require_commands
    command_record_resume_handle "$@"
    ;;
  activate)
    require_commands
    command_activate "$@"
    ;;
  list)
    require_commands
    command_list "$@"
    ;;
  active)
    require_commands
    command_list --active "$@"
    ;;
  query)
    require_commands
    command_query "$@"
    ;;
  update)
    require_commands
    command_update "$@"
    ;;
  retire)
    require_commands
    command_retire "$@"
    ;;
  prune|clear)
    require_commands
    command_prune "$@"
    ;;
  assert-no-active)
    require_commands
    command_assert_no_active "$@"
    ;;
  assert-empty)
    require_commands
    command_assert_empty "$@"
    ;;
  ''|--help|-h)
    usage "$EXIT_USAGE"
    ;;
  *)
    die "$EXIT_USAGE" "unknown registry command: $command_name. Use --help for usage."
    ;;
esac
