#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs intentionally use single-quoted $variables.
set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_REPOSITORY=4
readonly EXIT_SCHEMA=5
readonly EXIT_LOCK=9
readonly EXIT_FILESYSTEM=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly PACKAGE_ROOT
DEFAULT_SKILLS_ROOT="$(cd "$PACKAGE_ROOT/.." && pwd -P)"
readonly DEFAULT_SKILLS_ROOT
readonly GITIGNORE_ENTRY='.agents/agent-registry/'
readonly CAVEMAN_SKILL_RELATIVE_PATH='.agents/skills/caveman/SKILL.md'

REPO_INPUT='.'
SKILLS_ROOT="$DEFAULT_SKILLS_ROOT"
REPO_ROOT=''
REGISTRY_DIR=''
REGISTRY_PATH=''
LOCK_DIR=''
CAVEMAN_SKILL_PATH=''
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
  init.sh [--repo PATH|-C PATH] [--skills-root PATH]

Initialize the current Git repository's persistent Luna worker registry.
The command is idempotent. If project-local Caveman skill is missing, init installs it from the repository root and may use the network.
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
  local required_commands=(bash git jq codex mktemp mkdir mv rm rmdir date kill ps sleep head awk cmp)

  for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing="${missing}${missing:+, }${command_name}"
    fi
  done

  if [[ -n "$missing" ]]; then
    die "$EXIT_PREREQUISITE" "missing runtime prerequisite(s): $missing. Check with 'command -v <name>'; install them through the repository/host-approved mechanism, then rerun init."
  fi

  if [[ "${BASH_VERSINFO[0]}" -lt 3 ]]; then
    die "$EXIT_PREREQUISITE" "Bash 3 or newer is required (detected ${BASH_VERSION}). Run this script with a supported Bash executable; init does not install one."
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
  CAVEMAN_SKILL_PATH="$REPO_ROOT/$CAVEMAN_SKILL_RELATIVE_PATH"
}

check_dependent_skills() {
  local reviewer_skill="$SKILLS_ROOT/code-reviewer/SKILL.md"
  if [[ ! -f "$reviewer_skill" ]]; then
    die "$EXIT_PREREQUISITE" "dependent skill missing: code-reviewer. Expected $reviewer_skill. Install or enable that skill through the approved local skill workflow, or rerun init with --skills-root PATH pointing at the active skills root. Code-reviewer is not auto-installed."
  fi
}

is_project_local_caveman_skill() {
  [[ -f "$CAVEMAN_SKILL_PATH" ]] || return 1
  [[ ! -L "$REPO_ROOT/.agents" ]] || return 1
  [[ ! -L "$REPO_ROOT/.agents/skills" ]] || return 1
  [[ ! -L "$REPO_ROOT/.agents/skills/caveman" ]] || return 1
  [[ ! -L "$CAVEMAN_SKILL_PATH" ]] || return 1
  return "$EXIT_OK"
}

ensure_caveman_skill() {
  if is_project_local_caveman_skill; then
    return "$EXIT_OK"
  fi

  if ! command -v npx >/dev/null 2>&1; then
    die "$EXIT_PREREQUISITE" "Caveman skill prerequisite/setup failed: npx is unavailable; expected project-local $CAVEMAN_SKILL_PATH. Required command: npx -y skills add https://github.com/juliusbrussee/caveman --skill caveman -y. Install or enable npx, then rerun init. A global Caveman copy does not satisfy project setup."
  fi

  if ! (cd "$REPO_ROOT" && npx -y skills add https://github.com/juliusbrussee/caveman --skill caveman -y); then
    die "$EXIT_PREREQUISITE" "Caveman skill prerequisite/setup failed: npx install command failed from repository root. Expected project-local $CAVEMAN_SKILL_PATH. Fix npx or network access, then rerun init. A global Caveman copy does not satisfy project setup."
  fi

  if ! is_project_local_caveman_skill; then
    die "$EXIT_PREREQUISITE" "Caveman skill prerequisite/setup failed: npx returned success, but expected project-local $CAVEMAN_SKILL_PATH is missing or not a regular project-local file. Inspect the install, then rerun init. A global Caveman copy does not satisfy project setup."
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

validate_registry_file() {
  local registry_file="$1"
  if [[ ! -s "$registry_file" ]] || ! jq -e "$SCHEMA_FILTER" "$registry_file" >/dev/null 2>&1; then
    die "$EXIT_SCHEMA" "registry is missing or fails schema version 1 validation: $registry_file. Preserve it for investigation, then repair it with a valid registry or restore the repository's known-good registry before retrying."
  fi
}

ensure_gitignore_entry() {
  local gitignore_path="$REPO_ROOT/.gitignore"
  local temp_path

  if [[ -e "$gitignore_path" && ! -f "$gitignore_path" ]]; then
    die "$EXIT_FILESYSTEM" "repository .gitignore is not a regular file: $gitignore_path. Resolve that path and rerun init."
  fi

  temp_path="$(mktemp "$REPO_ROOT/.gitignore.luna.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create an atomic .gitignore temporary file under $REPO_ROOT. Check repository permissions."
  if [[ -f "$gitignore_path" ]]; then
    if ! awk -v entry="$GITIGNORE_ENTRY" '
      $0 == entry {
        if (!seen) {
          print
          seen = 1
        }
        next
      }
      { print }
      END {
        if (!seen) print entry
      }
    ' "$gitignore_path" > "$temp_path"; then
      rm -f "$temp_path"
      die "$EXIT_FILESYSTEM" "cannot read repository .gitignore: $gitignore_path. Check permissions and rerun init."
    fi
  else
    printf '%s\n' "$GITIGNORE_ENTRY" > "$temp_path"
  fi

  if cmp -s "$temp_path" "$gitignore_path" 2>/dev/null; then
    rm -f "$temp_path"
  elif ! mv -f "$temp_path" "$gitignore_path"; then
    rm -f "$temp_path"
    die "$EXIT_FILESYSTEM" "cannot atomically update repository .gitignore: $gitignore_path. Check permissions and rerun init."
  fi
}

ensure_registry() {
  local temp_path
  local timestamp

  if [[ -e "$REGISTRY_PATH" ]]; then
    [[ -f "$REGISTRY_PATH" ]] || die "$EXIT_SCHEMA" "registry path is not a regular file: $REGISTRY_PATH. Preserve it and repair the path before retrying."
    validate_registry_file "$REGISTRY_PATH"
    if [[ "$(jq -r '.repository_root' "$REGISTRY_PATH")" != "$REPO_ROOT" ]]; then
      die "$EXIT_SCHEMA" "registry repository_root does not match the target Git root $REPO_ROOT: $REGISTRY_PATH. Do not reuse a registry from another repository; inspect or remove only the target repository's registry after preserving evidence."
    fi
    return "$EXIT_OK"
  fi

  timestamp="$(now_utc)"
  temp_path="$(mktemp "$REGISTRY_DIR/registry.json.tmp.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create an atomic registry temporary file under $REGISTRY_DIR. Check repository permissions."
  if ! jq -n \
    --arg repo_root "$REPO_ROOT" \
    --arg timestamp "$timestamp" \
    '{schema_version: 1, registry: "luna-local-review-loop", repository_root: $repo_root, created_at: $timestamp, updated_at: $timestamp, identity_ledger: [], workers: []}' \
    > "$temp_path"; then
    rm -f "$temp_path"
    die "$EXIT_FILESYSTEM" "jq could not create the initial registry JSON at $REGISTRY_PATH. Verify jq and filesystem permissions."
  fi
  validate_registry_file "$temp_path"
  if ! mv -f "$temp_path" "$REGISTRY_PATH"; then
    rm -f "$temp_path"
    die "$EXIT_FILESYSTEM" "cannot atomically install the registry at $REGISTRY_PATH. Check repository permissions and retry."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|-C)
      [[ $# -ge 2 ]] || usage "$EXIT_USAGE"
      REPO_INPUT="$2"
      shift 2
      ;;
    --skills-root)
      [[ $# -ge 2 ]] || usage "$EXIT_USAGE"
      SKILLS_ROOT="$2"
      shift 2
      ;;
    --help|-h)
      usage "$EXIT_OK"
      ;;
    *)
      die "$EXIT_USAGE" "unknown argument: $1. Use --help for usage."
      ;;
  esac
done

require_commands
[[ -d "$SKILLS_ROOT" ]] || die "$EXIT_PREREQUISITE" "skills root does not exist or is not a directory: $SKILLS_ROOT. Pass --skills-root PATH for the active skills directory."
SKILLS_ROOT="$(cd "$SKILLS_ROOT" 2>/dev/null && pwd -P)" || die "$EXIT_PREREQUISITE" "cannot access skills root: $SKILLS_ROOT. Check permissions and rerun init."
check_dependent_skills
resolve_repo_root
ensure_caveman_skill
mkdir -p "$REGISTRY_DIR" || die "$EXIT_FILESYSTEM" "cannot create registry directory: $REGISTRY_DIR. Check repository permissions."
acquire_lock
ensure_gitignore_entry
ensure_registry

printf 'Initialized Luna worker registry: %s\n' "$REGISTRY_PATH"
printf 'Schema: version 1; identity ledger is append-only and terminal entries are prunable.\n'
