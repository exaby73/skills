#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs intentionally use single-quoted $variables.
set -euo pipefail
umask 077

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_REPOSITORY=4
readonly EXIT_SCHEMA=5
readonly EXIT_LOCK=9
readonly EXIT_FILESYSTEM=10

REPO_INPUT='.'
STATE_ROOT_INPUT="${LUNA_REGISTRY_ROOT:-${TMPDIR:-/tmp}/luna-local-review-loop}"
REPO_ROOT=''
STATE_ROOT=''
REGISTRY_DIR=''
REGISTRY_PATH=''
LOCK_DIR=''
LOCK_HELD=0

readonly SCHEMA_FILTER='
  def nonempty_string: type == "string" and length > 0;
  def nullable_string: . == null or (. | nonempty_string);
  def valid_status($status): ["reserved", "bound", "active", "retired"] | index($status) != null;
  def valid_terminal($status): ["completed", "failed", "blocked", "interrupted"] | index($status) != null;
  . as $root
  | try (
      (.schema_version == 2)
      and (.registry == "luna-local-review-loop")
      and (.repository_root | nonempty_string)
      and (.created_at | nonempty_string)
      and (.updated_at | nonempty_string)
      and (.identity_ledger | type == "array")
      and (.workers | type == "array")
      and all($root.identity_ledger[];
        (.task_id | nonempty_string)
        and (.scope | nonempty_string)
        and (.retry_of | nullable_string)
        and (.session_id | nullable_string)
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
        (.task_id | nonempty_string)
        and (.scope | nonempty_string)
        and (.retry_of | nullable_string)
        and (.session_id | nullable_string)
        and (valid_status(.status))
        and (.status != "retired")
        and (.created_at | nonempty_string)
        and (.updated_at | nonempty_string)
        and ((.bound_at == null) or (.bound_at | nonempty_string))
        and ((.activated_at == null) or (.activated_at | nonempty_string))
        and (.checkpoint_evidence | type == "string")
      )
      and (([$root.identity_ledger[].task_id] | length) == ([$root.identity_ledger[].task_id] | unique | length))
      and (([$root.identity_ledger[] | select(.session_id != null) | .session_id] | length) == ([$root.identity_ledger[] | select(.session_id != null) | .session_id] | unique | length))
      and (([$root.workers[].task_id] | length) == ([$root.workers[].task_id] | unique | length))
      and (([$root.workers[] | select(.session_id != null) | .session_id] | length) == ([$root.workers[] | select(.session_id != null) | .session_id] | unique | length))
      and all($root.identity_ledger[];
        . as $row
        | if .retry_of == null then true
          else any($root.identity_ledger[]; .task_id == $row.retry_of and .scope == $row.scope)
          end
      )
      and all($root.workers[];
        . as $worker
        | any($root.identity_ledger[];
          .task_id == $worker.task_id
          and .scope == $worker.scope
          and .retry_of == $worker.retry_of
          and .session_id == $worker.session_id
          and .status == $worker.status
          and .bound_at == $worker.bound_at
          and .activated_at == $worker.activated_at
        )
      )
    ) catch false
  | .
'

usage() {
	local exit_code="${1:-0}"
	cat <<'EOF'
Usage:
  init.sh [--repo PATH|-C PATH] [--state-root PATH] [--print-path]

Validate project prerequisites and initialize a non-project worker registry.
Init never installs skills and never changes repository files.
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

require_commands() {
	local missing=''
	local command_name
	local required_commands=(bash git jq codex mktemp mkdir mv rm rmdir date kill ps sleep awk chmod shasum dirname find wc tr head cat)

	for command_name in "${required_commands[@]}"; do
		if ! command -v "$command_name" >/dev/null 2>&1; then
			missing="${missing}${missing:+, }${command_name}"
		fi
	done

	[[ -z "$missing" ]] || die "$EXIT_PREREQUISITE" "missing runtime prerequisite(s): $missing. Install them through the approved host mechanism, then retry."
	[[ "${BASH_VERSINFO[0]}" -ge 3 ]] || die "$EXIT_PREREQUISITE" "Bash 3 or newer is required (detected ${BASH_VERSION})."
}

resolve_paths() {
	local candidate
	local repo_fingerprint

	[[ -d "$REPO_INPUT" ]] || die "$EXIT_REPOSITORY" "repository path does not exist or is not a directory: $REPO_INPUT."
	candidate="$(cd "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot access repository path: $REPO_INPUT."
	REPO_ROOT="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)" || die "$EXIT_REPOSITORY" "path is not inside a Git repository: $candidate."
	REPO_ROOT="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot resolve repository root: $candidate."
	mkdir -p "$STATE_ROOT_INPUT" || die "$EXIT_FILESYSTEM" "cannot create state root: $STATE_ROOT_INPUT."
	STATE_ROOT="$(cd "$STATE_ROOT_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_FILESYSTEM" "cannot access state root: $STATE_ROOT_INPUT."
	repo_fingerprint="$(printf '%s' "$REPO_ROOT" | shasum -a 256 | awk '{print $1}')"
	[[ -n "$repo_fingerprint" ]] || die "$EXIT_FILESYSTEM" 'could not derive repository state key.'
	REGISTRY_DIR="$STATE_ROOT/$repo_fingerprint"
	REGISTRY_PATH="$REGISTRY_DIR/registry.json"
	LOCK_DIR="$REGISTRY_DIR/.lock"
}

require_project_skills() {
	local code_reviewer="$REPO_ROOT/.agents/skills/code-reviewer/SKILL.md"
	local caveman="$REPO_ROOT/.agents/skills/caveman/SKILL.md"
	local missing=''

	[[ -f "$code_reviewer" && ! -L "$code_reviewer" ]] || missing="${missing}${missing:+, }code-reviewer"
	[[ -f "$caveman" && ! -L "$caveman" ]] || missing="${missing}${missing:+, }caveman"
	[[ -z "$missing" ]] || die "$EXIT_PREREQUISITE" "missing project-local skill(s): $missing. Init is non-mutating. Install explicitly with '-a universal', review Skills CLI changes, then retry. code-reviewer: npx -y skills add https://github.com/google-gemini/gemini-cli --skill code-reviewer -a universal -y ; caveman: npx -y skills add https://github.com/juliusbrussee/caveman --skill caveman -a universal -y"
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

	mkdir -p "$REGISTRY_DIR" || die "$EXIT_FILESYSTEM" "cannot create registry directory: $REGISTRY_DIR."
	chmod 0700 "$REGISTRY_DIR" 2>/dev/null || die "$EXIT_FILESYSTEM" "cannot restrict registry directory permissions: $REGISTRY_DIR."
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

write_new_registry() {
	local timestamp
	local temp_path
	timestamp="$(now_utc)"
	temp_path="$(mktemp "$REGISTRY_DIR/.registry.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create temporary registry in $REGISTRY_DIR."
	jq -n \
		--arg root "$REPO_ROOT" \
		--arg timestamp "$timestamp" \
		'{schema_version: 2, registry: "luna-local-review-loop", repository_root: $root, created_at: $timestamp, updated_at: $timestamp, identity_ledger: [], workers: []}' >"$temp_path"
	jq -e "$SCHEMA_FILTER" "$temp_path" >/dev/null 2>&1 || die "$EXIT_SCHEMA" 'new registry failed schema validation.'
	chmod 0600 "$temp_path" || die "$EXIT_FILESYSTEM" "cannot restrict registry permissions: $temp_path."
	mv "$temp_path" "$REGISTRY_PATH" || die "$EXIT_FILESYSTEM" "cannot publish registry: $REGISTRY_PATH."
}

PRINT_PATH=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo | -C)
		[[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."
		REPO_INPUT="$2"
		shift 2
		;;
	--state-root)
		[[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing value for --state-root.'
		STATE_ROOT_INPUT="$2"
		shift 2
		;;
	--print-path)
		PRINT_PATH=1
		shift
		;;
	--help | -h) usage "$EXIT_OK" ;;
	*) die "$EXIT_USAGE" "unknown argument: $1. Use --help for usage." ;;
	esac
done

require_commands
resolve_paths
require_project_skills
acquire_lock
if [[ -e "$REGISTRY_PATH" ]]; then
	[[ -f "$REGISTRY_PATH" && ! -L "$REGISTRY_PATH" ]] || die "$EXIT_SCHEMA" "registry is not a regular file: $REGISTRY_PATH."
	jq -e "$SCHEMA_FILTER" "$REGISTRY_PATH" >/dev/null 2>&1 || die "$EXIT_SCHEMA" "registry fails schema version 2 validation: $REGISTRY_PATH. Preserve it for investigation."
	[[ "$(jq -r '.repository_root' "$REGISTRY_PATH")" == "$REPO_ROOT" ]] || die "$EXIT_SCHEMA" "registry repository root does not match $REPO_ROOT: $REGISTRY_PATH."
else
	write_new_registry
fi

if [[ "$PRINT_PATH" -eq 1 ]]; then
	printf '%s\n' "$REGISTRY_PATH"
else
	printf 'Initialized Luna worker registry outside project: %s\n' "$REGISTRY_PATH"
fi
