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
CODEX_BIN="${CODEX_BIN:-codex}"
REPO_ROOT=''
REPO_IDENTITY=''
STATE_ROOT=''
REGISTRY_DIR=''
REGISTRY_PATH=''
LOCK_DIR=''
LEGACY_REGISTRY_PATH=''
LOCK_HELD=0
ALLOW_INSTANCE_MARKER_CREATE=0

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
      and (.repository_identity | nonempty_string)
      and (.created_at | nonempty_string)
      and (.updated_at | nonempty_string)
      and (.identity_ledger | type == "array")
      and (.workers | type == "array")
      and all($root.identity_ledger[];
        (.task_id | nonempty_string)
        and (.scope | nonempty_string)
        and (.sandbox == "read-only" or .sandbox == "workspace-write")
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
        and (.sandbox == "read-only" or .sandbox == "workspace-write")
        and (.retry_of | nullable_string)
        and (.session_id | nullable_string)
        and (valid_status(.status))
        and (.status != "retired")
        and (.created_at | nonempty_string)
        and (.updated_at | nonempty_string)
        and ((.bound_at == null) or (.bound_at | nonempty_string))
        and ((.activated_at == null) or (.activated_at | nonempty_string))
        and (.checkpoint_evidence | type == "string")
        and ((.invocation_pid == null and .invocation_token == null)
             or ((.invocation_pid | nonempty_string) and (.invocation_token | nonempty_string)))
        and ((.active_child_pgid == null)
             or ((.active_child_pgid | nonempty_string) and (.invocation_pid | nonempty_string) and (.invocation_token | nonempty_string)))
      )
      and (([$root.identity_ledger[].task_id] | length) == ([$root.identity_ledger[].task_id] | unique | length))
      and (([$root.identity_ledger[] | select(.session_id != null) | .session_id] | length) == ([$root.identity_ledger[] | select(.session_id != null) | .session_id] | unique | length))
      and (([$root.identity_ledger[] | select(.retry_of != null) | .retry_of] | length) == ([$root.identity_ledger[] | select(.retry_of != null) | .retry_of] | unique | length))
      and (([$root.workers[].task_id] | length) == ([$root.workers[].task_id] | unique | length))
      and (([$root.workers[].scope] | length) == ([$root.workers[].scope] | unique | length))
      and (([$root.workers[] | select(.session_id != null) | .session_id] | length) == ([$root.workers[] | select(.session_id != null) | .session_id] | unique | length))
      and all($root.identity_ledger[];
        . as $row
        | if .retry_of == null then true
          else any($root.identity_ledger[]; .task_id == $row.retry_of and .scope == $row.scope and .sandbox == $row.sandbox)
          end
      )
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
  init.sh [--repo PATH|-C PATH] [--state-root PATH] [--print-path]
  init.sh --existing-path [--repo PATH|-C PATH] [--state-root PATH]

Validate project prerequisites and initialize a non-project worker registry.
--existing-path validates and prints an already initialized registry without
requiring launch-only tools or project skills. Init never changes repository files.
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
	local required_commands=(bash git jq mkdir rm rmdir mv ln kill ps sleep awk shasum stat cat)
	if [[ "$EXISTING_ONLY" -eq 0 ]]; then
		required_commands+=(mktemp date chmod od tr)
	fi

	for command_name in "${required_commands[@]}"; do
		if ! command -v "$command_name" >/dev/null 2>&1; then
			missing="${missing}${missing:+, }${command_name}"
		fi
	done

	[[ -z "$missing" ]] || die "$EXIT_PREREQUISITE" "missing runtime prerequisite(s): $missing. Install them through the approved host mechanism, then retry."
	if [[ "$EXISTING_ONLY" -eq 0 ]] && ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
		die "$EXIT_PREREQUISITE" "Codex CLI not found: $CODEX_BIN. Normal initialization validates launch prerequisites; use --existing-path only for recovery of an already initialized external registry."
	fi
	[[ "${BASH_VERSINFO[0]}" -ge 3 ]] || die "$EXIT_PREREQUISITE" "Bash 3 or newer is required (detected ${BASH_VERSION})."
}

resolve_paths() {
	local candidate
	local repo_fingerprint
	local registry_candidate
	local state_candidate

	[[ -d "$REPO_INPUT" ]] || die "$EXIT_REPOSITORY" "repository path does not exist or is not a directory: $REPO_INPUT."
	candidate="$(cd -P "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot access repository path: $REPO_INPUT."
	REPO_ROOT="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)" || die "$EXIT_REPOSITORY" "path is not inside a Git repository: $candidate."
	REPO_ROOT="$(cd -P "$REPO_ROOT" 2>/dev/null && pwd -P)" || die "$EXIT_REPOSITORY" "cannot resolve repository root: $candidate."
	LEGACY_REGISTRY_PATH="$REPO_ROOT/.agents/agent-registry/registry.json"
	state_candidate="$(canonical_path_without_creation "$STATE_ROOT_INPUT")" || die "$EXIT_FILESYSTEM" "cannot resolve state root candidate: $STATE_ROOT_INPUT."
	case "$state_candidate/" in
	"$REPO_ROOT/"*) die "$EXIT_FILESYSTEM" "state root must be outside the repository: $state_candidate." ;;
	esac
	repo_fingerprint="$(printf '%s' "$REPO_ROOT" | shasum -a 256 | awk '{print $1}')"
	[[ -n "$repo_fingerprint" ]] || die "$EXIT_FILESYSTEM" 'could not derive repository state key.'
	registry_candidate="$state_candidate/$repo_fingerprint/registry.json"
	if [[ "$EXISTING_ONLY" -eq 0 && ! -e "$registry_candidate" ]]; then
		refuse_live_legacy_registry
		ALLOW_INSTANCE_MARKER_CREATE=1
	fi
	if [[ "$EXISTING_ONLY" -eq 1 ]]; then
		[[ -d "$STATE_ROOT_INPUT" ]] || die "$EXIT_FILESYSTEM" "state root does not exist: $STATE_ROOT_INPUT."
	else
		mkdir -p "$STATE_ROOT_INPUT" || die "$EXIT_FILESYSTEM" "cannot create state root: $STATE_ROOT_INPUT."
	fi
	STATE_ROOT="$(cd -P "$STATE_ROOT_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_FILESYSTEM" "cannot access state root: $STATE_ROOT_INPUT."
	case "$STATE_ROOT/" in
	"$REPO_ROOT/"*) die "$EXIT_FILESYSTEM" "state root must be outside the repository: $STATE_ROOT." ;;
	esac
	REGISTRY_DIR="$STATE_ROOT/$repo_fingerprint"
	REGISTRY_PATH="$REGISTRY_DIR/registry.json"
	LOCK_DIR="$REGISTRY_DIR/.lock"
	validate_registry_dir
}

repository_instance_identity() {
	local allow_create="$1"
	local git_dir
	local git_dir_real
	local marker_path
	local nonce=''
	git_dir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
	git_dir_real="$(cd -P "$git_dir" 2>/dev/null && pwd -P)" || return 1
	marker_path="$git_dir_real/luna-local-review-loop.instance"
	[[ ! -L "$marker_path" ]] || return 1
	if [[ ! -e "$marker_path" ]]; then
		[[ "$allow_create" -eq 1 ]] || return 1
		nonce="$(od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
		[[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
		if ! (set -o noclobber; printf '%s\n' "$nonce" >"$marker_path") 2>/dev/null; then
			[[ -f "$marker_path" && ! -L "$marker_path" ]] || return 1
		fi
	fi
	[[ -f "$marker_path" && ! -L "$marker_path" ]] || return 1
	IFS= read -r nonce <"$marker_path" || return 1
	[[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s' "$git_dir_real:$nonce" | shasum -a 256 | awk '{print $1}'
}

refuse_live_legacy_registry() {
	local live_count
	[[ -e "$LEGACY_REGISTRY_PATH" ]] || return "$EXIT_OK"
	[[ -f "$LEGACY_REGISTRY_PATH" && ! -L "$LEGACY_REGISTRY_PATH" ]] || die "$EXIT_SCHEMA" "legacy project registry is not a regular file: $LEGACY_REGISTRY_PATH. Preserve it for recovery before initializing external state."
	jq -e '
    (.schema_version == 1)
    and (.registry == "luna-local-review-loop")
    and (.workers | type == "array")
    and all(.workers[]; .status as $status | (["reserved", "bound", "active", "stopping", "completed", "failed", "blocked", "interrupted", "retired"] | index($status) != null))
  ' "$LEGACY_REGISTRY_PATH" >/dev/null 2>&1 || die "$EXIT_SCHEMA" "legacy project registry cannot be validated safely: $LEGACY_REGISTRY_PATH. Preserve it and recover with the previous skill version before initializing external state."
	live_count="$(jq '[.workers[] | select(.status == "reserved" or .status == "bound" or .status == "active" or .status == "stopping")] | length' "$LEGACY_REGISTRY_PATH")"
	[[ "$live_count" -eq 0 ]] || die "$EXIT_SCHEMA" "legacy project registry contains $live_count live worker(s): $LEGACY_REGISTRY_PATH. Reinstall the previous skill version, retire or recover every live worker, verify its registry is empty, then rerun this version. The legacy registry was not changed."
}

canonical_path_without_creation() {
	local path="$1"
	local suffix=''
	local base
	local parent
	local resolved

	[[ -n "$path" ]] || return 1
	case "$path" in
	/*) ;;
	*) path="$PWD/$path" ;;
	esac
	while [[ ! -e "$path" ]]; do
		base="${path##*/}"
		parent="${path%/*}"
		[[ -n "$base" && -n "$parent" && "$parent" != "$path" ]] || return 1
		suffix="/$base$suffix"
		path="$parent"
	done
	[[ -d "$path" ]] || return 1
	resolved="$(cd -P "$path" 2>/dev/null && pwd -P)" || return 1
	normalize_absolute_path "$resolved$suffix"
}

validate_registry_dir() {
	local resolved
	[[ ! -e "$REGISTRY_DIR" && ! -L "$REGISTRY_DIR" ]] && return "$EXIT_OK"
	[[ -d "$REGISTRY_DIR" && ! -L "$REGISTRY_DIR" ]] || die "$EXIT_FILESYSTEM" "repository fingerprint state path must be a real directory, not a symlink: $REGISTRY_DIR."
	resolved="$(cd -P "$REGISTRY_DIR" 2>/dev/null && pwd -P)" || die "$EXIT_FILESYSTEM" "cannot resolve repository fingerprint state path: $REGISTRY_DIR."
	[[ "$resolved" == "$REGISTRY_DIR" ]] || die "$EXIT_FILESYSTEM" "repository fingerprint state path resolved unexpectedly: $REGISTRY_DIR -> $resolved."
	case "$resolved/" in
	"$REPO_ROOT/"*) die "$EXIT_FILESYSTEM" "repository fingerprint state path must be outside the repository: $resolved." ;;
	esac
}

normalize_absolute_path() {
	local path="$1"
	local component
	local output=''
	local old_ifs="$IFS"
	local components=()
	local stack=()

	[[ "$path" == /* ]] || return 1
	IFS='/' read -r -a components <<<"$path"
	IFS="$old_ifs"
	for component in "${components[@]}"; do
		case "$component" in
		'' | .) ;;
		..)
			if [[ "${#stack[@]}" -gt 0 ]]; then
				unset "stack[$((${#stack[@]} - 1))]"
			fi
			;;
		*) stack+=("$component") ;;
		esac
	done
	for component in "${stack[@]}"; do
		output="$output/$component"
	done
	printf '%s\n' "${output:-/}"
}

require_project_skills() {
	local code_reviewer="$REPO_ROOT/.agents/skills/code-reviewer/SKILL.md"
	local caveman="$REPO_ROOT/.agents/skills/caveman/SKILL.md"
	local missing=''
	local path

	for path in \
		"$REPO_ROOT/.agents" \
		"$REPO_ROOT/.agents/skills" \
		"$REPO_ROOT/.agents/skills/code-reviewer" \
		"$REPO_ROOT/.agents/skills/caveman"; do
		[[ ! -L "$path" ]] || die "$EXIT_PREREQUISITE" "project skill path must be a real directory, not a symlink: $path."
	done
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
	local process_state=''

	if process_state="$(ps -p "$owner_pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"; then
		case "$process_state" in
		Z*) return 0 ;;
		?*) return 1 ;;
		esac
	fi
	if kill_error="$(LC_ALL=C kill -0 "$owner_pid" 2>&1)"; then
		if process_state="$(ps -p "$owner_pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"; then
			case "$process_state" in
			Z*) return 0 ;;
			?*) return 1 ;;
			esac
		fi
		return 1
	fi
	case "$kill_error" in
	*[Nn]o\ such\ process* | *[Nn]o\ such\ file* | *[Nn]o\ process*) return 0 ;;
	*) return 1 ;;
	esac
}

remove_stale_reclaim_marker() {
	local marker="$1"
	local attempt="$2"
	local marker_pid=''
	local witness="$REGISTRY_DIR/.reclaim-observed.$$.$attempt"

	[[ -e "$marker" ]] || return 0
	[[ -f "$marker" && ! -L "$marker" ]] || return 1
	IFS= read -r marker_pid <"$marker" || marker_pid=''
	case "$marker_pid" in '' | 0 | *[!0-9]*) return 1 ;; esac
	pid_is_confirmed_nonexistent "$marker_pid" || return 1
	rm -f "$witness"
	if ln "$marker" "$witness" 2>/dev/null; then
		if [[ "$marker" -ef "$witness" ]]; then
			rm -f "$marker" 2>/dev/null || true
		fi
		rm -f "$witness" 2>/dev/null || true
	fi
}

acquire_lock() {
	local attempt=0
	local owner_pid=''
	local current_pid=''
	local reclaim_candidate=''
	local reclaim_marker=''
	local quarantine=''

	if ! mkdir "$REGISTRY_DIR" 2>/dev/null; then
		validate_registry_dir
	fi
	validate_registry_dir
	chmod 0700 "$REGISTRY_DIR" 2>/dev/null || die "$EXIT_FILESYSTEM" "cannot restrict registry directory permissions: $REGISTRY_DIR."
	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		owner_pid=''
		[[ ! -f "$LOCK_DIR/pid" ]] || IFS= read -r owner_pid <"$LOCK_DIR/pid" || owner_pid=''
		case "$owner_pid" in
		'' | 0 | *[!0-9]*) ;;
		*)
			if pid_is_confirmed_nonexistent "$owner_pid"; then
				reclaim_marker="$LOCK_DIR/.reclaim"
				reclaim_candidate="$REGISTRY_DIR/.reclaim-candidate.$$.$attempt"
				printf '%s\n' "$$" >"$reclaim_candidate" || die "$EXIT_FILESYSTEM" "cannot create registry-lock reclaim candidate: $reclaim_candidate."
				if ln "$reclaim_candidate" "$reclaim_marker" 2>/dev/null; then
					rm -f "$reclaim_candidate" 2>/dev/null || true
					current_pid=''
					[[ ! -f "$LOCK_DIR/pid" ]] || IFS= read -r current_pid <"$LOCK_DIR/pid" || current_pid=''
					if [[ "$current_pid" == "$owner_pid" ]] && pid_is_confirmed_nonexistent "$current_pid"; then
						quarantine="$REGISTRY_DIR/.lock.reclaimed.$$.$attempt"
						if mv "$LOCK_DIR" "$quarantine" 2>/dev/null; then
							rm -f "$quarantine/pid" 2>/dev/null || true
							rm -f "$quarantine/.reclaim" 2>/dev/null || true
							rmdir "$quarantine" 2>/dev/null || true
							continue
						fi
					fi
					rm -f "$reclaim_marker" 2>/dev/null || true
				else
					rm -f "$reclaim_candidate" 2>/dev/null || true
					remove_stale_reclaim_marker "$reclaim_marker" "$attempt" || true
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
		--arg identity "$REPO_IDENTITY" \
		--arg timestamp "$timestamp" \
		'{schema_version: 2, registry: "luna-local-review-loop", repository_root: $root, repository_identity: $identity, created_at: $timestamp, updated_at: $timestamp, identity_ledger: [], workers: []}' >"$temp_path"
	jq -e "$SCHEMA_FILTER" "$temp_path" >/dev/null 2>&1 || die "$EXIT_SCHEMA" 'new registry failed schema validation.'
	chmod 0600 "$temp_path" || die "$EXIT_FILESYSTEM" "cannot restrict registry permissions: $temp_path."
	mv "$temp_path" "$REGISTRY_PATH" || die "$EXIT_FILESYSTEM" "cannot publish registry: $REGISTRY_PATH."
}

PRINT_PATH=0
EXISTING_ONLY=0
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
	--existing-path)
		EXISTING_ONLY=1
		PRINT_PATH=1
		shift
		;;
	--help | -h) usage "$EXIT_OK" ;;
	*) die "$EXIT_USAGE" "unknown argument: $1. Use --help for usage." ;;
	esac
done

require_commands
resolve_paths
if [[ "$EXISTING_ONLY" -eq 0 ]]; then
	require_project_skills
fi
REPO_IDENTITY="$(repository_instance_identity "$ALLOW_INSTANCE_MARKER_CREATE")" || die "$EXIT_REPOSITORY" "cannot read or safely create the Git-directory instance marker for $REPO_ROOT. This may be a different Git repository instance at the same path; preserve external state and inspect the repository before retrying."
acquire_lock
if [[ -e "$REGISTRY_PATH" ]]; then
	[[ -f "$REGISTRY_PATH" && ! -L "$REGISTRY_PATH" ]] || die "$EXIT_SCHEMA" "registry is not a regular file: $REGISTRY_PATH."
	jq -e "$SCHEMA_FILTER" "$REGISTRY_PATH" >/dev/null 2>&1 || die "$EXIT_SCHEMA" "registry fails schema version 2 validation: $REGISTRY_PATH. Preserve it for investigation."
	[[ "$(jq -r '.repository_root' "$REGISTRY_PATH")" == "$REPO_ROOT" ]] || die "$EXIT_SCHEMA" "registry repository root does not match $REPO_ROOT: $REGISTRY_PATH."
	[[ "$(jq -r '.repository_identity' "$REGISTRY_PATH")" == "$REPO_IDENTITY" ]] || die "$EXIT_SCHEMA" "registry belongs to a different Git repository instance at $REPO_ROOT: $REGISTRY_PATH. Preserve live state and recover it only with the original checkout; after proving no live workers remain, remove or archive this external registry before initializing the replacement checkout."
else
	[[ "$EXISTING_ONLY" -eq 0 ]] || die "$EXIT_FILESYSTEM" "registry does not exist: $REGISTRY_PATH. Run init before launch."
	write_new_registry
fi

if [[ "$PRINT_PATH" -eq 1 ]]; then
	printf '%s\n' "$REGISTRY_PATH"
else
	printf 'Initialized Luna worker registry outside project: %s\n' "$REGISTRY_PATH"
fi
