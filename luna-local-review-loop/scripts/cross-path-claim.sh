#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFLICT=6
readonly EXIT_FILESYSTEM=10
readonly EXIT_RUNTIME_STATE=11

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR='.'
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd -P)"
readonly SCRIPT_DIR

REPO_INPUT='.'
SCOPE=''
TOKEN=''
REENTER=0
REENTER_OR_ACQUIRE=0
FALLBACK_PREFLIGHT=0
CLAIM_ROOT=''
CLAIM_PATH=''
CLAIM_KEY=''
CLAIM_LOCK_PATH=''
CLAIM_LOCK_HELD=0
REGISTRY_PREFLIGHT_PID=''
REGISTRY_PREFLIGHT_INSTANCE=''
REGISTRY_PREFLIGHT_READY_PATH=''
REGISTRY_PREFLIGHT_RELEASE_PATH=''
REGISTRY_PREFLIGHT_ERROR_PATH=''
REGISTRY_PREFLIGHT_LOG_PATH=''
REGISTRY_PREFLIGHT_RELEASE_TOKEN=''
CHECKOUT_PHYSICAL_IDENTITY=''
CHECKOUT_IDENTITY=''
SHA256_COMMAND=''

usage() {
	local exit_code="${1:-0}"
	cat <<'EOF'
Usage:
  cross-path-claim.sh acquire --repo PATH --scope TEXT --token TOKEN
  cross-path-claim.sh acquire --reenter --repo PATH --scope TEXT --token TOKEN
  cross-path-claim.sh acquire --reenter-or-acquire --repo PATH --scope TEXT --token TOKEN
  cross-path-claim.sh acquire --fallback-preflight --repo PATH --scope TEXT --token TOKEN
  cross-path-claim.sh release --repo PATH --scope TEXT --token TOKEN

The claim is shared by native startup and the CLI fallback reservation. It is
keyed by physical checkout identity plus immutable scope and is separate from
the project-local fallback registry. Native initial acquisition is exclusive;
continuation must explicitly use --reenter with the stable owner token. The
fallback launcher uses --reenter-or-acquire with its stable task token so a
parent-held same-owner claim is explicitly re-entered, while a missing claim
is acquired atomically. Existing claims still require exact owner/token
matches, including legacy fallback continuation after its active registry row
has been validated. Acquire and release serialize through a short-lived
private lock. Fallback preflight runs under that lock before checkout-seal
creation and claim publication.
EOF
	exit "$exit_code"
}

die() {
	local exit_code="$1"
	shift
	printf 'luna-local-review-loop: ERROR [%s] %s\n' "$exit_code" "$*" >&2
	exit "$exit_code"
}

validate_scope() {
	[[ -n "$SCOPE" ]] || die "$EXIT_USAGE" 'scope must not be empty.'
	case "$SCOPE" in
	*$'\n'* | *$'\r'*) die "$EXIT_USAGE" 'scope must be one line.' ;;
	esac
}

validate_token() {
	[[ -n "$TOKEN" ]] || die "$EXIT_USAGE" 'token must not be empty.'
	case "$TOKEN" in
	*[!A-Za-z0-9._:/-]*) die "$EXIT_USAGE" 'token contains unsupported characters.' ;;
	esac
}

file_identity() {
	local path="$1"
	local identity=''
	if identity="$(LC_ALL=C stat -c '%d:%i' "$path" 2>/dev/null)"; then
		:
	elif identity="$(LC_ALL=C stat -f '%d:%i' "$path" 2>/dev/null)"; then
		:
	else
		return 1
	fi
	[[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
	printf '%s\n' "$identity"
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

path_owner_mode() {
	local path="$1"
	local metadata=''
	if metadata="$(LC_ALL=C stat -c '%u %a' "$path" 2>/dev/null)" && [[ "$metadata" =~ ^[0-9]+[[:space:]][0-7]+$ ]]; then
		printf '%s\n' "$metadata"
		return 0
	fi
	if metadata="$(LC_ALL=C stat -f '%u %Lp' "$path" 2>/dev/null)" && [[ "$metadata" =~ ^[0-9]+[[:space:]][0-7]+$ ]]; then
		printf '%s\n' "$metadata"
		return 0
	fi
	return 1
}

require_owned_directory() {
	local path="$1"
	local label="$2"
	local metadata=''
	local owner=''
	local mode=''
	[[ -d "$path" && ! -L "$path" ]] || die "$EXIT_FILESYSTEM" "$label must be a real directory: $path."
	metadata="$(path_owner_mode "$path")" || die "$EXIT_FILESYSTEM" "cannot inspect $label ownership and permissions: $path."
	read -r owner mode <<<"$metadata"
	[[ "$owner" == "$UID" ]] || die "$EXIT_FILESYSTEM" "$label must be owned by UID $UID: $path is owned by UID $owner."
	(( (8#$mode & 022) == 0 )) || die "$EXIT_FILESYSTEM" "$label must not be group- or world-writable: $path has mode $mode."
}

regular_file_link_count() {
	local path="$1"
	local count=''
	if count="$(LC_ALL=C stat -c '%h' "$path" 2>/dev/null)"; then
		:
	elif count="$(LC_ALL=C stat -f '%l' "$path" 2>/dev/null)"; then
		:
	else
		return 1
	fi
	[[ "$count" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s\n' "$count"
}

require_private_file() {
	local path="$1"
	local label="$2"
	local metadata=''
	local owner=''
	local mode=''
	[[ -f "$path" && ! -L "$path" ]] || die "$EXIT_FILESYSTEM" "$label must be a real regular file: $path."
	[[ "$(regular_file_link_count "$path")" == 1 ]] || die "$EXIT_FILESYSTEM" "$label must have exactly one hard link: $path."
	metadata="$(path_owner_mode "$path")" || die "$EXIT_FILESYSTEM" "cannot inspect $label ownership and permissions: $path."
	read -r owner mode <<<"$metadata"
	[[ "$owner" == "$UID" ]] || die "$EXIT_FILESYSTEM" "$label must be owned by UID $UID: $path is owned by UID $owner."
	[[ "$mode" == 600 ]] || die "$EXIT_FILESYSTEM" "$label must have mode 0600: $path has mode $mode."
}

private_file_is_valid() {
	local path="$1"
	local metadata=''
	local owner=''
	local mode=''
	local link_count=''
	[[ -f "$path" && ! -L "$path" ]] || return 1
	link_count="$(regular_file_link_count "$path")" || return 1
	[[ "$link_count" == 1 ]] || return 1
	metadata="$(path_owner_mode "$path")" || return 1
	read -r owner mode <<<"$metadata"
	[[ "$owner" == "$UID" && "$mode" == 600 ]]
}

select_sha256_command() {
	[[ -n "$SHA256_COMMAND" ]] && return 0
	if command -v shasum >/dev/null 2>&1; then
		SHA256_COMMAND='shasum'
	elif command -v sha256sum >/dev/null 2>&1; then
		SHA256_COMMAND='sha256sum'
	else
		return 1
	fi
}

sha256_digest() {
	local digest=''
	select_sha256_command || return 1
	case "$SHA256_COMMAND" in
	shasum) digest="$(LC_ALL=C shasum -a 256 "$@" 2>/dev/null | LC_ALL=C awk '{print tolower($1); exit}')" || return 1 ;;
	sha256sum) digest="$(LC_ALL=C sha256sum "$@" 2>/dev/null | LC_ALL=C awk '{print tolower($1); exit}')" || return 1 ;;
	*) return 1 ;;
	esac
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$digest"
}

owner_metadata_shape_is_valid() {
	local path="$1"
	awk -F= '
		BEGIN { valid = 1 }
		NR == 1 { valid = valid && NF == 2 && $1 == "version" && $2 == "1"; next }
		NR == 2 { valid = valid && NF == 2 && $1 == "identity" && $2 != ""; next }
		NR == 3 { valid = valid && NF == 2 && $1 == "scope" && $2 != ""; next }
		NR == 4 { valid = valid && NF == 2 && $1 == "token" && $2 != ""; next }
		NR == 5 { valid = valid && NF == 2 && $1 == "pid" && $2 ~ /^[0-9]+$/; next }
		{ valid = 0 }
		END {
			if (NR != 5) valid = 0
			exit(valid ? 0 : 1)
		}
	' "$path" >/dev/null 2>&1
}

resolve_git_path() {
	local path="$1"
	local parent=''
	local name=''
	case "$path" in
	/*) ;;
	*) path="$REPO_ROOT/$path" ;;
	esac
	parent="${path%/*}"
	name="${path##*/}"
	[[ -n "$parent" && -n "$name" ]] || return 1
	parent="$(cd -P "$parent" 2>/dev/null && pwd -P)" || return 1
	printf '%s/%s\n' "$parent" "$name"
}

verify_checkout_git_pointer() {
	local git_pointer="$REPO_ROOT/.git"
	local backlink=''
	local pointer_path=''
	if [[ -d "$git_pointer" ]]; then
		[[ ! -L "$git_pointer" ]] || die "$EXIT_FILESYSTEM" 'ordinary checkout .git must not be symlinked.'
		pointer_path="$(cd -P "$git_pointer" 2>/dev/null && pwd -P)" || die "$EXIT_FILESYSTEM" 'cannot resolve ordinary checkout .git directory.'
		[[ "$pointer_path" == "$GIT_DIR_REAL" ]] || die "$EXIT_FILESYSTEM" 'ordinary checkout .git does not match Git administration evidence.'
		return 0
	fi
	[[ -f "$git_pointer" && ! -L "$git_pointer" ]] || die "$EXIT_FILESYSTEM" 'checkout .git is neither a real directory nor a regular linked-worktree file.'
	[[ "$(regular_file_link_count "$git_pointer")" == 1 ]] || die "$EXIT_FILESYSTEM" 'linked-worktree .git file must have exactly one hard link.'
	exec 7<"$git_pointer" || die "$EXIT_FILESYSTEM" 'cannot open linked-worktree .git backlink.'
	IFS= read -r backlink <&7 || {
		exec 7<&-
		die "$EXIT_FILESYSTEM" 'cannot read linked-worktree .git backlink.'
	}
	if IFS= read -r <&7; then
		exec 7<&-
		die "$EXIT_FILESYSTEM" 'linked-worktree .git backlink must contain exactly one line.'
	fi
	exec 7<&-
	[[ "$backlink" == 'gitdir: '* ]] || die "$EXIT_FILESYSTEM" 'linked-worktree .git backlink has invalid format.'
	backlink="${backlink#gitdir: }"
	pointer_path="$(resolve_git_path "$backlink")" || die "$EXIT_FILESYSTEM" 'cannot resolve linked-worktree .git backlink.'
	[[ "$pointer_path" == "$GIT_DIR_REAL" ]] || die "$EXIT_FILESYSTEM" 'linked-worktree .git backlink does not match Git administration evidence.'
}

read_checkout_seal() {
	local seal_path="$GIT_DIR_REAL/.luna-checkout-identity"
	local seal=''
	local digest=''
	local seal_file_identity=''
	if [[ ! -e "$seal_path" && ! -L "$seal_path" ]]; then
		printf '%s\n' 'missing'
		return 0
	fi
	require_private_file "$seal_path" 'Git checkout identity seal'
	exec 7<"$seal_path" || die "$EXIT_FILESYSTEM" 'cannot open Git checkout identity seal.'
	IFS= read -r seal <&7 || {
		exec 7<&-
		die "$EXIT_FILESYSTEM" 'Git checkout identity seal is empty.'
	}
	if IFS= read -r <&7; then
		exec 7<&-
		die "$EXIT_FILESYSTEM" 'Git checkout identity seal must contain exactly one line.'
	fi
	exec 7<&-
	[[ "$seal" =~ ^[0-9a-f]{64}$ ]] || die "$EXIT_FILESYSTEM" 'Git checkout identity seal is not 256-bit lowercase hex.'
	digest="$(sha256_digest "$seal_path")" || die "$EXIT_FILESYSTEM" 'cannot digest Git checkout identity seal.'
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "$EXIT_FILESYSTEM" 'Git checkout identity seal digest is invalid.'
	seal_file_identity="$(file_identity "$seal_path")" || die "$EXIT_FILESYSTEM" 'cannot identify Git checkout identity seal.'
	printf '%s|digest:%s|file:%s\n' "$seal" "$digest" "$seal_file_identity"
}

create_checkout_seal() {
	local seal_path="$GIT_DIR_REAL/.luna-checkout-identity"
	local temp_path=''
	local random_seal=''
	if [[ -e "$seal_path" || -L "$seal_path" ]]; then
		read_checkout_seal
		return 0
	fi
	temp_path="$(mktemp "$GIT_DIR_REAL/.luna-checkout-identity.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create Git checkout identity seal temporary file: $GIT_DIR_REAL."
	chmod 0600 "$temp_path" || { rm -f "$temp_path"; die "$EXIT_FILESYSTEM" "cannot restrict Git checkout identity seal temporary file: $temp_path."; }
	random_seal="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')" || { rm -f "$temp_path"; die "$EXIT_FILESYSTEM" 'cannot generate Git checkout identity seal entropy.'; }
	[[ "$random_seal" =~ ^[0-9a-f]{64}$ ]] || { rm -f "$temp_path"; die "$EXIT_FILESYSTEM" 'generated Git checkout identity seal is not 256-bit lowercase hex.'; }
	printf '%s\n' "$random_seal" >"$temp_path" || { rm -f "$temp_path"; die "$EXIT_FILESYSTEM" "cannot write Git checkout identity seal temporary file: $temp_path."; }
	if ln -n "$temp_path" "$seal_path" 2>/dev/null; then
		rm "$temp_path" || die "$EXIT_FILESYSTEM" "cannot release Git checkout identity seal temporary link: $temp_path."
	else
		rm -f "$temp_path" || die "$EXIT_FILESYSTEM" "cannot remove Git checkout identity seal temporary file: $temp_path."
		[[ -e "$seal_path" || -L "$seal_path" ]] || die "$EXIT_FILESYSTEM" "Git checkout identity seal appeared or could not be created: $seal_path."
	fi
	read_checkout_seal
}

ensure_checkout_seal() {
	local seal_path="$GIT_DIR_REAL/.luna-checkout-identity"
	if [[ -e "$seal_path" || -L "$seal_path" ]]; then
		read_checkout_seal
	else
		create_checkout_seal
	fi
}

resolve_claim() {
	local repo_candidate=''
	local git_dir=''
	local git_common=''
	local root_identity=''
	local git_identity=''
	local common_identity=''
	[[ -d "$REPO_INPUT" ]] || die "$EXIT_USAGE" "repository path is not a directory: $REPO_INPUT."
	repo_candidate="$(cd -P "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve repository path: $REPO_INPUT."
	REPO_ROOT="$(git -C "$repo_candidate" rev-parse --show-toplevel 2>/dev/null)" || die "$EXIT_USAGE" "repository path is not inside a Git repository: $REPO_INPUT."
	REPO_ROOT="$(cd -P "$REPO_ROOT" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" 'cannot resolve Git checkout root.'
	case "$repo_candidate" in
	"$REPO_ROOT" | "$REPO_ROOT"/*) ;;
	*) die "$EXIT_USAGE" "Git recorded a different checkout root than the supplied path: $repo_candidate -> $REPO_ROOT." ;;
	esac
	git_dir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || die "$EXIT_FILESYSTEM" 'cannot resolve Git administration directory.'
	GIT_DIR_REAL="$(cd -P "$git_dir" 2>/dev/null && pwd -P)" || die "$EXIT_FILESYSTEM" 'cannot resolve physical Git administration directory.'
	git_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)" || die "$EXIT_FILESYSTEM" 'cannot resolve Git common directory.'
	case "$git_common" in
	/*) ;;
	*) git_common="$REPO_ROOT/$git_common" ;;
	esac
	GIT_COMMON_DIR_REAL="$(cd -P "$git_common" 2>/dev/null && pwd -P)" || die "$EXIT_FILESYSTEM" 'cannot resolve physical Git common directory.'
	require_owned_directory "$GIT_DIR_REAL" 'Git administration directory'
	require_owned_directory "$GIT_COMMON_DIR_REAL" 'Git common directory'
	verify_checkout_git_pointer
	root_identity="$(file_identity "$REPO_ROOT")" || die "$EXIT_FILESYSTEM" 'cannot identify physical checkout root.'
	git_identity="$(file_identity "$GIT_DIR_REAL")" || die "$EXIT_FILESYSTEM" 'cannot identify physical Git administration directory.'
	common_identity="$(file_identity "$GIT_COMMON_DIR_REAL")" || die "$EXIT_FILESYSTEM" 'cannot identify physical Git common directory.'
	select_sha256_command || die "$EXIT_PREREQUISITE" 'missing SHA-256 prerequisite: install shasum or sha256sum.'
	CHECKOUT_PHYSICAL_IDENTITY="root:$root_identity|gitdir:$git_identity|common:$common_identity"
	CLAIM_KEY="$(printf '%s\n%s\n' "$CHECKOUT_PHYSICAL_IDENTITY" "$SCOPE" | sha256_digest)" || die "$EXIT_FILESYSTEM" 'cannot derive cross-path claim key with the selected SHA-256 implementation.'
	[[ "$CLAIM_KEY" =~ ^[0-9a-f]{64}$ ]] || die "$EXIT_FILESYSTEM" 'cross-path claim key was not a SHA-256 digest.'
	CLAIM_ROOT="$GIT_COMMON_DIR_REAL/.luna-cross-path-claims"
	if [[ ! -e "$CLAIM_ROOT" && ! -L "$CLAIM_ROOT" ]]; then
		mkdir -m 700 "$CLAIM_ROOT" 2>/dev/null || [[ -d "$CLAIM_ROOT" && ! -L "$CLAIM_ROOT" ]] || die "$EXIT_FILESYSTEM" "cannot create cross-path claim root: $CLAIM_ROOT."
	fi
	require_owned_directory "$CLAIM_ROOT" 'cross-path claim root'
	local claim_root_mode=''
	claim_root_mode="$(path_owner_mode "$CLAIM_ROOT" | awk '{print $2}')"
	[[ "$claim_root_mode" == 700 ]] || die "$EXIT_FILESYSTEM" "cross-path claim root must have mode 0700: $CLAIM_ROOT has mode $claim_root_mode."
	CLAIM_PATH="$CLAIM_ROOT/$CLAIM_KEY"
}

set_checkout_identity() {
	local seal_identity=''
	seal_identity="$(ensure_checkout_seal)"
	[[ "$seal_identity" != 'missing' ]] || die "$EXIT_FILESYSTEM" 'Git checkout identity seal is missing after claim coordination.'
	CHECKOUT_IDENTITY="$CHECKOUT_PHYSICAL_IDENTITY|seal:$seal_identity"
}

release_claim_lock() {
	if [[ "$CLAIM_LOCK_HELD" -eq 1 ]]; then
		[[ -d "$CLAIM_LOCK_PATH" && ! -L "$CLAIM_LOCK_PATH" ]] || return 1
		rmdir "$CLAIM_LOCK_PATH" 2>/dev/null || return 1
		CLAIM_LOCK_HELD=0
	fi
}

remove_preflight_artifact() {
	local path="$1"
	[[ -n "$path" ]] || return 0
	if [[ ! -e "$path" && ! -L "$path" ]]; then
		return 0
	fi
	private_file_is_valid "$path" || return 1
	rm "$path"
}

preflight_control_state_is_valid() {
	local path="$1"
	local expected="$2"
	local state=''
	private_file_is_valid "$path" || return 1
	exec 7<"$path" || return 1
	IFS= read -r state <&7 || state=''
	if IFS= read -r <&7; then
		exec 7<&-
		return 1
	fi
	exec 7<&-
	[[ "$state" == "$expected" ]]
}

write_preflight_release_state() {
	local state="$1"
	local temp_path=''
	[[ -n "$REGISTRY_PREFLIGHT_RELEASE_PATH" && -n "$REGISTRY_PREFLIGHT_RELEASE_TOKEN" ]] || return 1
	temp_path="$(mktemp "$CLAIM_ROOT/.registry-preflight-release.XXXXXX")" || return 1
	if ! printf '%s:%s\n' "$state" "$REGISTRY_PREFLIGHT_RELEASE_TOKEN" >"$temp_path" || ! chmod 0600 "$temp_path" || ! private_file_is_valid "$temp_path"; then
		rm -f "$temp_path"
		return 1
	fi
	if ! mv -f "$temp_path" "$REGISTRY_PREFLIGHT_RELEASE_PATH"; then
		rm -f "$temp_path"
		return 1
	fi
	private_file_is_valid "$REGISTRY_PREFLIGHT_RELEASE_PATH" && preflight_control_state_is_valid "$REGISTRY_PREFLIGHT_RELEASE_PATH" "$state:$REGISTRY_PREFLIGHT_RELEASE_TOKEN"
}

signal_preflight_release() {
	[[ -n "$REGISTRY_PREFLIGHT_RELEASE_PATH" ]] || return 0
	if preflight_control_state_is_valid "$REGISTRY_PREFLIGHT_RELEASE_PATH" "release:$REGISTRY_PREFLIGHT_RELEASE_TOKEN"; then
		return 0
	fi
	preflight_control_state_is_valid "$REGISTRY_PREFLIGHT_RELEASE_PATH" "hold:$REGISTRY_PREFLIGHT_RELEASE_TOKEN" || return 1
	write_preflight_release_state release
}

stop_registry_preflight_lock() {
	local wait_status=0
	if [[ -n "$REGISTRY_PREFLIGHT_PID" ]]; then
		signal_preflight_release || wait_status=1
		wait_for_registry_preflight_helper "$REGISTRY_PREFLIGHT_PID" || wait_status=1
		REGISTRY_PREFLIGHT_PID=''
		REGISTRY_PREFLIGHT_INSTANCE=''
	fi
	remove_preflight_artifact "$REGISTRY_PREFLIGHT_READY_PATH" || wait_status=1
	remove_preflight_artifact "$REGISTRY_PREFLIGHT_RELEASE_PATH" || wait_status=1
	remove_preflight_artifact "$REGISTRY_PREFLIGHT_ERROR_PATH" || wait_status=1
	remove_preflight_artifact "$REGISTRY_PREFLIGHT_LOG_PATH" || wait_status=1
	REGISTRY_PREFLIGHT_READY_PATH=''
	REGISTRY_PREFLIGHT_RELEASE_PATH=''
	REGISTRY_PREFLIGHT_ERROR_PATH=''
	REGISTRY_PREFLIGHT_LOG_PATH=''
	REGISTRY_PREFLIGHT_RELEASE_TOKEN=''
	return "$wait_status"
}

process_is_live_non_zombie() {
	local pid="$1"
	local process_state=''
	if process_state="$(ps -p "$pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"; then
		case "$process_state" in
		'' | Z*) return 1 ;;
		*) return 0 ;;
		esac
	fi
	kill -0 "$pid" 2>/dev/null
}

process_instance_matches() {
	local pid="$1"
	local expected="$2"
	[[ -n "$expected" ]] || return 1
	[[ "$(process_instance_identity "$pid" 2>/dev/null)" == "$expected" ]]
}

wait_for_registry_preflight_helper() {
	local pid="$1"
	wait "$pid" 2>/dev/null
}

collect_fallback_preflight_exit() {
	local pid="$1"
	local preflight_status=0
	if wait "$pid"; then
		preflight_status=0
	else
		preflight_status=$?
	fi
	REGISTRY_PREFLIGHT_PID=''
	REGISTRY_PREFLIGHT_INSTANCE=''
	if [[ -s "$REGISTRY_PREFLIGHT_ERROR_PATH" ]]; then
		cat "$REGISTRY_PREFLIGHT_ERROR_PATH" >&2 || true
	fi
	if [[ -s "$REGISTRY_PREFLIGHT_LOG_PATH" ]]; then
		cat "$REGISTRY_PREFLIGHT_LOG_PATH" >&2 || true
	fi
	[[ "$preflight_status" -eq 0 ]] || die "$EXIT_RUNTIME_STATE" "fallback registry preflight failed with status $preflight_status before checkout-seal creation and claim publication. Resolve the preflight diagnostic and retry."
	die "$EXIT_RUNTIME_STATE" 'fallback registry preflight exited without publishing readiness before checkout-seal creation and claim publication.'
}

cleanup_coordination() {
	local exit_code=$?
	local cleanup_status=0
	trap - EXIT
	stop_registry_preflight_lock >/dev/null 2>&1 || cleanup_status=1
	release_claim_lock >/dev/null 2>&1 || cleanup_status=1
	if [[ "$cleanup_status" -ne 0 && "$exit_code" -eq 0 ]]; then
		exit_code="$EXIT_RUNTIME_STATE"
	fi
	exit "$exit_code"
}

trap cleanup_coordination EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

run_fallback_preflight() {
	local parent_instance=''
	local ready_state=''
	[[ -f "$SCRIPT_DIR/registry.sh" && ! -L "$SCRIPT_DIR/registry.sh" ]] || die "$EXIT_FILESYSTEM" "fallback registry preflight primitive is unavailable: $SCRIPT_DIR/registry.sh."
	parent_instance="$(process_instance_identity "$$")" || die "$EXIT_RUNTIME_STATE" 'cannot identify fallback preflight parent process.'
	REGISTRY_PREFLIGHT_READY_PATH="$(mktemp "$CLAIM_ROOT/.registry-preflight-ready.XXXXXX")" || die "$EXIT_FILESYSTEM" 'cannot create fallback preflight readiness file.'
	chmod 0600 "$REGISTRY_PREFLIGHT_READY_PATH" || die "$EXIT_FILESYSTEM" 'cannot restrict fallback preflight readiness file.'
	REGISTRY_PREFLIGHT_RELEASE_PATH="$(mktemp "$CLAIM_ROOT/.registry-preflight-release.XXXXXX")" || die "$EXIT_FILESYSTEM" 'cannot create fallback preflight release file.'
	chmod 0600 "$REGISTRY_PREFLIGHT_RELEASE_PATH" || die "$EXIT_FILESYSTEM" 'cannot restrict fallback preflight release file.'
	REGISTRY_PREFLIGHT_RELEASE_TOKEN="$(printf '%s\n' "$$-${RANDOM:-0}-$(date -u '+%s%N')" | sha256_digest)" || die "$EXIT_RUNTIME_STATE" 'cannot derive fallback preflight release token.'
	printf 'pending:%s\n' "$REGISTRY_PREFLIGHT_RELEASE_TOKEN" >"$REGISTRY_PREFLIGHT_READY_PATH" || die "$EXIT_FILESYSTEM" 'cannot initialize fallback preflight readiness file.'
	printf 'hold:%s\n' "$REGISTRY_PREFLIGHT_RELEASE_TOKEN" >"$REGISTRY_PREFLIGHT_RELEASE_PATH" || die "$EXIT_FILESYSTEM" 'cannot initialize fallback preflight release file.'
	private_file_is_valid "$REGISTRY_PREFLIGHT_RELEASE_PATH" || die "$EXIT_FILESYSTEM" 'fallback preflight release file is not private.'
	preflight_control_state_is_valid "$REGISTRY_PREFLIGHT_RELEASE_PATH" "hold:$REGISTRY_PREFLIGHT_RELEASE_TOKEN" || die "$EXIT_FILESYSTEM" 'fallback preflight release file has invalid initial state.'
	REGISTRY_PREFLIGHT_ERROR_PATH="$(mktemp "$CLAIM_ROOT/.registry-preflight-error.XXXXXX")" || die "$EXIT_FILESYSTEM" 'cannot create fallback preflight diagnostic file.'
	chmod 0600 "$REGISTRY_PREFLIGHT_ERROR_PATH" || die "$EXIT_FILESYSTEM" 'cannot restrict fallback preflight diagnostic file.'
	REGISTRY_PREFLIGHT_LOG_PATH="$(mktemp "$CLAIM_ROOT/.registry-preflight-log.XXXXXX")" || die "$EXIT_FILESYSTEM" 'cannot create fallback preflight log file.'
	chmod 0600 "$REGISTRY_PREFLIGHT_LOG_PATH" || die "$EXIT_FILESYSTEM" 'cannot restrict fallback preflight log file.'
	bash "$SCRIPT_DIR/registry.sh" preflight-lock \
		--repo "$REPO_INPUT" \
		--ready-file "$REGISTRY_PREFLIGHT_READY_PATH" \
		--release-file "$REGISTRY_PREFLIGHT_RELEASE_PATH" \
		--ready-token "$REGISTRY_PREFLIGHT_RELEASE_TOKEN" \
		--release-token "$REGISTRY_PREFLIGHT_RELEASE_TOKEN" \
		--error-file "$REGISTRY_PREFLIGHT_ERROR_PATH" \
		--parent-pid "$$" \
		--parent-instance "$parent_instance" \
		>/dev/null 2>"$REGISTRY_PREFLIGHT_LOG_PATH" &
	REGISTRY_PREFLIGHT_PID=$!
	if ! REGISTRY_PREFLIGHT_INSTANCE="$(process_instance_identity "$REGISTRY_PREFLIGHT_PID")"; then
		if ! process_is_live_non_zombie "$REGISTRY_PREFLIGHT_PID"; then
			collect_fallback_preflight_exit "$REGISTRY_PREFLIGHT_PID"
		fi
		die "$EXIT_RUNTIME_STATE" 'cannot identify fallback preflight helper process.'
	fi
	while true; do
		ready_state="$(cat "$REGISTRY_PREFLIGHT_READY_PATH" 2>/dev/null || true)"
		case "$ready_state" in
		"ready=locked:$REGISTRY_PREFLIGHT_RELEASE_TOKEN" | "ready=unlocked:$REGISTRY_PREFLIGHT_RELEASE_TOKEN") return 0 ;;
		"pending:$REGISTRY_PREFLIGHT_RELEASE_TOKEN") ;;
		*) die "$EXIT_RUNTIME_STATE" 'fallback registry preflight published invalid readiness state.' ;;
		esac
		if ! process_is_live_non_zombie "$REGISTRY_PREFLIGHT_PID"; then
			collect_fallback_preflight_exit "$REGISTRY_PREFLIGHT_PID"
		fi
		process_instance_matches "$REGISTRY_PREFLIGHT_PID" "$REGISTRY_PREFLIGHT_INSTANCE" || die "$EXIT_RUNTIME_STATE" 'fallback registry preflight helper process identity changed before readiness.'
		sleep 0.01
	done
}

finish_fallback_preflight() {
	local preflight_status=0
	[[ -n "$REGISTRY_PREFLIGHT_PID" ]] || return 0
	signal_preflight_release || die "$EXIT_FILESYSTEM" 'cannot release registry lock after fallback claim publication.'
	wait_for_registry_preflight_helper "$REGISTRY_PREFLIGHT_PID" || preflight_status=$?
	REGISTRY_PREFLIGHT_PID=''
	REGISTRY_PREFLIGHT_INSTANCE=''
	if [[ "$preflight_status" -ne 0 ]]; then
		if [[ -s "$REGISTRY_PREFLIGHT_ERROR_PATH" ]]; then
			cat "$REGISTRY_PREFLIGHT_ERROR_PATH" >&2 || true
		fi
		if [[ -s "$REGISTRY_PREFLIGHT_LOG_PATH" ]]; then
			cat "$REGISTRY_PREFLIGHT_LOG_PATH" >&2 || true
		fi
	fi
	[[ "$preflight_status" -eq 0 ]] || die "$EXIT_RUNTIME_STATE" "fallback registry preflight lock helper exited with status $preflight_status after claim publication. Preserve claim and checkout seal for recovery."
	remove_preflight_artifact "$REGISTRY_PREFLIGHT_READY_PATH" || die "$EXIT_FILESYSTEM" 'cannot remove fallback preflight readiness file.'
	remove_preflight_artifact "$REGISTRY_PREFLIGHT_RELEASE_PATH" || die "$EXIT_FILESYSTEM" 'cannot remove fallback preflight release file.'
	remove_preflight_artifact "$REGISTRY_PREFLIGHT_ERROR_PATH" || die "$EXIT_FILESYSTEM" 'cannot remove fallback preflight diagnostic file.'
	remove_preflight_artifact "$REGISTRY_PREFLIGHT_LOG_PATH" || die "$EXIT_FILESYSTEM" 'cannot remove fallback preflight log file.'
	REGISTRY_PREFLIGHT_READY_PATH=''
	REGISTRY_PREFLIGHT_RELEASE_PATH=''
	REGISTRY_PREFLIGHT_ERROR_PATH=''
	REGISTRY_PREFLIGHT_LOG_PATH=''
}

acquire_claim_lock() {
	local attempt=0
	local lock_metadata=''
	local lock_owner=''
	local lock_mode=''
	CLAIM_LOCK_PATH="$CLAIM_ROOT/.claim-lock-$CLAIM_KEY"
	while true; do
		[[ ! -L "$CLAIM_LOCK_PATH" ]] || die "$EXIT_FILESYSTEM" "cross-path claim lock must not be a symlink: $CLAIM_LOCK_PATH."
		if mkdir -m 700 "$CLAIM_LOCK_PATH" 2>/dev/null; then
			require_owned_directory "$CLAIM_LOCK_PATH" 'cross-path claim lock'
			CLAIM_LOCK_HELD=1
			return 0
		fi
		if [[ ! -e "$CLAIM_LOCK_PATH" && ! -L "$CLAIM_LOCK_PATH" ]]; then
			attempt=$((attempt + 1))
			[[ "$attempt" -lt 100 ]] || die "$EXIT_CONFLICT" "cross-path claim lock is busy: $CLAIM_LOCK_PATH. Inspect it and retry after its owner exits."
			sleep 0.01
			continue
		fi
		[[ -d "$CLAIM_LOCK_PATH" && ! -L "$CLAIM_LOCK_PATH" ]] || die "$EXIT_FILESYSTEM" "cross-path claim lock must be a real directory: $CLAIM_LOCK_PATH."
		if ! lock_metadata="$(path_owner_mode "$CLAIM_LOCK_PATH")"; then
			if [[ ! -e "$CLAIM_LOCK_PATH" && ! -L "$CLAIM_LOCK_PATH" ]]; then
				attempt=$((attempt + 1))
				[[ "$attempt" -lt 100 ]] || die "$EXIT_CONFLICT" "cross-path claim lock is busy: $CLAIM_LOCK_PATH. Inspect it and retry after its owner exits."
				sleep 0.01
				continue
			fi
			die "$EXIT_FILESYSTEM" "cannot inspect cross-path claim lock ownership and permissions: $CLAIM_LOCK_PATH."
		fi
		read -r lock_owner lock_mode <<<"$lock_metadata"
		[[ "$lock_owner" == "$UID" ]] || die "$EXIT_FILESYSTEM" "cross-path claim lock must be owned by UID $UID: $CLAIM_LOCK_PATH is owned by UID $lock_owner."
		(( (8#$lock_mode & 022) == 0 )) || die "$EXIT_FILESYSTEM" "cross-path claim lock must not be group- or world-writable: $CLAIM_LOCK_PATH has mode $lock_mode."
		attempt=$((attempt + 1))
		[[ "$attempt" -lt 100 ]] || die "$EXIT_CONFLICT" "cross-path claim lock is busy: $CLAIM_LOCK_PATH. Inspect it and retry after its owner exits."
		sleep 0.01
	done
}

write_owner() {
	local owner_tmp=''
	owner_tmp="$(mktemp "$CLAIM_ROOT/.claim.XXXXXX")" || return 1
	if ! printf 'version=1\nidentity=%s\nscope=%s\ntoken=%s\npid=%s\n' \
		"$CHECKOUT_IDENTITY" "$CLAIM_KEY" "$TOKEN" "$$" >"$owner_tmp"; then
		rm -f "$owner_tmp"
		return 1
	fi
	if ! chmod 0600 "$owner_tmp"; then
		rm -f "$owner_tmp"
		return 1
	fi
	if ! private_file_is_valid "$owner_tmp" || ! owner_metadata_shape_is_valid "$owner_tmp"; then
		rm -f "$owner_tmp"
		return 1
	fi
	if [[ -e "$CLAIM_PATH" || -L "$CLAIM_PATH" ]] || ! ln -n "$owner_tmp" "$CLAIM_PATH" 2>/dev/null; then
		rm -f "$owner_tmp"
		return 1
	fi
	if ! rm "$owner_tmp" || ! private_file_is_valid "$CLAIM_PATH" || ! owner_metadata_shape_is_valid "$CLAIM_PATH"; then
		rm -f "$CLAIM_PATH" "$owner_tmp"
		return 1
	fi
}

read_owner_field() {
	local field="$1"
	[[ -f "$CLAIM_PATH" && ! -L "$CLAIM_PATH" ]] || return 1
	awk -F= -v field="$field" '$1 == field {print substr($0, index($0, "=") + 1); exit}' "$CLAIM_PATH"
}

claim_owner_matches() {
	local stored_version
	local stored_identity
	local stored_scope
	local stored_token
	private_file_is_valid "$CLAIM_PATH" || return 1
	owner_metadata_shape_is_valid "$CLAIM_PATH" || return 1
	stored_version="$(read_owner_field version)" || return 1
	stored_identity="$(read_owner_field identity)" || return 1
	stored_scope="$(read_owner_field scope)" || return 1
	stored_token="$(read_owner_field token)" || return 1
	[[ "$stored_version" == 1 && "$stored_identity" == "$CHECKOUT_IDENTITY" && "$stored_scope" == "$CLAIM_KEY" && "$stored_token" == "$TOKEN" ]]
}

acquire_claim() {
	resolve_claim
	acquire_claim_lock
	if [[ "$FALLBACK_PREFLIGHT" -eq 1 ]]; then
		run_fallback_preflight
	fi
	set_checkout_identity
	if [[ "$REENTER" -eq 1 || "$REENTER_OR_ACQUIRE" -eq 1 ]]; then
		if [[ -L "$CLAIM_PATH" || -e "$CLAIM_PATH" && ! -f "$CLAIM_PATH" ]]; then
			die "$EXIT_FILESYSTEM" "cross-path claim path is not a real regular file: $CLAIM_PATH."
		fi
		if [[ -f "$CLAIM_PATH" ]] && claim_owner_matches; then
			printf 'Re-entered cross-path claim=%s\n' "$CLAIM_KEY"
			if [[ "$FALLBACK_PREFLIGHT" -eq 1 ]]; then
				finish_fallback_preflight
			fi
			release_claim_lock || die "$EXIT_FILESYSTEM" 'cannot release cross-path claim lock after re-entry.'
			return 0
		fi
		if [[ "$REENTER_OR_ACQUIRE" -eq 1 && ! -e "$CLAIM_PATH" && ! -L "$CLAIM_PATH" ]]; then
			if write_owner; then
				printf 'Acquired cross-path claim=%s\n' "$CLAIM_KEY"
				if [[ "$FALLBACK_PREFLIGHT" -eq 1 ]]; then
					finish_fallback_preflight
				fi
				release_claim_lock || die "$EXIT_FILESYSTEM" 'cannot release cross-path claim lock after acquisition.'
				return 0
			fi
			if [[ -L "$CLAIM_PATH" || -e "$CLAIM_PATH" && ! -f "$CLAIM_PATH" ]]; then
				die "$EXIT_FILESYSTEM" "cross-path claim path is not a real regular file: $CLAIM_PATH."
			fi
		fi
		die "$EXIT_CONFLICT" "cannot re-enter cross-path claim that is not held by this owner: $CLAIM_KEY."
	fi
	if write_owner; then
		printf 'Acquired cross-path claim=%s\n' "$CLAIM_KEY"
		if [[ "$FALLBACK_PREFLIGHT" -eq 1 ]]; then
			finish_fallback_preflight
		fi
		release_claim_lock || die "$EXIT_FILESYSTEM" 'cannot release cross-path claim lock after acquisition.'
		return 0
	fi
	if [[ -L "$CLAIM_PATH" || -e "$CLAIM_PATH" && ! -f "$CLAIM_PATH" ]]; then
		die "$EXIT_FILESYSTEM" "cross-path claim path is not a real regular file: $CLAIM_PATH."
	fi
	die "$EXIT_CONFLICT" "cross-path claim is already held for this checkout and immutable scope: $CLAIM_KEY."
}

release_claim() {
	local stored_version
	local stored_identity
	local stored_scope
	local stored_token
	resolve_claim
	acquire_claim_lock
	[[ -e "$GIT_DIR_REAL/.luna-checkout-identity" || -L "$GIT_DIR_REAL/.luna-checkout-identity" ]] || die "$EXIT_FILESYSTEM" 'Git checkout identity seal is missing; refusing to release a claim.'
	set_checkout_identity
	if [[ -L "$CLAIM_PATH" || -e "$CLAIM_PATH" && ! -f "$CLAIM_PATH" ]]; then
		die "$EXIT_FILESYSTEM" "cross-path claim path is not a real regular file: $CLAIM_PATH."
	fi
	[[ -f "$CLAIM_PATH" ]] || die "$EXIT_CONFLICT" "cross-path claim is not held: $CLAIM_KEY."
	private_file_is_valid "$CLAIM_PATH" || die "$EXIT_CONFLICT" 'cross-path claim has no valid owner metadata; refusing to guess ownership.'
	owner_metadata_shape_is_valid "$CLAIM_PATH" || die "$EXIT_CONFLICT" 'cross-path claim owner metadata is malformed; refusing to guess ownership.'
	stored_version="$(read_owner_field version)" || die "$EXIT_CONFLICT" 'cross-path claim has no valid owner metadata; refusing to guess ownership.'
	stored_identity="$(read_owner_field identity)" || die "$EXIT_CONFLICT" 'cross-path claim owner identity is missing; refusing to guess ownership.'
	stored_scope="$(read_owner_field scope)" || die "$EXIT_CONFLICT" 'cross-path claim owner scope is missing; refusing to guess ownership.'
	stored_token="$(read_owner_field token)" || die "$EXIT_CONFLICT" 'cross-path claim owner token is missing; refusing to guess ownership.'
	[[ "$stored_version" == 1 && "$stored_identity" == "$CHECKOUT_IDENTITY" && "$stored_scope" == "$CLAIM_KEY" ]] || die "$EXIT_CONFLICT" 'cross-path claim owner metadata does not match this checkout and scope.'
	[[ "$stored_token" == "$TOKEN" ]] || die "$EXIT_CONFLICT" 'cross-path claim token does not match its owner.'
	rm "$CLAIM_PATH" || die "$EXIT_FILESYSTEM" 'cannot remove cross-path claim file.'
	release_claim_lock || die "$EXIT_FILESYSTEM" 'cannot release cross-path claim lock after claim removal.'
	printf 'Released cross-path claim=%s\n' "$CLAIM_KEY"
}

[[ $# -gt 0 ]] || usage "$EXIT_USAGE"
MODE="$1"
shift
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo | -C)
		[[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for $1."
		REPO_INPUT="$2"
		shift 2
		;;
	--scope)
		[[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing scope.'
		SCOPE="$2"
		shift 2
		;;
	--token)
		[[ $# -ge 2 ]] || die "$EXIT_USAGE" 'missing token.'
		TOKEN="$2"
		shift 2
		;;
		--reenter)
			REENTER=1
			shift
			;;
		--reenter-or-acquire)
			REENTER_OR_ACQUIRE=1
			shift
			;;
		--fallback-preflight)
			FALLBACK_PREFLIGHT=1
			shift
			;;
	--help | -h) usage "$EXIT_OK" ;;
	*) die "$EXIT_USAGE" "unknown argument: $1." ;;
	esac
done

case "$MODE" in
acquire) ;;
release)
		[[ "$REENTER" -eq 0 && "$REENTER_OR_ACQUIRE" -eq 0 && "$FALLBACK_PREFLIGHT" -eq 0 ]] || die "$EXIT_USAGE" 'reentry and fallback-preflight options are only valid with acquire.'
		;;
*) die "$EXIT_USAGE" "unknown command: $MODE. Use --help for usage." ;;
esac
[[ "$REENTER" -eq 0 || "$REENTER_OR_ACQUIRE" -eq 0 ]] || die "$EXIT_USAGE" '--reenter and --reenter-or-acquire cannot be combined.'
[[ "$FALLBACK_PREFLIGHT" -eq 0 || "$MODE" == acquire ]] || die "$EXIT_USAGE" '--fallback-preflight is only valid with acquire.'
validate_scope
validate_token
case "$MODE" in
acquire) acquire_claim ;;
release) release_claim ;;
esac
