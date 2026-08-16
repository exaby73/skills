#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC1091
set -euo pipefail
umask 077

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR='.'
[[ -n "$SCRIPT_DIR" ]] || SCRIPT_DIR='/'
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd -P)"
readonly SCRIPT_DIR

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_REPOSITORY=4
readonly EXIT_SCHEMA=5
readonly EXIT_LOCK=9
readonly EXIT_FILESYSTEM=10

REPO_INPUT='.'
REPO_ROOT=''
AGENTS_DIR=''
REGISTRY_DIR=''
REGISTRY_PATH=''
LOCK_DIR=''
GIT_DIR_REAL=''
GIT_COMMON_DIR_REAL=''
REPO_IDENTITY=''
REPO_CHECKOUT_PHYSICAL_ID=''
REPO_CHECKOUT_SEAL_PATH=''
REPO_CHECKOUT_SEAL=''
REPO_CHECKOUT_SEAL_PHYSICAL_ID=''
REPO_CHECKOUT_IDENTITY=''
PRINT_PATH=0
EXISTING_ONLY=0
LOCK_HELD=0

readonly SCHEMA_FILTER='
  def nonempty_string: type == "string" and length > 0;
  def safe_scope: type == "string" and length > 0 and (test("[\\r\\n]") | not);
  def safe_identity: type == "string" and test("^[A-Za-z0-9._:/-]+$");
  def safe_task_id: type == "string" and test("^[A-Za-z0-9._-]+$") and . != "." and . != "..";
  def safe_session: type == "string" and length > 0 and (startswith("-") | not);
  def positive_pid: type == "string" and test("^[1-9][0-9]*$");
  def process_instance: type == "string" and test("^(proc:[0-9]+|ps:[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4})$");
  def nullable_identity: . == null or (. | safe_identity);
  def nullable_session: . == null or (. | safe_session);
  def valid_status($status): ["reserved", "bound", "active", "retired"] | index($status) != null;
  def valid_terminal($status): ["completed", "failed", "blocked", "interrupted"] | index($status) != null;
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
  | try (
      (.schema_version == 3)
      and (.registry == "luna-local-review-loop")
      and (.repository_root | nonempty_string)
      and (.repository_identity | nonempty_string)
      and (.repository_checkout_identity | type == "string" and test("^gitdir:[0-9]+:[0-9]+(:seal:[0-9a-f]{64}(:seal-file:[0-9]+:[0-9]+)?)?$"))
      and (.created_at | nonempty_string)
      and (.updated_at | nonempty_string)
      and (.identity_ledger | type == "array")
      and (.workers | type == "array")
      and all($root.identity_ledger[];
        (.task_id | safe_task_id)
        and (.scope | safe_scope)
        and (.sandbox == "read-only" or .sandbox == "workspace-write")
        and (.retry_of == null or (.retry_of | safe_task_id))
        and (.session_id | nullable_session)
        and (valid_status(.status))
        and (.reserved_at | nonempty_string)
        and ((.bound_at == null) or (.bound_at | nonempty_string))
        and ((.activated_at == null) or (.activated_at | nonempty_string))
        and ((.terminal_at == null) or (.terminal_at | nonempty_string))
        and ((.retired_at == null) or (.retired_at | nonempty_string))
        and ((.terminal_status == null) or valid_terminal(.terminal_status))
        and (.terminal_evidence | type == "string")
        and (if .status == "reserved" then .session_id == null
             elif .status == "bound" then (.session_id != null and .bound_at != null and .activated_at == null)
             elif .status == "active" then (.session_id != null and .bound_at != null and .activated_at != null)
             else (.status == "retired" and .terminal_status != null and .terminal_at != null and .retired_at != null and (.terminal_evidence | nonempty_string))
             end)
      )
      and all($root.workers[];
        (.task_id | safe_task_id)
        and (.scope | safe_scope)
        and (.sandbox == "read-only" or .sandbox == "workspace-write")
        and (.retry_of == null or (.retry_of | safe_task_id))
        and (.session_id | nullable_session)
        and (valid_status(.status))
        and (.status != "retired")
        and (.created_at | nonempty_string)
        and (.updated_at | nonempty_string)
        and ((.bound_at == null) or (.bound_at | nonempty_string))
        and ((.activated_at == null) or (.activated_at | nonempty_string))
        and (.checkpoint_evidence | type == "string")
        and ((.invocation_pid == null and .invocation_token == null and .invocation_instance == null)
             or ((.invocation_pid | positive_pid) and (.invocation_token | safe_identity) and (.invocation_instance | process_instance)))
        and ((.active_child_pgid == null and .active_child_instance == null)
             or ((.active_child_pgid | positive_pid) and (.active_child_instance | process_instance) and (.invocation_pid | positive_pid) and (.invocation_token | safe_identity) and (.invocation_instance | process_instance)))
      )
      and (([$root.identity_ledger[].task_id] | length) == ([$root.identity_ledger[].task_id] | unique | length))
      and (([$root.identity_ledger[] | select(.session_id != null) | .session_id] | length) == ([$root.identity_ledger[] | select(.session_id != null) | .session_id] | unique | length))
      and (([$root.identity_ledger[] | select(.retry_of != null) | .retry_of] | length) == ([$root.identity_ledger[] | select(.retry_of != null) | .retry_of] | unique | length))
      and (([$root.identity_ledger[] | select(.retry_of == null) | .scope] | length) == ([$root.identity_ledger[] | select(.retry_of == null) | .scope] | unique | length))
      and (([$root.workers[].task_id] | length) == ([$root.workers[].task_id] | unique | length))
      and (([$root.workers[].scope] | length) == ([$root.workers[].scope] | unique | length))
      and (([$root.workers[] | select(.session_id != null) | .session_id] | length) == ([$root.workers[] | select(.session_id != null) | .session_id] | unique | length))
      and valid_retry_chain($root.identity_ledger)
      and all($root.workers[];
        . as $worker
        | any($root.identity_ledger[];
          .task_id == $worker.task_id
          and .scope == $worker.scope
          and .sandbox == $worker.sandbox
          and .retry_of == $worker.retry_of
          and .session_id == $worker.session_id
          and .status == $worker.status
          and .bound_at == $worker.bound_at
          and .activated_at == $worker.activated_at
        )
      )
      and all($root.identity_ledger[];
        . as $row
        | if .status == "retired" then true
          else any($root.workers[];
            .task_id == $row.task_id
            and .scope == $row.scope
            and .sandbox == $row.sandbox
            and .retry_of == $row.retry_of
            and .session_id == $row.session_id
            and .status == $row.status
            and .bound_at == $row.bound_at
            and .activated_at == $row.activated_at
          )
          end
      )
    ) catch false
  | .
'

usage() {
  local exit_code="${1:-0}"
  cat <<'EOF'
Usage:
  init.sh [--repo PATH|-C PATH] [--print-path]
  init.sh --existing-path [--repo PATH|-C PATH]

Initialize or validate project-local Luna registry.
--existing-path prints an existing registry without launch-only prerequisites.
Init may add exactly one .agents/agent-registry/ line to root .gitignore.
The registry-local .gitignore is private and ends with '*'.
EOF
  exit "$exit_code"
}

die() {
  local exit_code="$1"
  shift
  printf 'luna-local-review-loop: ERROR [%s] %s\n' "$exit_code" "$*" >&2
  exit "$exit_code"
}

now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

regular_file_link_count() {
  local path="$1" count=''
  if count="$(stat -c '%h' "$path" 2>/dev/null)"; then :
  elif count="$(stat -f '%l' "$path" 2>/dev/null)"; then :
  else return 1
  fi
  [[ "$count" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$count"
}

path_owner_mode() {
  local path="$1" metadata=''
  if metadata="$(stat -c '%u %a' "$path" 2>/dev/null)" && [[ "$metadata" =~ ^[0-9]+[[:space:]][0-7]+$ ]]; then
    printf '%s\n' "$metadata"; return 0
  fi
  if metadata="$(stat -f '%u %Lp' "$path" 2>/dev/null)" && [[ "$metadata" =~ ^[0-9]+[[:space:]][0-7]+$ ]]; then
    printf '%s\n' "$metadata"; return 0
  fi
  return 1
}

require_owned_directory() {
  local path="$1" label="$2" metadata='' owner='' mode=''
  [[ -d "$path" && ! -L "$path" ]] || die "$EXIT_FILESYSTEM" "$label must be a real directory: $path."
  metadata="$(path_owner_mode "$path")" || die "$EXIT_FILESYSTEM" "cannot inspect $label ownership and permissions: $path."
  read -r owner mode <<<"$metadata"
  [[ "$owner" == "$UID" ]] || die "$EXIT_FILESYSTEM" "$label must be owned by UID $UID: $path is owned by UID $owner."
  (( (8#$mode & 022) == 0 )) || die "$EXIT_FILESYSTEM" "$label must not be group- or world-writable: $path has mode $mode."
}

require_private_file() {
  local path="$1" label="$2" metadata='' owner='' mode=''
  [[ -f "$path" && ! -L "$path" ]] || die "$EXIT_FILESYSTEM" "$label must be a real regular file: $path."
  [[ "$(regular_file_link_count "$path")" == 1 ]] || die "$EXIT_FILESYSTEM" "$label must have exactly one hard link: $path."
  metadata="$(path_owner_mode "$path")" || die "$EXIT_FILESYSTEM" "cannot inspect $label ownership and permissions: $path."
  read -r owner mode <<<"$metadata"
  [[ "$owner" == "$UID" ]] || die "$EXIT_FILESYSTEM" "$label must be owned by UID $UID: $path is owned by UID $owner."
  [[ "$mode" == 600 ]] || die "$EXIT_FILESYSTEM" "$label must have mode 0600: $path has mode $mode."
}

require_commands() {
  local missing='' command_name
  local required_commands=(bash dirname git jq mkdir rm rmdir mv ln kill ps sleep awk shasum stat cat mktemp date chmod sed wc)
  if [[ "$EXISTING_ONLY" -eq 0 ]]; then required_commands+=(od tr sort head mkfifo); fi
  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing="${missing}${missing:+, }${command_name}"
  done
  [[ -z "$missing" ]] || die "$EXIT_PREREQUISITE" "missing runtime prerequisite(s): $missing."
  if [[ "$EXISTING_ONLY" -eq 0 ]] && ! command -v "${CODEX_BIN:-codex}" >/dev/null 2>&1; then
    die "$EXIT_PREREQUISITE" "Codex CLI not found: ${CODEX_BIN:-codex}. Use --existing-path only for registry recovery."
  fi
  [[ "${BASH_VERSINFO[0]}" -ge 3 ]] || die "$EXIT_PREREQUISITE" "Bash 3 or newer is required (detected ${BASH_VERSION})."
}

resolve_paths() {
  local candidate
  [[ -d "$REPO_INPUT" ]] || die "$EXIT_REPOSITORY" "repository path does not exist or is not a directory: $REPO_INPUT."
  candidate="$(cd -P "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot access repository path: $REPO_INPUT."
  REPO_ROOT="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)" || die "$EXIT_REPOSITORY" "path is not inside a Git repository: $candidate."
  REPO_ROOT="$(cd -P "$REPO_ROOT" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot resolve repository root: $candidate."
  [[ -d "$REPO_ROOT" && ! -L "$REPO_ROOT" ]] || die "$EXIT_REPOSITORY" "repository root must be a real directory: $REPO_ROOT."
  case "$candidate" in
    "$REPO_ROOT" | "$REPO_ROOT"/*) ;;
    *) die "$EXIT_REPOSITORY" "Git recorded a different checkout root than the supplied path: $candidate -> $REPO_ROOT." ;;
  esac
  AGENTS_DIR="$REPO_ROOT/.agents"
  REGISTRY_DIR="$AGENTS_DIR/agent-registry"
  REGISTRY_PATH="$REGISTRY_DIR/registry.json"
  LOCK_DIR="$REGISTRY_DIR/.lock"
}

resolve_git_identity() {
  local git_dir common_dir backlink='' backlink_parent='' backlink_name='' backlink_real='' gitdir_backlink=''
  local common_identity='' checkout_identity='' ordinary_git_dir=''
  git_dir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || die "$EXIT_REPOSITORY" "cannot locate Git administration directory for $REPO_ROOT."
  GIT_DIR_REAL="$(cd -P "$git_dir" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot resolve Git administration directory: $git_dir."
  [[ -d "$GIT_DIR_REAL" && ! -L "$GIT_DIR_REAL" ]] || die "$EXIT_REPOSITORY" "Git administration directory must be real: $GIT_DIR_REAL."
  common_dir="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)" || die "$EXIT_REPOSITORY" "cannot locate Git common directory for $REPO_ROOT."
  case "$common_dir" in /*) ;; *) common_dir="$REPO_ROOT/$common_dir" ;; esac
  GIT_COMMON_DIR_REAL="$(cd -P "$common_dir" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot resolve Git common directory: $common_dir."
  [[ -d "$GIT_COMMON_DIR_REAL" && ! -L "$GIT_COMMON_DIR_REAL" ]] || die "$EXIT_REPOSITORY" "Git common directory must be real: $GIT_COMMON_DIR_REAL."
  require_owned_directory "$GIT_DIR_REAL" 'Git administration directory'
  require_owned_directory "$GIT_COMMON_DIR_REAL" 'Git common directory'
  if [[ -f "$REPO_ROOT/.git" ]]; then
    [[ ! -L "$REPO_ROOT/.git" ]] || die "$EXIT_REPOSITORY" "linked-worktree .git file must not be a symlink: $REPO_ROOT/.git."
    [[ "$(regular_file_link_count "$REPO_ROOT/.git")" == 1 ]] || die "$EXIT_REPOSITORY" "linked-worktree .git file must have exactly one hard link: $REPO_ROOT/.git."
    IFS= read -r backlink <"$REPO_ROOT/.git" || die "$EXIT_REPOSITORY" "cannot read linked-worktree .git backlink: $REPO_ROOT/.git."
    [[ "$backlink" == "gitdir: "* ]] || die "$EXIT_REPOSITORY" "linked-worktree .git file has invalid format: $REPO_ROOT/.git."
    backlink="${backlink#gitdir: }"
    case "$backlink" in /*) ;; *) backlink="$REPO_ROOT/$backlink" ;; esac
    backlink_parent="${backlink%/*}"; backlink_name="${backlink##*/}"
    [[ -n "$backlink_parent" && -n "$backlink_name" ]] || die "$EXIT_REPOSITORY" "linked-worktree .git backlink is incomplete: $REPO_ROOT/.git."
    backlink_parent="$(cd -P "$backlink_parent" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot resolve linked-worktree .git backlink: $backlink."
    [[ "$backlink_parent/$backlink_name" == "$GIT_DIR_REAL" ]] || die "$EXIT_REPOSITORY" "linked-worktree .git backlink does not match Git evidence: $REPO_ROOT/.git."
    [[ -f "$GIT_DIR_REAL/gitdir" && ! -L "$GIT_DIR_REAL/gitdir" ]] || die "$EXIT_REPOSITORY" "linked-worktree Git administration backlink is missing or unsafe: $GIT_DIR_REAL/gitdir."
    [[ "$(regular_file_link_count "$GIT_DIR_REAL/gitdir")" == 1 ]] || die "$EXIT_REPOSITORY" "linked-worktree Git administration backlink must have exactly one hard link: $GIT_DIR_REAL/gitdir."
    IFS= read -r gitdir_backlink <"$GIT_DIR_REAL/gitdir" || die "$EXIT_REPOSITORY" "cannot read linked-worktree Git administration backlink: $GIT_DIR_REAL/gitdir."
    case "$gitdir_backlink" in /*) ;; *) gitdir_backlink="$GIT_DIR_REAL/$gitdir_backlink" ;; esac
    backlink_parent="${gitdir_backlink%/*}"; backlink_name="${gitdir_backlink##*/}"
    backlink_parent="$(cd -P "$backlink_parent" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot resolve linked-worktree administration backlink: $gitdir_backlink."
    [[ "$backlink_parent/$backlink_name" == "$REPO_ROOT/.git" ]] || die "$EXIT_REPOSITORY" "linked-worktree administration backlink does not name this checkout: $GIT_DIR_REAL/gitdir."
  else
    [[ -d "$REPO_ROOT/.git" && ! -L "$REPO_ROOT/.git" ]] || die "$EXIT_REPOSITORY" "ordinary checkout .git must be a real directory: $REPO_ROOT/.git."
    ordinary_git_dir="$(cd -P "$REPO_ROOT/.git" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot resolve ordinary checkout .git directory."
    [[ "$ordinary_git_dir" == "$GIT_DIR_REAL" ]] || die "$EXIT_REPOSITORY" "ordinary checkout .git evidence does not match Git administration directory."
  fi
  if checkout_identity="$(stat -c '%d:%i' "$GIT_DIR_REAL" 2>/dev/null)"; then :
  elif checkout_identity="$(stat -f '%d:%i' "$GIT_DIR_REAL" 2>/dev/null)"; then :
  else die "$EXIT_REPOSITORY" "cannot derive physical Git checkout identity: $GIT_DIR_REAL."; fi
  [[ "$checkout_identity" =~ ^[0-9]+:[0-9]+$ ]] || die "$EXIT_REPOSITORY" "physical Git checkout identity is invalid: $checkout_identity."
  if common_identity="$(stat -c '%d:%i' "$GIT_COMMON_DIR_REAL" 2>/dev/null)"; then :
  elif common_identity="$(stat -f '%d:%i' "$GIT_COMMON_DIR_REAL" 2>/dev/null)"; then :
  else die "$EXIT_REPOSITORY" "cannot derive Git common-directory identity: $GIT_COMMON_DIR_REAL."; fi
  [[ "$common_identity" =~ ^[0-9]+:[0-9]+$ ]] || die "$EXIT_REPOSITORY" "Git common-directory identity is invalid: $common_identity."
  REPO_CHECKOUT_PHYSICAL_ID="gitdir:$checkout_identity"
  REPO_IDENTITY="git-common:$common_identity"
  REPO_CHECKOUT_SEAL_PATH="$GIT_DIR_REAL/.luna-checkout-identity"
}

physical_file_identity() {
  local path="$1"
  local identity=''
  if identity="$(stat -c '%d:%i' "$path" 2>/dev/null)"; then :
  elif identity="$(stat -f '%d:%i' "$path" 2>/dev/null)"; then :
  else return 1; fi
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s\n' "$identity"
}

validate_checkout_seal_file() {
  local seal=''
  local extra=''
  local first_status=0
  local seal_identity=''
  [[ -e "$REPO_CHECKOUT_SEAL_PATH" || -L "$REPO_CHECKOUT_SEAL_PATH" ]] || return 1
  require_private_file "$REPO_CHECKOUT_SEAL_PATH" 'Git checkout identity seal'
  exec 9<"$REPO_CHECKOUT_SEAL_PATH" || die "$EXIT_FILESYSTEM" "cannot open Git checkout identity seal: $REPO_CHECKOUT_SEAL_PATH."
  IFS= read -r seal <&9 || first_status=$?
  if [[ "$first_status" -ne 0 && -z "$seal" ]]; then
    exec 9<&-
    die "$EXIT_FILESYSTEM" "Git checkout identity seal is empty: $REPO_CHECKOUT_SEAL_PATH."
  fi
  if IFS= read -r extra <&9; then
    exec 9<&-
    die "$EXIT_FILESYSTEM" "Git checkout identity seal must contain one lowercase-hex line: $REPO_CHECKOUT_SEAL_PATH."
  fi
  exec 9<&-
  [[ "$seal" =~ ^[0-9a-f]{64}$ ]] || die "$EXIT_FILESYSTEM" "Git checkout identity seal must be exactly 256-bit lowercase hex: $REPO_CHECKOUT_SEAL_PATH."
  seal_identity="$(physical_file_identity "$REPO_CHECKOUT_SEAL_PATH")" || die "$EXIT_FILESYSTEM" "cannot derive Git checkout identity seal device/inode: $REPO_CHECKOUT_SEAL_PATH."
  REPO_CHECKOUT_SEAL="$(shasum -a 256 "$REPO_CHECKOUT_SEAL_PATH" | awk '{print $1}')" || die "$EXIT_FILESYSTEM" "cannot digest Git checkout identity seal: $REPO_CHECKOUT_SEAL_PATH."
  [[ "$REPO_CHECKOUT_SEAL" =~ ^[0-9a-f]{64}$ ]] || die "$EXIT_FILESYSTEM" "Git checkout identity seal digest is invalid: $REPO_CHECKOUT_SEAL_PATH."
  REPO_CHECKOUT_SEAL_PHYSICAL_ID="seal-file:$seal_identity"
  REPO_CHECKOUT_IDENTITY="$REPO_CHECKOUT_PHYSICAL_ID:seal:$REPO_CHECKOUT_SEAL:$REPO_CHECKOUT_SEAL_PHYSICAL_ID"
}

create_checkout_seal() {
  local temp_path=''
  local random_seal=''
  [[ "$EXISTING_ONLY" -eq 0 ]] || die "$EXIT_FILESYSTEM" "Git checkout identity seal is missing: $REPO_CHECKOUT_SEAL_PATH. Existing-path recovery is validation-only; recover with the previous skill version or run normal init after proving the checkout."
  [[ ! -e "$REPO_CHECKOUT_SEAL_PATH" && ! -L "$REPO_CHECKOUT_SEAL_PATH" ]] || { validate_checkout_seal_file; return 0; }
  temp_path="$(mktemp "$GIT_DIR_REAL/.luna-checkout-identity.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create Git checkout identity seal temporary file: $GIT_DIR_REAL."
  chmod 0600 "$temp_path" || { rm -f "$temp_path"; die "$EXIT_FILESYSTEM" "cannot restrict Git checkout identity seal temporary file: $temp_path."; }
  random_seal="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')" || { rm -f "$temp_path"; die "$EXIT_FILESYSTEM" 'cannot generate Git checkout identity seal entropy.'; }
  [[ "$random_seal" =~ ^[0-9a-f]{64}$ ]] || { rm -f "$temp_path"; die "$EXIT_FILESYSTEM" 'generated Git checkout identity seal is not 256-bit lowercase hex.'; }
  printf '%s\n' "$random_seal" >"$temp_path" || { rm -f "$temp_path"; die "$EXIT_FILESYSTEM" "cannot write Git checkout identity seal temporary file: $temp_path."; }
  if ! ln -n "$temp_path" "$REPO_CHECKOUT_SEAL_PATH" 2>/dev/null; then
    rm -f "$temp_path"
    [[ -e "$REPO_CHECKOUT_SEAL_PATH" || -L "$REPO_CHECKOUT_SEAL_PATH" ]] || die "$EXIT_FILESYSTEM" "Git checkout identity seal appeared or could not be created: $REPO_CHECKOUT_SEAL_PATH."
    validate_checkout_seal_file
    return 0
  fi
  rm "$temp_path" || die "$EXIT_FILESYSTEM" "cannot release Git checkout identity seal temporary link: $temp_path."
  validate_checkout_seal_file
}

ensure_checkout_seal() {
  if [[ -e "$REPO_CHECKOUT_SEAL_PATH" || -L "$REPO_CHECKOUT_SEAL_PATH" ]]; then
    validate_checkout_seal_file
  else
    create_checkout_seal
  fi
}

ensure_boundary() {
  local canonical metadata mode
  if [[ "$EXISTING_ONLY" -eq 1 ]]; then
    [[ -d "$AGENTS_DIR" && ! -L "$AGENTS_DIR" ]] || die "$EXIT_FILESYSTEM" "project agent directory does not exist as a real directory: $AGENTS_DIR. Run init before registry recovery lookup."
  elif [[ ! -e "$AGENTS_DIR" && ! -L "$AGENTS_DIR" ]]; then
    mkdir -m 0700 "$AGENTS_DIR" || die "$EXIT_FILESYSTEM" "cannot create project agent directory: $AGENTS_DIR."
  fi
  require_owned_directory "$AGENTS_DIR" 'project agent directory'
  canonical="$(cd -P "$AGENTS_DIR" 2>/dev/null && pwd -P)" || die "$EXIT_FILESYSTEM" "cannot resolve project agent directory: $AGENTS_DIR."
  [[ "$canonical" == "$AGENTS_DIR" ]] || die "$EXIT_FILESYSTEM" "project agent directory escapes repository root: $AGENTS_DIR."
  if [[ "$EXISTING_ONLY" -eq 1 ]]; then
    [[ -d "$REGISTRY_DIR" && ! -L "$REGISTRY_DIR" ]] || die "$EXIT_FILESYSTEM" "project-local registry directory does not exist as a real directory: $REGISTRY_DIR. Run init before registry recovery lookup."
  elif [[ ! -e "$REGISTRY_DIR" && ! -L "$REGISTRY_DIR" ]]; then
    mkdir -m 0700 "$REGISTRY_DIR" || die "$EXIT_FILESYSTEM" "cannot create project-local registry directory: $REGISTRY_DIR."
  fi
  require_owned_directory "$REGISTRY_DIR" 'project-local registry directory'
  canonical="$(cd -P "$REGISTRY_DIR" 2>/dev/null && pwd -P)" || die "$EXIT_FILESYSTEM" "cannot resolve project-local registry directory: $REGISTRY_DIR."
  [[ "$canonical" == "$REGISTRY_DIR" ]] || die "$EXIT_FILESYSTEM" "project-local registry directory escapes repository root: $REGISTRY_DIR."
  metadata="$(path_owner_mode "$REGISTRY_DIR")" || die "$EXIT_FILESYSTEM" "cannot inspect project-local registry directory: $REGISTRY_DIR."
  read -r _ mode <<<"$metadata"
  [[ "$mode" == 700 ]] || die "$EXIT_FILESYSTEM" "project-local registry directory must have mode 0700: $REGISTRY_DIR has mode $mode."
}

validate_gitignore_target() {
  local ignore_path="$REPO_ROOT/.gitignore" metadata='' owner='' mode=''
  [[ ! -L "$ignore_path" ]] || die "$EXIT_FILESYSTEM" "repository root .gitignore must not be a symlink: $ignore_path."
  [[ ! -e "$ignore_path" ]] && return 0
  [[ -f "$ignore_path" ]] || die "$EXIT_FILESYSTEM" "repository root .gitignore must be a regular file: $ignore_path."
  [[ "$(regular_file_link_count "$ignore_path")" == 1 ]] || die "$EXIT_FILESYSTEM" "repository root .gitignore must have exactly one hard link: $ignore_path."
  metadata="$(path_owner_mode "$ignore_path")" || die "$EXIT_FILESYSTEM" "cannot inspect repository root .gitignore: $ignore_path."
  read -r owner mode <<<"$metadata"
  [[ "$owner" == "$UID" ]] || die "$EXIT_FILESYSTEM" "repository root .gitignore must be owned by UID $UID: $ignore_path is owned by UID $owner."
  (( (8#$mode & 022) == 0 )) || die "$EXIT_FILESYSTEM" "repository root .gitignore must not be group- or world-writable: $ignore_path has mode $mode."
}

ensure_gitignore() {
  local ignore_path="$REPO_ROOT/.gitignore" temp_path mode='644' metadata='' owner=''
  validate_gitignore_target
  if [[ -e "$ignore_path" ]]; then
    metadata="$(path_owner_mode "$ignore_path")" || die "$EXIT_FILESYSTEM" "cannot inspect repository root .gitignore: $ignore_path."
    read -r owner mode <<<"$metadata"
  else
    (set -o noclobber; : >"$ignore_path") 2>/dev/null || die "$EXIT_FILESYSTEM" "cannot create repository root .gitignore: $ignore_path."
    chmod 0644 "$ignore_path" || die "$EXIT_FILESYSTEM" "cannot set new repository root .gitignore mode: $ignore_path."
  fi
  temp_path="$(mktemp "$REGISTRY_DIR/.gitignore.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create .gitignore temporary file in $REGISTRY_DIR."
  if ! awk -v target='.agents/agent-registry/' '$0 != target { print }' "$ignore_path" >"$temp_path"; then rm -f "$temp_path"; die "$EXIT_FILESYSTEM" "cannot read repository root .gitignore: $ignore_path."; fi
  printf '%s\n' '.agents/agent-registry/' >>"$temp_path" || die "$EXIT_FILESYSTEM" "cannot update repository root .gitignore: $ignore_path."
  chmod "$mode" "$temp_path" || die "$EXIT_FILESYSTEM" "cannot preserve repository root .gitignore mode: $ignore_path."
  mv "$temp_path" "$ignore_path" || die "$EXIT_FILESYSTEM" "cannot publish repository root .gitignore: $ignore_path."
}

private_gitignore_has_final_star() {
  local ignore_path="$1"
  awk 'NF { last = $0 } END { exit(last == "*" ? 0 : 1) }' "$ignore_path" >/dev/null 2>&1
}

validate_private_gitignore_target() {
  local ignore_path="$REGISTRY_DIR/.gitignore"
  [[ -e "$ignore_path" || -L "$ignore_path" ]] || return 1
  require_private_file "$ignore_path" 'registry-local .gitignore'
  private_gitignore_has_final_star "$ignore_path" || die "$EXIT_FILESYSTEM" "registry-local .gitignore must end with a '*' rule: $ignore_path."
}

ensure_private_gitignore() {
  local ignore_path="$REGISTRY_DIR/.gitignore"
  local temp_path=''
  if [[ -e "$ignore_path" || -L "$ignore_path" ]]; then
    require_private_file "$ignore_path" 'registry-local .gitignore'
    if private_gitignore_has_final_star "$ignore_path"; then
      return 0
    fi
    temp_path="$(mktemp "$REGISTRY_DIR/.gitignore.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create registry-local .gitignore temporary file: $REGISTRY_DIR."
    if ! cat "$ignore_path" >"$temp_path" || ! printf '%s\n' '*' >>"$temp_path"; then
      rm -f "$temp_path"
      die "$EXIT_FILESYSTEM" "cannot update registry-local .gitignore: $ignore_path."
    fi
    chmod 0600 "$temp_path" || die "$EXIT_FILESYSTEM" "cannot restrict registry-local .gitignore temporary file: $temp_path."
    mv "$temp_path" "$ignore_path" || die "$EXIT_FILESYSTEM" "cannot publish registry-local .gitignore: $ignore_path."
    return 0
  fi
  (set -o noclobber; : >"$ignore_path") 2>/dev/null || die "$EXIT_FILESYSTEM" "cannot create registry-local .gitignore: $ignore_path."
  chmod 0600 "$ignore_path" || die "$EXIT_FILESYSTEM" "cannot restrict registry-local .gitignore: $ignore_path."
  printf '%s\n' '*' >"$ignore_path" || die "$EXIT_FILESYSTEM" "cannot write registry-local .gitignore: $ignore_path."
  require_private_file "$ignore_path" 'registry-local .gitignore'
}

validate_registry_ignore_rules() {
  local ignore_path="$REPO_ROOT/.gitignore"
  local target='.agents/agent-registry/'
  local target_count=''
  local representative=''
  [[ -f "$ignore_path" && ! -L "$ignore_path" ]] || die "$EXIT_FILESYSTEM" "repository root .gitignore is required for registry recovery: $ignore_path."
  target_count="$(awk -v target="$target" '$0 == target { count++ } END { print count + 0 }' "$ignore_path")" || die "$EXIT_FILESYSTEM" "cannot inspect repository root .gitignore: $ignore_path."
  [[ "$target_count" == 1 ]] || die "$EXIT_FILESYSTEM" "repository root .gitignore must contain exactly one $target rule: $ignore_path."
  for representative in \
    '.agents/agent-registry/.gitignore' \
    '.agents/agent-registry/registry.json' \
    '.agents/agent-registry/.lock' \
    '.agents/agent-registry/.lock-owner.candidate' \
    '.agents/agent-registry/artifacts/example/nested/result.json'; do
    git -C "$REPO_ROOT" check-ignore --no-index -q -- "$representative" || die "$EXIT_FILESYSTEM" "registry path is not ignored by the project root .gitignore: $representative."
  done
}

validate_present_registry_ignore_negations() {
  local ignore_path="$REPO_ROOT/.gitignore"
  local target='.agents/agent-registry/'
  local target_count=''
  local representative=''
  [[ -f "$ignore_path" && ! -L "$ignore_path" ]] || return 0
  target_count="$(awk -v target="$target" '$0 == target { count++ } END { print count + 0 }' "$ignore_path")" || die "$EXIT_FILESYSTEM" "cannot inspect repository root .gitignore: $ignore_path."
  [[ "$target_count" == 1 ]] || return 0
  if awk '$0 ~ /^!\.agents\/agent-registry(\/|$)/ { found = 1 } END { exit(found ? 0 : 1) }' "$ignore_path"; then
    die "$EXIT_FILESYSTEM" "repository root .gitignore contains an unsafe registry negation: $ignore_path."
  fi
  for representative in \
    '.agents/agent-registry/.gitignore' \
    '.agents/agent-registry/registry.json' \
    '.agents/agent-registry/.lock' \
    '.agents/agent-registry/.lock-owner.candidate' \
    '.agents/agent-registry/artifacts/example/nested/result.json'; do
    git -C "$REPO_ROOT" check-ignore --no-index -q -- "$representative" || die "$EXIT_FILESYSTEM" "repository root .gitignore contains an unsafe negation for registry path: $representative."
  done
}

require_project_skills() {
  local code_reviewer="$REPO_ROOT/.agents/skills/code-reviewer/SKILL.md" caveman="$REPO_ROOT/.agents/skills/caveman/SKILL.md" missing='' path
  for path in "$REPO_ROOT/.agents" "$REPO_ROOT/.agents/skills" "$REPO_ROOT/.agents/skills/code-reviewer" "$REPO_ROOT/.agents/skills/caveman"; do
    [[ ! -L "$path" ]] || die "$EXIT_PREREQUISITE" "project skill path must be a real directory, not a symlink: $path."
  done
  [[ -f "$code_reviewer" && ! -L "$code_reviewer" ]] || missing="${missing}${missing:+, }code-reviewer"
  [[ -f "$caveman" && ! -L "$caveman" ]] || missing="${missing}${missing:+, }caveman"
  [[ -z "$missing" ]] || die "$EXIT_PREREQUISITE" "missing project-local skill(s): $missing. Install explicitly with '-a universal', review resulting changes, then retry."
}

pid_is_confirmed_nonexistent() {
  local owner_pid="$1" kill_error='' process_state=''
  if process_state="$(ps -p "$owner_pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"; then
    case "$process_state" in Z* | '') return 0 ;; ?*) return 1 ;; esac
  fi
  if kill_error="$(LC_ALL=C kill -0 "$owner_pid" 2>&1)"; then return 1; fi
  case "$kill_error" in *[Nn]o\ such\ process* | *[Nn]o\ such\ file* | *[Nn]o\ process*) return 0 ;; *) return 1 ;; esac
}

# shellcheck source=registry-lock.sh
source "$SCRIPT_DIR/registry-lock.sh"

write_new_registry() {
  local timestamp temp_path
  ensure_checkout_seal
  [[ -n "$REPO_CHECKOUT_IDENTITY" ]] || die "$EXIT_SCHEMA" 'new registry has no durable checkout identity.'
  timestamp="$(now_utc)"
  temp_path="$(mktemp "$REGISTRY_DIR/.registry.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create registry temporary file in $REGISTRY_DIR."
  jq -n --arg root "$REPO_ROOT" --arg identity "$REPO_IDENTITY" --arg checkout_identity "$REPO_CHECKOUT_IDENTITY" --arg timestamp "$timestamp" \
    '{schema_version:3,registry:"luna-local-review-loop",repository_root:$root,repository_identity:$identity,repository_checkout_identity:$checkout_identity,created_at:$timestamp,updated_at:$timestamp,identity_ledger:[],workers:[]}' >"$temp_path" || die "$EXIT_FILESYSTEM" "cannot write new registry: $REGISTRY_PATH."
  jq -e "$SCHEMA_FILTER" "$temp_path" >/dev/null 2>&1 || die "$EXIT_SCHEMA" 'new registry failed schema validation.'
  chmod 0600 "$temp_path" || die "$EXIT_FILESYSTEM" "cannot restrict new registry permissions: $temp_path."
  mv "$temp_path" "$REGISTRY_PATH" || die "$EXIT_FILESYSTEM" "cannot publish new registry: $REGISTRY_PATH."
}

legacy_v1_status_is_known() {
  jq -e '(.schema_version == 1) and (.registry == "luna-local-review-loop") and (.workers | type == "array") and all(.workers[]; .status as $status | (["reserved","bound","active","stopping","completed","failed","blocked","interrupted","retired"] | index($status) != null))' "$REGISTRY_PATH" >/dev/null 2>&1
}

migrate_v1_if_safe() {
  local live_count worker_count recorded_root timestamp temp_path
  legacy_v1_status_is_known || die "$EXIT_SCHEMA" "project-local schema-v1 registry cannot be validated safely: $REGISTRY_PATH. Preserve it and recover with the previous skill version."
  worker_count="$(jq '.workers | length' "$REGISTRY_PATH")"
  live_count="$(jq '[.workers[] | select(.status == "reserved" or .status == "bound" or .status == "active" or .status == "stopping")] | length' "$REGISTRY_PATH")"
  [[ "$live_count" -eq 0 ]] || die "$EXIT_SCHEMA" "project-local schema-v1 registry contains $live_count live worker(s): $REGISTRY_PATH. Retire or recover every live worker with the previous skill version, verify registry emptiness, then rerun this version. Registry unchanged."
  [[ "$worker_count" -eq 0 ]] || die "$EXIT_SCHEMA" "project-local schema-v1 registry is not empty: $REGISTRY_PATH. Automatic migration requires proven ownership and zero historical worker rows; recover it with the previous skill version. Registry unchanged."
  recorded_root="$(jq -r '.repository_root // empty' "$REGISTRY_PATH")"
  [[ "$recorded_root" == "$REPO_ROOT" ]] || die "$EXIT_REPOSITORY" "project-local schema-v1 registry ownership is not proven: $REGISTRY_PATH. Recover it with the previous skill version before replacing it."
  [[ "$EXISTING_ONLY" -eq 0 ]] || die "$EXIT_SCHEMA" "schema-v1 migration is disabled for --existing-path recovery: $REGISTRY_PATH. Registry unchanged; run normal init only after recovery with the previous skill version."
  ensure_checkout_seal
  timestamp="$(now_utc)"; temp_path="$(mktemp "$REGISTRY_DIR/.registry-migration.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create schema migration temporary file in $REGISTRY_DIR."
  jq -n --arg root "$REPO_ROOT" --arg identity "$REPO_IDENTITY" --arg checkout_identity "$REPO_CHECKOUT_IDENTITY" --arg timestamp "$timestamp" '{schema_version:3,registry:"luna-local-review-loop",repository_root:$root,repository_identity:$identity,repository_checkout_identity:$checkout_identity,created_at:$timestamp,updated_at:$timestamp,identity_ledger:[],workers:[]}' >"$temp_path" || die "$EXIT_SCHEMA" "cannot prepare schema-v1 migration: $REGISTRY_PATH."
  chmod 0600 "$temp_path" || die "$EXIT_FILESYSTEM" "cannot restrict schema migration file: $temp_path."
  mv "$temp_path" "$REGISTRY_PATH" || die "$EXIT_FILESYSTEM" "cannot publish schema-v1 migration: $REGISTRY_PATH."
}

migrate_v2_if_safe() {
	local worker_count ledger_count recorded_root temp_path timestamp
	jq -e '(.schema_version == 2) and (.registry == "luna-local-review-loop") and (.repository_root | type == "string" and length > 0) and (.repository_identity | type == "string" and length > 0) and (.identity_ledger | type == "array") and (.workers | type == "array")' "$REGISTRY_PATH" >/dev/null 2>&1 || die "$EXIT_SCHEMA" "schema version 2 registry cannot be validated safely: $REGISTRY_PATH. Preserve it and recover with the previous skill version."
  recorded_root="$(jq -r '.repository_root' "$REGISTRY_PATH")"
  [[ "$recorded_root" == "$REPO_ROOT" ]] || die "$EXIT_REPOSITORY" "schema version 2 registry belongs to another repository root: $REGISTRY_PATH. Registry unchanged."
  worker_count="$(jq '.workers | length' "$REGISTRY_PATH")"
  [[ "$worker_count" -eq 0 ]] || die "$EXIT_SCHEMA" "schema version 2 registry contains $worker_count live worker(s): $REGISTRY_PATH. Retire them with the previous skill version before migration. Registry unchanged."
	ledger_count="$(jq '.identity_ledger | length' "$REGISTRY_PATH")"
	[[ "$ledger_count" -eq 0 ]] || die "$EXIT_SCHEMA" "schema version 2 registry contains $ledger_count historical worker row(s): $REGISTRY_PATH. Automatic migration requires proven emptiness; recover it with the previous skill version. Registry unchanged."
	[[ "$EXISTING_ONLY" -eq 0 ]] || die "$EXIT_SCHEMA" "schema-v2 migration is disabled for --existing-path recovery: $REGISTRY_PATH. Registry unchanged; run normal init only after recovery with the previous skill version."
	timestamp="$(now_utc)"
	if ! jq --arg identity "$REPO_IDENTITY" --arg checkout_identity "$REPO_CHECKOUT_PHYSICAL_ID" --arg timestamp "$timestamp" '.schema_version = 3 | .repository_identity = $identity | .repository_checkout_identity = $checkout_identity | .updated_at = $timestamp' "$REGISTRY_PATH" \
		| jq -e "$SCHEMA_FILTER" >/dev/null 2>&1; then
		die "$EXIT_SCHEMA" "schema version 2 registry cannot be safely migrated: $REGISTRY_PATH. Registry unchanged and checkout seal was not created."
	fi
	ensure_checkout_seal
	temp_path="$(mktemp "$REGISTRY_DIR/.registry-migration.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create schema migration file in $REGISTRY_DIR."
	if ! jq --arg identity "$REPO_IDENTITY" --arg checkout_identity "$REPO_CHECKOUT_IDENTITY" --arg timestamp "$timestamp" '.schema_version = 3 | .repository_identity = $identity | .repository_checkout_identity = $checkout_identity | .updated_at = $timestamp' "$REGISTRY_PATH" >"$temp_path"; then
		rm -f "$temp_path"; die "$EXIT_SCHEMA" "cannot prepare schema version 3 migration: $REGISTRY_PATH."
	fi
	jq -e "$SCHEMA_FILTER" "$temp_path" >/dev/null 2>&1 || { rm -f "$temp_path"; die "$EXIT_SCHEMA" "schema version 2 registry cannot be safely migrated after checkout seal creation: $REGISTRY_PATH. Registry unchanged."; }
	chmod 0600 "$temp_path" || die "$EXIT_FILESYSTEM" "cannot restrict schema migration file: $temp_path."
	mv "$temp_path" "$REGISTRY_PATH" || die "$EXIT_FILESYSTEM" "cannot publish schema version 3 migration: $REGISTRY_PATH."
}

add_checkout_seal_to_registry() {
	local temp_path=''
	local timestamp=''
	[[ -n "$REPO_CHECKOUT_IDENTITY" ]] || die "$EXIT_SCHEMA" 'cannot record an empty checkout identity seal.'
	timestamp="$(now_utc)"
	temp_path="$(mktemp "$REGISTRY_DIR/.registry-seal.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create checkout seal migration temporary file: $REGISTRY_DIR."
	if ! jq --arg checkout_identity "$REPO_CHECKOUT_IDENTITY" --arg timestamp "$timestamp" '.repository_checkout_identity = $checkout_identity | .updated_at = $timestamp' "$REGISTRY_PATH" >"$temp_path"; then
    rm -f "$temp_path"
    die "$EXIT_SCHEMA" "cannot prepare checkout seal migration: $REGISTRY_PATH."
  fi
  jq -e "$SCHEMA_FILTER" "$temp_path" >/dev/null 2>&1 || { rm -f "$temp_path"; die "$EXIT_SCHEMA" "checkout seal migration failed schema validation: $REGISTRY_PATH. Registry unchanged."; }
  chmod 0600 "$temp_path" || die "$EXIT_FILESYSTEM" "cannot restrict checkout seal migration file: $temp_path."
  mv "$temp_path" "$REGISTRY_PATH" || die "$EXIT_FILESYSTEM" "cannot publish checkout seal migration: $REGISTRY_PATH."
}

validate_drained_preseal_registry() {
  local recorded_root=''
  local recorded_identity=''
  local worker_count=''
  recorded_root="$(jq -r '.repository_root // empty' "$REGISTRY_PATH")"
  [[ "$recorded_root" == "$REPO_ROOT" ]] || die "$EXIT_REPOSITORY" "pre-seal schema-v3 registry has a different recorded repository root: $REGISTRY_PATH. Registry unchanged; recover with the previous skill version."
  [[ "$(jq -r '.repository_identity // empty' "$REGISTRY_PATH")" == "$REPO_IDENTITY" ]] || die "$EXIT_REPOSITORY" "pre-seal schema-v3 registry has a different repository identity: $REGISTRY_PATH. Registry unchanged; recover with the previous skill version."
  recorded_identity="$(jq -r '.repository_checkout_identity // empty' "$REGISTRY_PATH")"
  [[ "$recorded_identity" == "$REPO_CHECKOUT_PHYSICAL_ID" ]] || die "$EXIT_REPOSITORY" "pre-seal schema-v3 registry has a different physical checkout identity: $REGISTRY_PATH. Registry unchanged; recover with the previous skill version."
  worker_count="$(jq '.workers | length' "$REGISTRY_PATH")"
  [[ "$worker_count" == 0 ]] || die "$EXIT_SCHEMA" "pre-seal schema-v3 registry contains $worker_count live worker(s): $REGISTRY_PATH. Retire or recover every worker with the previous skill version, then rerun normal init. Registry unchanged."
  [[ "$EXISTING_ONLY" -eq 0 ]] || die "$EXIT_SCHEMA" "pre-seal schema-v3 migration is disabled for --existing-path recovery: $REGISTRY_PATH. Registry unchanged; run normal init only after recovery with the previous skill version."
}

validate_existing_registry() {
  local version temp_path recorded_identity=''
  [[ -e "$REGISTRY_PATH" || -L "$REGISTRY_PATH" ]] || return 1
  require_private_file "$REGISTRY_PATH" 'registry'
  version="$(jq -r '.schema_version // empty' "$REGISTRY_PATH" 2>/dev/null)" || die "$EXIT_SCHEMA" "registry is not valid JSON: $REGISTRY_PATH."
  case "$version" in
  1) migrate_v1_if_safe ;;
  2) migrate_v2_if_safe ;;
  3)
    jq -e "$SCHEMA_FILTER" "$REGISTRY_PATH" >/dev/null 2>&1 || die "$EXIT_SCHEMA" "registry fails pre-seal schema version 3 validation: $REGISTRY_PATH. Preserve it for recovery."
    [[ "$(jq -r '.repository_identity' "$REGISTRY_PATH")" == "$REPO_IDENTITY" ]] || die "$EXIT_REPOSITORY" "registry belongs to a different repository identity at $REPO_ROOT: $REGISTRY_PATH. Preserve copied or replacement state; do not attach it."
    recorded_identity="$(jq -r '.repository_checkout_identity' "$REGISTRY_PATH")"
    case "$recorded_identity" in
    "$REPO_CHECKOUT_PHYSICAL_ID")
      validate_drained_preseal_registry
      ensure_checkout_seal
      add_checkout_seal_to_registry
      ;;
    "$REPO_CHECKOUT_PHYSICAL_ID:seal:"*)
      ensure_checkout_seal
      [[ "$recorded_identity" == "$REPO_CHECKOUT_IDENTITY" || "$recorded_identity" == "$REPO_CHECKOUT_PHYSICAL_ID:seal:$REPO_CHECKOUT_SEAL" ]] || die "$EXIT_REPOSITORY" "registry checkout seal does not match this physical Git administration directory: $REGISTRY_PATH. Preserve state and recover it only with its original checkout."
      if [[ "$EXISTING_ONLY" -eq 0 && "$recorded_identity" != "$REPO_CHECKOUT_IDENTITY" ]]; then
        add_checkout_seal_to_registry
      fi
      ;;
    *) die "$EXIT_REPOSITORY" "registry belongs to a different physical Git checkout at $REPO_ROOT: $REGISTRY_PATH. Preserve state and recover it only with its original checkout." ;;
    esac
    ;;
  '') die "$EXIT_SCHEMA" "registry has no schema version: $REGISTRY_PATH. Preserve it for recovery." ;;
  *) die "$EXIT_SCHEMA" "unsupported registry schema version $version: $REGISTRY_PATH. Preserve it for recovery." ;;
  esac
  jq -e "$SCHEMA_FILTER" "$REGISTRY_PATH" >/dev/null 2>&1 || die "$EXIT_SCHEMA" "registry fails schema version 3 validation: $REGISTRY_PATH. Preserve it for recovery."
  [[ "$(jq -r '.repository_identity' "$REGISTRY_PATH")" == "$REPO_IDENTITY" ]] || die "$EXIT_REPOSITORY" "registry belongs to a different repository identity at $REPO_ROOT: $REGISTRY_PATH. Preserve copied or replacement state; do not attach it."
  [[ "$(jq -r '.repository_checkout_identity' "$REGISTRY_PATH")" == "$REPO_CHECKOUT_IDENTITY" ]] || die "$EXIT_REPOSITORY" "registry belongs to a different physical Git checkout at $REPO_ROOT: $REGISTRY_PATH. Preserve state and recover it only with its original checkout."
  if [[ "$(jq -r '.repository_root' "$REGISTRY_PATH")" != "$REPO_ROOT" ]]; then
    [[ "$EXISTING_ONLY" -eq 0 ]] || return 0
    temp_path="$(mktemp "$REGISTRY_DIR/.registry-move.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create moved-root registry temporary file: $REGISTRY_DIR."
    if ! jq --arg root "$REPO_ROOT" --arg timestamp "$(now_utc)" '.repository_root = $root | .updated_at = $timestamp' "$REGISTRY_PATH" >"$temp_path"; then
      rm -f "$temp_path"; die "$EXIT_FILESYSTEM" "cannot update moved repository root: $REGISTRY_PATH."
    fi
    jq -e "$SCHEMA_FILTER" "$temp_path" >/dev/null 2>&1 || { rm -f "$temp_path"; die "$EXIT_SCHEMA" 'moved repository root update failed schema validation.'; }
    chmod 0600 "$temp_path" || die "$EXIT_FILESYSTEM" "cannot restrict moved-root registry file: $temp_path."
    mv "$temp_path" "$REGISTRY_PATH" || die "$EXIT_FILESYSTEM" "cannot publish moved repository root: $REGISTRY_PATH."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo | -C) [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."; REPO_INPUT="$2"; shift 2 ;;
  --print-path) PRINT_PATH=1; shift ;;
  --existing-path) EXISTING_ONLY=1; PRINT_PATH=1; shift ;;
  --help | -h) usage "$EXIT_OK" ;;
  *) die "$EXIT_USAGE" "unknown argument: $1. Use --help for usage." ;;
  esac
done

require_commands
resolve_paths
require_owned_directory "$REPO_ROOT" 'repository root'
resolve_git_identity
[[ "$EXISTING_ONLY" -eq 1 ]] || require_project_skills
validate_gitignore_target
validate_present_registry_ignore_negations
ensure_boundary
if [[ "$EXISTING_ONLY" -eq 1 ]]; then
  [[ -e "$REGISTRY_DIR/.gitignore" || -L "$REGISTRY_DIR/.gitignore" ]] || die "$EXIT_FILESYSTEM" "registry-local .gitignore is missing: $REGISTRY_DIR/.gitignore. Existing-path recovery is validation-only."
  validate_private_gitignore_target
  validate_registry_ignore_rules
else
  ensure_gitignore
  ensure_private_gitignore
  validate_registry_ignore_rules
fi
acquire_lock
if ! validate_existing_registry; then
  [[ "$EXISTING_ONLY" -eq 0 ]] || die "$EXIT_FILESYSTEM" "registry does not exist: $REGISTRY_PATH. Run init before recovery lookup."
  [[ ! -e "$REGISTRY_PATH" && ! -L "$REGISTRY_PATH" ]] || die "$EXIT_FILESYSTEM" "registry appeared during initialization: $REGISTRY_PATH."
  write_new_registry
fi

if [[ "$PRINT_PATH" -eq 1 ]]; then
  printf '%s\n' "$REGISTRY_PATH"
else
  printf 'Initialized Luna worker registry in project: %s\n' "$REGISTRY_PATH"
fi
