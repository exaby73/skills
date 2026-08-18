#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFLICT=6
readonly EXIT_FILESYSTEM=10

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR='.'
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd -P)"
readonly SCRIPT_DIR

REPO_INPUT='.'
SCOPE=''
TOKEN=''
REENTER=0
CLAIM_ROOT=''
CLAIM_PATH=''
CLAIM_KEY=''
CHECKOUT_PHYSICAL_IDENTITY=''
CHECKOUT_IDENTITY=''
SHA256_COMMAND=''

usage() {
	local exit_code="${1:-0}"
	cat <<'EOF'
Usage:
  cross-path-claim.sh acquire --repo PATH --scope TEXT --token TOKEN
  cross-path-claim.sh acquire --reenter --repo PATH --scope TEXT --token TOKEN
  cross-path-claim.sh release --repo PATH --scope TEXT --token TOKEN

The claim is shared by native startup and the CLI fallback reservation. It is
keyed by physical checkout identity plus immutable scope and is separate from
the project-local fallback registry. Initial acquisition is exclusive; a
continuation must explicitly use --reenter with the stable owner token.
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
	local seal_identity=''
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
	seal_identity="$(ensure_checkout_seal)"
	CHECKOUT_PHYSICAL_IDENTITY="root:$root_identity|gitdir:$git_identity|common:$common_identity"
	CHECKOUT_IDENTITY="$CHECKOUT_PHYSICAL_IDENTITY|seal:$seal_identity"
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
	if [[ "$REENTER" -eq 1 ]]; then
		if [[ -L "$CLAIM_PATH" || -e "$CLAIM_PATH" && ! -f "$CLAIM_PATH" ]]; then
			die "$EXIT_FILESYSTEM" "cross-path claim path is not a real regular file: $CLAIM_PATH."
		fi
		if [[ -f "$CLAIM_PATH" ]] && claim_owner_matches; then
			printf 'Re-entered cross-path claim=%s\n' "$CLAIM_KEY"
			return 0
		fi
		die "$EXIT_CONFLICT" "cannot re-enter cross-path claim that is not held by this owner: $CLAIM_KEY."
	fi
	if write_owner; then
		printf 'Acquired cross-path claim=%s\n' "$CLAIM_KEY"
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
	--help | -h) usage "$EXIT_OK" ;;
	*) die "$EXIT_USAGE" "unknown argument: $1." ;;
	esac
done

case "$MODE" in
acquire) ;;
release)
	[[ "$REENTER" -eq 0 ]] || die "$EXIT_USAGE" '--reenter is only valid with acquire.'
	;;
*) die "$EXIT_USAGE" "unknown command: $MODE. Use --help for usage." ;;
esac
validate_scope
validate_token
case "$MODE" in
acquire) acquire_claim ;;
release) release_claim ;;
esac
