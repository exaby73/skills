#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CLAIM_SCRIPT="$SCRIPT_DIR/cross-path-claim.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/luna-cross-path-claim.XXXXXX")"
cleanup_test_root() {
	local process_id
	for process_id in "${pid_a:-}" "${pid_b:-}" "${release_pid_a:-}" "${release_pid_b:-}" "${new_owner_pid:-}" "${fallback_preflight_pid:-}" "${fallback_competing_pid:-}"; do
		[[ -n "$process_id" ]] || continue
		kill "$process_id" 2>/dev/null || true
		wait "$process_id" 2>/dev/null || true
	done
	if [[ "${KEEP_TEST_ROOT:-0}" == 1 ]]; then
		printf 'Preserved test root: %s\n' "$TEST_ROOT" >&2
	else
		rm -rf -- "$TEST_ROOT"
	fi
}
trap cleanup_test_root EXIT

REPO_ROOT="$TEST_ROOT/repository"
mkdir -m 0700 "$REPO_ROOT"
git init -q "$REPO_ROOT"
SCOPE='same canonical checkout and immutable scope'

claim_race_bin="$TEST_ROOT/claim-race-bin"
claim_race_winner_marker="$TEST_ROOT/claim-race-winner-lock"
claim_race_loser_marker="$TEST_ROOT/claim-race-loser-mkdir-failed"
claim_race_release_marker="$TEST_ROOT/claim-race-lock-released"
mkdir -m 0700 "$claim_race_bin"
claim_real_mkdir="$(command -p -v mkdir)"
claim_real_rmdir="$(command -p -v rmdir)"
cat >"$claim_race_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
status=0
"${LUNA_TEST_REAL_MKDIR:?}" "$@" || status=$?
if [[ "$target" == */.claim-lock-* ]]; then
	if [[ "$status" -eq 0 && "${LUNA_TEST_LOCK_WINNER:-0}" == 1 ]]; then
		: >"${LUNA_TEST_LOCK_WINNER_MARKER:?}"
		while [[ ! -e "${LUNA_TEST_LOCK_LOSER_MARKER:?}" ]]; do
			sleep 0.01
		done
	elif [[ "$status" -ne 0 && "${LUNA_TEST_LOCK_LOSER:-0}" == 1 ]]; then
		: >"${LUNA_TEST_LOCK_LOSER_MARKER:?}"
		while [[ ! -e "${LUNA_TEST_LOCK_RELEASE_MARKER:?}" ]]; do
			sleep 0.01
		done
	fi
fi
exit "$status"
EOF
chmod 0700 "$claim_race_bin/mkdir"
cat >"$claim_race_bin/rmdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
status=0
"${LUNA_TEST_REAL_RMDIR:?}" "$@" || status=$?
if [[ "$status" -eq 0 && "${LUNA_TEST_LOCK_WINNER:-0}" == 1 && "$target" == */.claim-lock-* ]]; then
	: >"${LUNA_TEST_LOCK_RELEASE_MARKER:?}"
fi
exit "$status"
EOF
chmod 0700 "$claim_race_bin/rmdir"

set +e
LUNA_TEST_LOCK_WINNER=1 \
LUNA_TEST_REAL_MKDIR="$claim_real_mkdir" \
LUNA_TEST_REAL_RMDIR="$claim_real_rmdir" \
LUNA_TEST_LOCK_WINNER_MARKER="$claim_race_winner_marker" \
LUNA_TEST_LOCK_LOSER_MARKER="$claim_race_loser_marker" \
LUNA_TEST_LOCK_RELEASE_MARKER="$claim_race_release_marker" \
PATH="$claim_race_bin:$PATH" \
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$SCOPE" --token token-a >"$TEST_ROOT/a.out" 2>"$TEST_ROOT/a.err" &
pid_a=$!
race_wait_attempt=0
while [[ ! -e "$claim_race_winner_marker" && "$race_wait_attempt" -lt 1000 ]]; do
	sleep 0.01
	race_wait_attempt=$((race_wait_attempt + 1))
done
[[ -e "$claim_race_winner_marker" ]] || {
	printf 'race winner did not acquire claim lock\n' >&2
	exit 1
}
LUNA_TEST_LOCK_LOSER=1 \
LUNA_TEST_REAL_MKDIR="$claim_real_mkdir" \
LUNA_TEST_REAL_RMDIR="$claim_real_rmdir" \
LUNA_TEST_LOCK_WINNER_MARKER="$claim_race_winner_marker" \
LUNA_TEST_LOCK_LOSER_MARKER="$claim_race_loser_marker" \
LUNA_TEST_LOCK_RELEASE_MARKER="$claim_race_release_marker" \
PATH="$claim_race_bin:$PATH" \
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$SCOPE" --token token-b >"$TEST_ROOT/b.out" 2>"$TEST_ROOT/b.err" &
pid_b=$!
race_wait_attempt=0
while [[ ! -e "$claim_race_loser_marker" && "$race_wait_attempt" -lt 1000 ]]; do
	sleep 0.01
	race_wait_attempt=$((race_wait_attempt + 1))
done
[[ -e "$claim_race_loser_marker" ]] || {
	printf 'race loser did not observe busy claim lock\n' >&2
	exit 1
}
race_wait_attempt=0
while [[ ! -e "$claim_race_release_marker" && "$race_wait_attempt" -lt 1000 ]]; do
	sleep 0.01
	race_wait_attempt=$((race_wait_attempt + 1))
done
[[ -e "$claim_race_release_marker" ]] || {
	printf 'race winner did not release claim lock\n' >&2
	exit 1
}
status_a=0
status_b=0
wait "$pid_a" || status_a=$?
wait "$pid_b" || status_b=$?
pid_a=''
pid_b=''
set -e

if [[ "$status_a" -eq 0 && "$status_b" -eq 6 ]]; then
	winner=token-a
else
	printf 'expected one successful claim and one conflict; statuses were %s and %s\n' "$status_a" "$status_b" >&2
	exit 1
fi

seal_path="$REPO_ROOT/.git/.luna-checkout-identity"
[[ -f "$seal_path" && ! -L "$seal_path" ]] || {
	printf 'checkout identity seal was not atomically created: %s\n' "$seal_path" >&2
	exit 1
}
seal_value="$(cat "$seal_path")"
[[ "$seal_value" =~ ^[0-9a-f]{64}$ ]] || {
	printf 'checkout identity seal was not a lowercase 256-bit value: %s\n' "$seal_path" >&2
	exit 1
}

claim_root="$REPO_ROOT/.git/.luna-cross-path-claims"
claim_path="$(find "$claim_root" -mindepth 1 -maxdepth 1 -type f -print -quit)"
claim_key="${claim_path##*/}"
[[ -n "$claim_path" && "$claim_key" =~ ^[0-9a-f]{64}$ ]] || {
	printf 'cross-path claim key was not a lowercase 256-bit digest: %s\n' "$claim_key" >&2
	exit 1
}

[[ -f "$claim_path" && ! -L "$claim_path" ]] || {
	printf 'cross-path claim was not published as one regular file: %s\n' "$claim_path" >&2
	exit 1
}
claim_mode="$(stat -c '%a' "$claim_path" 2>/dev/null || stat -f '%Lp' "$claim_path")"
claim_links="$(stat -c '%h' "$claim_path" 2>/dev/null || stat -f '%l' "$claim_path")"
[[ "$claim_mode" == '600' && "$claim_links" == '1' ]] || {
	printf 'cross-path claim was not private and single-link: mode=%s links=%s\n' "$claim_mode" "$claim_links" >&2
	exit 1
}
rg -q '^identity=.*\|seal:' "$claim_path" || {
	printf 'cross-path claim owner metadata did not preserve seal evidence: %s\n' "$claim_path" >&2
	exit 1
}
rg -q '^scope=[0-9a-f]{64}$' "$claim_path" || {
	printf 'cross-path claim owner metadata did not preserve claim key: %s\n' "$claim_path" >&2
	exit 1
}
[[ -z "$(find "$claim_root" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]] || {
	printf 'cross-path claim left a directory representation: %s\n' "$claim_root" >&2
	exit 1
}

set +e
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$SCOPE" --token "$winner" >/dev/null 2>"$TEST_ROOT/reentry-required.err"
same_owner_status=$?
set -e
[[ "$same_owner_status" -eq 6 ]] || {
	printf 'expected same-owner acquisition without --reenter to conflict; status was %s\n' "$same_owner_status" >&2
	exit 1
}

bash "$CLAIM_SCRIPT" acquire --reenter --repo "$REPO_ROOT" --scope "$SCOPE" --token "$winner" >/dev/null

replacement_seal="$(printf '%064x' 1)"
printf '%s\n' "$replacement_seal" >"$seal_path"
chmod 0600 "$seal_path"
set +e
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$SCOPE" --token token-after-seal-replacement >/dev/null 2>"$TEST_ROOT/seal-replacement.err"
seal_replacement_status=$?
set -e
[[ "$seal_replacement_status" -eq 6 ]] || {
	printf 'seal replacement bypassed the active claim; status was %s\n' "$seal_replacement_status" >&2
	exit 1
}
claim_path_after_seal="$(find "$claim_root" -mindepth 1 -maxdepth 1 -type f -print -quit)"
[[ "$claim_path_after_seal" == "$claim_path" ]] || {
	printf 'seal replacement derived a different claim path: %s -> %s\n' "$claim_path" "$claim_path_after_seal" >&2
	exit 1
}
set +e
bash "$CLAIM_SCRIPT" acquire --reenter --repo "$REPO_ROOT" --scope "$SCOPE" --token "$winner" >/dev/null 2>"$TEST_ROOT/reentry-after-seal-replacement.err"
reentry_after_seal_status=$?
set -e
[[ "$reentry_after_seal_status" -eq 6 ]] || {
	printf 'seal replacement did not fail closed for same-owner re-entry; status was %s\n' "$reentry_after_seal_status" >&2
	exit 1
}
printf '%s\n' "$seal_value" >"$seal_path"
chmod 0600 "$seal_path"

release_bin="$TEST_ROOT/release-bin"
release_marker="$TEST_ROOT/release-paused"
release_gate="$TEST_ROOT/release-gate"
release_a_lock_marker="$TEST_ROOT/release-a-lock-acquired"
release_a_lock_gate="$TEST_ROOT/release-a-lock-gate"
release_a_lock_released="$TEST_ROOT/release-a-lock-released"
new_owner_bin="$TEST_ROOT/new-owner-bin"
new_owner_lock_marker="$TEST_ROOT/new-owner-lock-waiting"
mkdir -m 0700 "$release_bin"
mkdir -m 0700 "$new_owner_bin"
release_real_rm="$(command -p -v rm)"
release_real_mkdir="$(command -p -v mkdir)"
release_real_rmdir="$(command -p -v rmdir)"
cat >"$release_bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${LUNA_TEST_RELEASE_PAUSE:-0}" == 1 && "${1:-}" == *"/.luna-cross-path-claims/${LUNA_TEST_CLAIM_KEY:?}" ]]; then
	: >"${LUNA_TEST_RELEASE_MARKER:?}"
	while [[ ! -e "${LUNA_TEST_RELEASE_GATE:?}" ]]; do
		sleep 0.01
	done
fi
exec "${LUNA_TEST_REAL_RM:?}" "$@"
EOF
chmod 0700 "$release_bin/rm"
cat >"$release_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
status=0
"${LUNA_TEST_REAL_MKDIR:?}" "$@" || status=$?
if [[ "$status" -eq 0 && "$target" == */.claim-lock-* && "${LUNA_TEST_RELEASE_A_PAUSE:-0}" == 1 ]]; then
	: >"${LUNA_TEST_RELEASE_A_LOCK_MARKER:?}"
	while [[ ! -e "${LUNA_TEST_RELEASE_A_LOCK_GATE:?}" ]]; do
		sleep 0.01
	done
fi
exit "$status"
EOF
chmod 0700 "$release_bin/mkdir"
cat >"$release_bin/rmdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
status=0
"${LUNA_TEST_REAL_RMDIR:?}" "$@" || status=$?
if [[ "$status" -eq 0 && "$target" == */.claim-lock-* && "${LUNA_TEST_RELEASE_A_PAUSE:-0}" == 1 ]]; then
	: >"${LUNA_TEST_RELEASE_A_LOCK_RELEASED:?}"
fi
exit "$status"
EOF
chmod 0700 "$release_bin/rmdir"
cat >"$new_owner_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
status=0
"${LUNA_TEST_REAL_NEW_OWNER_MKDIR:?}" "$@" || status=$?
if [[ "$status" -ne 0 && "$target" == */.claim-lock-* && ! -e "${LUNA_TEST_NEW_OWNER_LOCK_MARKER:?}" ]]; then
	: >"${LUNA_TEST_NEW_OWNER_LOCK_MARKER:?}"
	while [[ ! -e "${LUNA_TEST_RELEASE_A_LOCK_RELEASED:?}" ]]; do
		sleep 0.01
	done
fi
exit "$status"
EOF
chmod 0700 "$new_owner_bin/mkdir"

LUNA_TEST_RELEASE_PAUSE=1 \
LUNA_TEST_CLAIM_KEY="$claim_key" \
	LUNA_TEST_RELEASE_MARKER="$release_marker" \
	LUNA_TEST_RELEASE_GATE="$release_gate" \
	LUNA_TEST_REAL_RM="$release_real_rm" \
	LUNA_TEST_REAL_MKDIR="$release_real_mkdir" \
	LUNA_TEST_REAL_RMDIR="$release_real_rmdir" \
	PATH="$release_bin:$PATH" \
bash "$CLAIM_SCRIPT" release --repo "$REPO_ROOT" --scope "$SCOPE" --token "$winner" >"$TEST_ROOT/release-b.out" 2>"$TEST_ROOT/release-b.err" &
release_pid_b=$!
release_wait_attempt=0
while [[ ! -e "$release_marker" && "$release_wait_attempt" -lt 1000 ]]; do
	sleep 0.01
	release_wait_attempt=$((release_wait_attempt + 1))
done
[[ -e "$release_marker" ]] || {
	printf 'delayed release did not reach validated-unlink barrier\n' >&2
	exit 1
}

LUNA_TEST_RELEASE_A_PAUSE=1 \
LUNA_TEST_RELEASE_A_LOCK_MARKER="$release_a_lock_marker" \
LUNA_TEST_RELEASE_A_LOCK_GATE="$release_a_lock_gate" \
LUNA_TEST_RELEASE_A_LOCK_RELEASED="$release_a_lock_released" \
LUNA_TEST_REAL_RM="$release_real_rm" \
LUNA_TEST_REAL_MKDIR="$release_real_mkdir" \
LUNA_TEST_REAL_RMDIR="$release_real_rmdir" \
PATH="$release_bin:$PATH" \
bash "$CLAIM_SCRIPT" release --repo "$REPO_ROOT" --scope "$SCOPE" --token "$winner" >"$TEST_ROOT/release-a.out" 2>"$TEST_ROOT/release-a.err" &
release_pid_a=$!
: >"$release_gate"
race_wait_attempt=0
while [[ ! -e "$release_a_lock_marker" && "$race_wait_attempt" -lt 1000 ]]; do
	sleep 0.01
	race_wait_attempt=$((race_wait_attempt + 1))
done
[[ -e "$release_a_lock_marker" ]] || {
	printf 'same-owner release did not reach controlled lock barrier\n' >&2
	exit 1
}

LUNA_TEST_REAL_NEW_OWNER_MKDIR="$(command -p -v mkdir)" \
	LUNA_TEST_NEW_OWNER_LOCK_MARKER="$new_owner_lock_marker" \
	LUNA_TEST_RELEASE_A_LOCK_RELEASED="$release_a_lock_released" \
	PATH="$new_owner_bin:$PATH" \
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$SCOPE" --token token-after-racing-release >"$TEST_ROOT/new-owner.out" 2>"$TEST_ROOT/new-owner.err" &
new_owner_pid=$!
race_wait_attempt=0
while [[ ! -e "$new_owner_lock_marker" && "$race_wait_attempt" -lt 1000 ]]; do
	sleep 0.01
	race_wait_attempt=$((race_wait_attempt + 1))
done
[[ -e "$new_owner_lock_marker" ]] || {
	printf 'new owner did not reach controlled lock-wait barrier\n' >&2
	exit 1
}

: >"$release_a_lock_gate"
release_status_a=0
release_status_b=0
new_owner_status=0
wait "$release_pid_b" || release_status_b=$?
wait "$release_pid_a" || release_status_a=$?
wait "$new_owner_pid" || new_owner_status=$?
release_pid_a=''
release_pid_b=''
new_owner_pid=''
[[ "$new_owner_status" -eq 0 ]] || {
	printf 'new owner could not acquire after serialized same-owner releases: status=%s\n' "$new_owner_status" >&2
	for diagnostic_file in "$TEST_ROOT/release-a.err" "$TEST_ROOT/release-b.err" "$TEST_ROOT/new-owner.err"; do
		printf '%s:\n' "$(basename "$diagnostic_file")" >&2
		if [[ -e "$diagnostic_file" ]]; then
			sed -n '1,80p' "$diagnostic_file" >&2 || true
		else
			printf '(missing)\n' >&2
		fi
	done
	if [[ -e "$claim_path" ]]; then
		printf 'claim path after failed new-owner acquisition: %s\n' "$claim_path" >&2
		sed -n '1,20p' "$claim_path" >&2 || true
	fi
	exit 1
}
[[ "$release_status_b" -eq 0 && "$release_status_a" -eq 6 ]] || {
	printf 'serialized same-owner release statuses were unexpected: release-b=%s release-a=%s\n' "$release_status_b" "$release_status_a" >&2
	for diagnostic_file in "$TEST_ROOT/release-a.err" "$TEST_ROOT/release-b.err"; do
		printf '%s:\n' "$(basename "$diagnostic_file")" >&2
		sed -n '1,80p' "$diagnostic_file" >&2 || true
	done
	exit 1
}
rg -q '^token=token-after-racing-release$' "$claim_path" || {
	printf 'delayed same-owner release removed a newly acquired claim (release statuses %s/%s)\n' "$release_status_a" "$release_status_b" >&2
	exit 1
}
bash "$CLAIM_SCRIPT" release --repo "$REPO_ROOT" --scope "$SCOPE" --token token-after-racing-release >/dev/null

set +e
bash "$CLAIM_SCRIPT" acquire --reenter --repo "$REPO_ROOT" --scope "$SCOPE" --token token-before-initial >/dev/null 2>"$TEST_ROOT/reentry-without-claim.err"
reentry_without_claim_status=$?
set -e
[[ "$reentry_without_claim_status" -eq 6 ]] || {
	printf 'expected --reenter without an existing claim to conflict; status was %s\n' "$reentry_without_claim_status" >&2
	exit 1
}

bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$SCOPE" --token token-after-release >/dev/null
bash "$CLAIM_SCRIPT" release --repo "$REPO_ROOT" --scope "$SCOPE" --token token-after-release >/dev/null

[[ -d "$claim_root" && ! -L "$claim_root" ]] || {
	echo 'cross-path claim root was not created under Git common metadata' >&2
	exit 1
}
[[ -z "$(find "$claim_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
	echo 'cross-path claim cleanup left a live claim' >&2
	exit 1
}
[[ ! -e "$REPO_ROOT/.agents/agent-registry" ]] || {
	echo 'cross-path claim test touched the fallback registry' >&2
	exit 1
}

seal_race_repo="$TEST_ROOT/shared-seal-race-repository"
seal_race_scope_a='shared seal cleanup scope A'
seal_race_scope_b='shared seal cleanup scope B'
seal_race_bin="$TEST_ROOT/shared-seal-race-bin"
seal_race_attempt_marker="$TEST_ROOT/shared-seal-race-claim-attempt"
seal_race_gate="$TEST_ROOT/shared-seal-race-claim-gate"
mkdir -m 0700 "$seal_race_repo"
git init -q "$seal_race_repo"
mkdir -m 0700 "$seal_race_bin"
seal_race_real_ln="$(command -p -v ln)"
cat >"$seal_race_bin/ln" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
if [[ "$target" == */.luna-cross-path-claims/* ]]; then
	: >"${LUNA_TEST_SEAL_RACE_ATTEMPT:?}"
	while [[ ! -e "${LUNA_TEST_SEAL_RACE_GATE:?}" ]]; do
		sleep 0.01
	done
	exit 1
fi
exec "${LUNA_TEST_SEAL_RACE_REAL_LN:?}" "$@"
EOF
chmod 0700 "$seal_race_bin/ln"

LUNA_TEST_SEAL_RACE_ATTEMPT="$seal_race_attempt_marker" \
LUNA_TEST_SEAL_RACE_GATE="$seal_race_gate" \
LUNA_TEST_SEAL_RACE_REAL_LN="$seal_race_real_ln" \
PATH="$seal_race_bin:$PATH" \
bash "$CLAIM_SCRIPT" acquire --repo "$seal_race_repo" --scope "$seal_race_scope_a" --token seal-race-a >"$TEST_ROOT/shared-seal-race-a.out" 2>"$TEST_ROOT/shared-seal-race-a.err" &
seal_race_pid_a=$!
seal_race_wait_attempt=0
while [[ ! -e "$seal_race_attempt_marker" && "$seal_race_wait_attempt" -lt 1000 ]]; do
	sleep 0.01
	seal_race_wait_attempt=$((seal_race_wait_attempt + 1))
done
[[ -e "$seal_race_attempt_marker" ]] || {
	printf 'shared-seal race did not reach the failed claim publication barrier\n' >&2
	exit 1
}
seal_race_seal="$seal_race_repo/.git/.luna-checkout-identity"
[[ -f "$seal_race_seal" && ! -L "$seal_race_seal" ]] || {
	printf 'shared-seal race did not create checkout identity seal before claim failure\n' >&2
	exit 1
}
seal_race_value="$(cat "$seal_race_seal")"

bash "$CLAIM_SCRIPT" acquire --repo "$seal_race_repo" --scope "$seal_race_scope_b" --token seal-race-b >"$TEST_ROOT/shared-seal-race-b.out" 2>"$TEST_ROOT/shared-seal-race-b.err" &
seal_race_pid_b=$!
seal_race_status_b=0
wait "$seal_race_pid_b" || seal_race_status_b=$?
seal_race_pid_b=''
[[ "$seal_race_status_b" -eq 0 ]] || {
	printf 'second scope could not publish against the shared checkout seal: status=%s\n' "$seal_race_status_b" >&2
	sed -n '1,80p' "$TEST_ROOT/shared-seal-race-b.err" >&2 || true
	exit 1
}
: >"$seal_race_gate"
seal_race_status_a=0
wait "$seal_race_pid_a" || seal_race_status_a=$?
seal_race_pid_a=''
[[ "$seal_race_status_a" -eq 6 ]] || {
	printf 'failed shared-seal claim attempt returned unexpected status: %s\n' "$seal_race_status_a" >&2
	sed -n '1,80p' "$TEST_ROOT/shared-seal-race-a.err" >&2 || true
	exit 1
}
[[ "$(cat "$seal_race_seal")" == "$seal_race_value" ]] || {
	printf 'failed cleanup changed the shared checkout seal used by the second scope\n' >&2
	exit 1
}
seal_race_claim_root="$seal_race_repo/.git/.luna-cross-path-claims"
seal_race_claim_b=''
for seal_race_candidate in "$seal_race_claim_root"/*; do
	[[ -f "$seal_race_candidate" && ! -L "$seal_race_candidate" ]] || continue
	seal_race_claim_b="$seal_race_candidate"
done
[[ -n "$seal_race_claim_b" ]] || {
	printf 'second scope claim did not survive failed first-scope cleanup\n' >&2
	exit 1
}
rg -q '^token=seal-race-b$' "$seal_race_claim_b" || {
	printf 'second scope claim owner changed after failed first-scope cleanup\n' >&2
	exit 1
}
bash "$CLAIM_SCRIPT" release --repo "$seal_race_repo" --scope "$seal_race_scope_b" --token seal-race-b >/dev/null

fallback_repo="$TEST_ROOT/fallback-preflight-repository"
fallback_scope='fallback preflight under claim lock'
mkdir -m 0700 "$fallback_repo"
git init -q "$fallback_repo"
fallback_script_dir="$TEST_ROOT/fallback-preflight-scripts"
mkdir -m 0700 "$fallback_script_dir"
cp "$CLAIM_SCRIPT" "$fallback_script_dir/cross-path-claim.sh"
cat >"$fallback_script_dir/registry.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
shift
repo=''
ready_file=''
release_file=''
ready_token=''
release_token=''
while [[ "$#" -gt 0 ]]; do
	case "$1" in
	--repo) repo="$2"; shift 2 ;;
	--ready-file) ready_file="$2"; shift 2 ;;
	--release-file) release_file="$2"; shift 2 ;;
	--ready-token) ready_token="$2"; shift 2 ;;
	--release-token) release_token="$2"; shift 2 ;;
	--error-file) shift 2 ;;
	--parent-pid | --parent-instance) shift 2 ;;
	*) exit 2 ;;
	esac
done
[[ -n "$repo" ]] || exit 2
preflight_status="${LUNA_TEST_PREFLIGHT_STATUS:-0}"
if [[ "$preflight_status" -ne 0 ]]; then
	printf 'fake registry preflight: %s\n' "${LUNA_TEST_PREFLIGHT_MESSAGE:-preflight failed}" >&2
	exit "$preflight_status"
fi
seal_path="$repo/.git/.luna-checkout-identity"
[[ ! -e "$seal_path" && ! -L "$seal_path" ]] || {
	: >"${LUNA_TEST_PREFLIGHT_FAILURE_MARKER:?}"
	exit 90
}
: >"${LUNA_TEST_PREFLIGHT_MARKER:?}"
while [[ ! -e "${LUNA_TEST_PREFLIGHT_GATE:?}" ]]; do
	sleep 0.01
done
if [[ "$mode" == preflight-lock ]]; then
	[[ -n "$ready_file" && -n "$release_file" && -n "$ready_token" && -n "$release_token" ]] || exit 2
	printf 'ready=unlocked:%s\n' "$ready_token" >"$ready_file"
	while [[ "$(command cat "$release_file")" != "release:$release_token" ]]; do
		sleep 0.01
	done
elif [[ "$mode" != preflight ]]; then
	exit 2
fi
EOF
chmod 0700 "$fallback_script_dir/registry.sh"
fallback_preflight_marker="$TEST_ROOT/fallback-preflight-started"
fallback_preflight_gate="$TEST_ROOT/fallback-preflight-gate"
fallback_preflight_failure_marker="$TEST_ROOT/fallback-preflight-created-seal"
fallback_claim_root="$fallback_repo/.git/.luna-cross-path-claims"

LUNA_TEST_PREFLIGHT_MARKER="$fallback_preflight_marker" \
LUNA_TEST_PREFLIGHT_GATE="$fallback_preflight_gate" \
LUNA_TEST_PREFLIGHT_FAILURE_MARKER="$fallback_preflight_failure_marker" \
bash "$fallback_script_dir/cross-path-claim.sh" acquire --fallback-preflight --repo "$fallback_repo" --scope "$fallback_scope" --token fallback-owner >"$TEST_ROOT/fallback-preflight.out" 2>"$TEST_ROOT/fallback-preflight.err" &
fallback_preflight_pid=$!
fallback_wait_attempt=0
while [[ ! -e "$fallback_preflight_marker" && "$fallback_wait_attempt" -lt 1000 ]]; do
	sleep 0.01
	fallback_wait_attempt=$((fallback_wait_attempt + 1))
done
[[ -e "$fallback_preflight_marker" ]] || {
	printf 'fallback preflight did not reach controlled validation barrier\n' >&2
	exit 1
}
[[ ! -e "$fallback_repo/.git/.luna-checkout-identity" && ! -L "$fallback_repo/.git/.luna-checkout-identity" ]] || {
	printf 'fallback preflight created checkout seal before validation completed\n' >&2
	exit 1
}
fallback_lock_path="$(find "$fallback_claim_root" -mindepth 1 -maxdepth 1 -type d -name '.claim-lock-*' -print -quit)"
[[ -d "$fallback_lock_path" && ! -L "$fallback_lock_path" ]] || {
	printf 'fallback preflight did not hold per-claim lock during validation\n' >&2
	exit 1
}
fallback_preflight_claim=''
for fallback_candidate in "$fallback_claim_root"/*; do
	[[ -f "$fallback_candidate" && ! -L "$fallback_candidate" ]] || continue
	case "$(basename "$fallback_candidate")" in
	.registry-preflight-* | .claim.*) continue ;;
	esac
	fallback_preflight_claim="$fallback_candidate"
	break
done
[[ -z "$fallback_preflight_claim" ]] || {
	printf 'fallback preflight published claim before validation completed\n' >&2
	exit 1
}

fallback_competing_bin="$TEST_ROOT/fallback-competing-bin"
fallback_competing_marker="$TEST_ROOT/fallback-competing-lock-attempt"
fallback_competing_gate="$TEST_ROOT/fallback-competing-gate"
mkdir -m 0700 "$fallback_competing_bin"
fallback_real_mkdir="$(command -p -v mkdir)"
cat >"$fallback_competing_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
status=0
"${LUNA_TEST_REAL_MKDIR:?}" "$@" || status=$?
if [[ "$target" == */.claim-lock-* && "$status" -ne 0 && ! -e "${LUNA_TEST_COMPETING_MARKER:?}" ]]; then
	: >"${LUNA_TEST_COMPETING_MARKER:?}"
	while [[ ! -e "${LUNA_TEST_COMPETING_GATE:?}" ]]; do
		sleep 0.01
	done
fi
exit "$status"
EOF
chmod 0700 "$fallback_competing_bin/mkdir"
LUNA_TEST_REAL_MKDIR="$fallback_real_mkdir" \
LUNA_TEST_COMPETING_MARKER="$fallback_competing_marker" \
LUNA_TEST_COMPETING_GATE="$fallback_competing_gate" \
PATH="$fallback_competing_bin:$PATH" \
bash "$fallback_script_dir/cross-path-claim.sh" acquire --repo "$fallback_repo" --scope "$fallback_scope" --token fallback-competing >"$TEST_ROOT/fallback-competing.out" 2>"$TEST_ROOT/fallback-competing.err" &
fallback_competing_pid=$!
fallback_wait_attempt=0
while [[ ! -e "$fallback_competing_marker" && "$fallback_wait_attempt" -lt 1000 ]]; do
	sleep 0.01
	fallback_wait_attempt=$((fallback_wait_attempt + 1))
done
[[ -e "$fallback_competing_marker" ]] || {
	printf 'competing acquisition did not reach claim-lock barrier\n' >&2
	exit 1
}
[[ ! -e "$fallback_repo/.git/.luna-checkout-identity" && ! -L "$fallback_repo/.git/.luna-checkout-identity" ]] || {
	printf 'competing acquisition observed seal before fallback validation completed\n' >&2
	exit 1
}
: >"$fallback_preflight_gate"
fallback_preflight_status=0
wait "$fallback_preflight_pid" || fallback_preflight_status=$?
fallback_preflight_pid=''
[[ "$fallback_preflight_status" -eq 0 ]] || {
	printf 'fallback preflight claim failed after controlled validation: %s\n' "$fallback_preflight_status" >&2
	exit 1
}
[[ -f "$fallback_repo/.git/.luna-checkout-identity" && ! -L "$fallback_repo/.git/.luna-checkout-identity" ]] || {
	printf 'fallback preflight did not create checkout seal after validation\n' >&2
	exit 1
}
fallback_claim_path="$(find "$fallback_claim_root" -mindepth 1 -maxdepth 1 -type f -print -quit)"
[[ -f "$fallback_claim_path" && ! -L "$fallback_claim_path" ]] || {
	printf 'fallback preflight did not publish claim after validation\n' >&2
	exit 1
}
[[ -z "$(find "$fallback_claim_root" -mindepth 1 -maxdepth 1 -name '.registry-preflight-*' -print -quit)" ]] || {
	printf 'fallback preflight leaked helper artifacts after success\n' >&2
	exit 1
}
[[ -z "$(find "$fallback_claim_root" -mindepth 1 -maxdepth 1 -type d -name '.claim-lock-*' -print -quit)" ]] || {
	printf 'fallback preflight leaked claim lock after success\n' >&2
	exit 1
}
: >"$fallback_competing_gate"
fallback_competing_status=0
wait "$fallback_competing_pid" || fallback_competing_status=$?
fallback_competing_pid=''
[[ "$fallback_competing_status" -eq 6 ]] || {
	printf 'competing acquisition bypassed serialized fallback preflight: status=%s\n' "$fallback_competing_status" >&2
	exit 1
}
bash "$fallback_script_dir/cross-path-claim.sh" release --repo "$fallback_repo" --scope "$fallback_scope" --token fallback-owner >/dev/null

assert_fallback_preflight_failure() {
	local case_name="$1"
	local expected_preflight_status="$2"
	local expected_message="$3"
	local case_repo="$TEST_ROOT/fallback-preflight-$case_name"
	local case_output="$TEST_ROOT/fallback-preflight-$case_name.out"
	local case_error="$TEST_ROOT/fallback-preflight-$case_name.err"
	local case_claim_root="$case_repo/.git/.luna-cross-path-claims"
	local case_status=0

	mkdir -m 0700 "$case_repo"
	git init -q "$case_repo"
	if LUNA_TEST_PREFLIGHT_STATUS="$expected_preflight_status" \
		LUNA_TEST_PREFLIGHT_MESSAGE="$expected_message" \
		bash "$fallback_script_dir/cross-path-claim.sh" acquire --fallback-preflight --repo "$case_repo" --scope "$fallback_scope/$case_name" --token "fallback-$case_name" >"$case_output" 2>"$case_error"; then
		case_status=0
	else
		case_status=$?
	fi

	[[ "$case_status" -eq 11 ]] || {
		printf '%s fallback preflight returned %s instead of runtime-state status 11\n' "$case_name" "$case_status" >&2
		sed -n '1,80p' "$case_error" >&2 || true
		exit 1
	}
	rg -Fq -- "fake registry preflight: $expected_message" "$case_error" || {
		printf '%s fallback preflight lost its actionable diagnostic\n' "$case_name" >&2
		sed -n '1,80p' "$case_error" >&2 || true
		exit 1
	}
	rg -Fq -- "fallback registry preflight failed with status $expected_preflight_status before checkout-seal creation and claim publication" "$case_error" || {
		printf '%s fallback preflight did not report the validated status\n' "$case_name" >&2
		sed -n '1,80p' "$case_error" >&2 || true
		exit 1
	}
	[[ -d "$case_claim_root" && ! -L "$case_claim_root" ]] || {
		printf '%s fallback preflight did not create its private coordination root\n' "$case_name" >&2
		exit 1
	}
	[[ -z "$(find "$case_claim_root" -mindepth 1 -maxdepth 1 -type d -name '.claim-lock-*' -print -quit)" ]] || {
		printf '%s fallback preflight leaked its private coordination lock\n' "$case_name" >&2
		exit 1
	}
	[[ -z "$(find "$case_claim_root" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]] || {
		printf '%s fallback preflight published a claim after failure\n' "$case_name" >&2
		exit 1
	}
	[[ ! -e "$case_repo/.git/.luna-checkout-identity" && ! -L "$case_repo/.git/.luna-checkout-identity" ]] || {
		printf '%s fallback preflight created a checkout seal after failure\n' "$case_name" >&2
		exit 1
	}
}

assert_fallback_preflight_failure unsafe 10 'unsafe fallback boundary'
assert_fallback_preflight_failure malformed 5 'malformed fallback registry'
assert_fallback_preflight_failure ineligible 4 'fallback registry belongs to another checkout'

identity_exit_repo="$TEST_ROOT/fallback-preflight-identity-exit"
identity_exit_bin="$TEST_ROOT/fallback-preflight-identity-exit-bin"
identity_exit_ps_count="$TEST_ROOT/fallback-preflight-identity-exit-ps-count"
identity_exit_output="$TEST_ROOT/fallback-preflight-identity-exit.out"
identity_exit_error="$TEST_ROOT/fallback-preflight-identity-exit.err"
identity_exit_claim_root="$identity_exit_repo/.git/.luna-cross-path-claims"
mkdir -m 0700 "$identity_exit_repo" "$identity_exit_bin"
git init -q "$identity_exit_repo"
cat >"$identity_exit_bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
format=''
while [[ "$#" -gt 0 ]]; do
	case "$1" in
	-p)
		shift 2
		;;
	-o)
		format="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
count=0
if [[ -f "${LUNA_TEST_PS_COUNT:?}" ]]; then
	count="$(command cat "$LUNA_TEST_PS_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$LUNA_TEST_PS_COUNT"
case "$format" in
lstart=)
	[[ "$count" -eq 1 ]] || exit 1
	printf '%s\n' 'Wed Aug 19 00:00:00 2026'
	;;
stat=)
	printf '%s\n' 'Z'
	;;
*)
	exit 1
	;;
esac
EOF
chmod 0700 "$identity_exit_bin/ps"
identity_exit_status=0
if LUNA_TEST_PS_COUNT="$identity_exit_ps_count" \
	LUNA_TEST_PREFLIGHT_STATUS=10 \
	LUNA_TEST_PREFLIGHT_MESSAGE='identity probe preflight diagnostic' \
	PATH="$identity_exit_bin:$PATH" \
	bash "$fallback_script_dir/cross-path-claim.sh" acquire \
		--fallback-preflight \
		--repo "$identity_exit_repo" \
		--scope "$fallback_scope/identity-exit" \
		--token fallback-identity-exit >"$identity_exit_output" 2>"$identity_exit_error"; then
	identity_exit_status=0
else
	identity_exit_status=$?
fi
[[ "$identity_exit_status" -eq 11 ]] || {
	printf 'pre-probe helper exit returned %s instead of runtime-state status 11\n' "$identity_exit_status" >&2
	sed -n '1,80p' "$identity_exit_error" >&2 || true
	exit 1
}
rg -Fq -- 'fake registry preflight: identity probe preflight diagnostic' "$identity_exit_error" || {
	printf 'pre-probe helper exit lost its actionable diagnostic\n' >&2
	sed -n '1,80p' "$identity_exit_error" >&2 || true
	exit 1
}
rg -Fq -- 'fallback registry preflight failed with status 10 before checkout-seal creation and claim publication' "$identity_exit_error" || {
	printf 'pre-probe helper exit lost its validated status\n' >&2
	sed -n '1,80p' "$identity_exit_error" >&2 || true
	exit 1
}
[[ -d "$identity_exit_claim_root" && ! -L "$identity_exit_claim_root" ]] || {
	printf 'pre-probe helper exit did not create its private coordination root\n' >&2
	exit 1
}
[[ -z "$(find "$identity_exit_claim_root" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]] || {
	printf 'pre-probe helper exit published a claim after failure\n' >&2
	exit 1
}
[[ ! -e "$identity_exit_repo/.git/.luna-checkout-identity" && ! -L "$identity_exit_repo/.git/.luna-checkout-identity" ]] || {
	printf 'pre-probe helper exit created a checkout seal after failure\n' >&2
	exit 1
}

launch_fixture_repo="$TEST_ROOT/fallback-launch-repository"
launch_fixture_scripts="$TEST_ROOT/fallback-launch-scripts"
launch_fixture_references="$TEST_ROOT/references"
launch_fixture_bin="$TEST_ROOT/fallback-launch-bin"
launch_fixture_codex_home="$TEST_ROOT/fallback-launch-codex-home"
launch_fixture_prompt="$TEST_ROOT/fallback-launch-prompt"
launch_fixture_init_marker="$TEST_ROOT/fallback-launch-registry-init"
launch_fixture_scope='documented fallback launch claim scope'
launch_fixture_task_id='fallback-launch-owner'
launch_fixture_token="task-$launch_fixture_task_id"
launch_fixture_claim_root="$launch_fixture_repo/.git/.luna-cross-path-claims"
launch_fixture_claim_path=''

mkdir -m 0700 "$launch_fixture_repo" "$launch_fixture_scripts" "$launch_fixture_references" "$launch_fixture_bin" "$launch_fixture_codex_home"
git init -q "$launch_fixture_repo"
cp "$CLAIM_SCRIPT" "$launch_fixture_scripts/cross-path-claim.sh"
cp "$SCRIPT_DIR/run-worker.sh" "$launch_fixture_scripts/run-worker.sh"
cp "$SCRIPT_DIR/../references/worker-result.schema.json" "$launch_fixture_references/worker-result.schema.json"
cat >"$launch_fixture_bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0700 "$launch_fixture_bin/codex"
cat >"$launch_fixture_scripts/registry.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
shift
ready_file=''
release_file=''
ready_token=''
release_token=''
while [[ "$#" -gt 0 ]]; do
	case "$1" in
	--ready-file) ready_file="$2"; shift 2 ;;
	--release-file) release_file="$2"; shift 2 ;;
	--ready-token) ready_token="$2"; shift 2 ;;
	--release-token) release_token="$2"; shift 2 ;;
	--error-file | --parent-pid | --parent-instance | --repo) shift 2 ;;
	--print-path) shift ;;
	*) shift ;;
	esac
done
case "$mode" in
preflight-lock)
	[[ -n "$ready_file" && -n "$release_file" && -n "$ready_token" && -n "$release_token" ]] || exit 2
	printf 'ready=unlocked:%s\n' "$ready_token" >"$ready_file"
	while [[ "$(cat "$release_file")" != "release:$release_token" ]]; do
		sleep 0.01
	done
	;;
init)
	: >"${LUNA_TEST_REGISTRY_INIT_MARKER:?}"
	exit 42
	;;
*) exit 0 ;;
esac
EOF
chmod 0700 "$launch_fixture_scripts/registry.sh"
printf '%s\n' 'documented fallback launch regression prompt' >"$launch_fixture_prompt"
chmod 0600 "$launch_fixture_prompt"

PATH="$launch_fixture_bin:$PATH" \
bash "$launch_fixture_scripts/cross-path-claim.sh" acquire \
	--fallback-preflight \
	--repo "$launch_fixture_repo" \
	--scope "$launch_fixture_scope" \
	--token "$launch_fixture_token" >/dev/null

launch_fixture_status=0
if CODEX_BIN=codex \
	CODEX_HOME="$launch_fixture_codex_home" \
	LUNA_TEST_REGISTRY_INIT_MARKER="$launch_fixture_init_marker" \
	PATH="$launch_fixture_bin:$PATH" \
	bash "$launch_fixture_scripts/run-worker.sh" launch \
		--repo "$launch_fixture_repo" \
		--task-id "$launch_fixture_task_id" \
		--scope "$launch_fixture_scope" \
		--sandbox read-only \
		--prompt-file "$launch_fixture_prompt" \
		>"$TEST_ROOT/fallback-launch-owner.out" 2>"$TEST_ROOT/fallback-launch-owner.err"; then
	launch_fixture_status=0
else
	launch_fixture_status=$?
fi
[[ "$launch_fixture_status" -eq 42 && -f "$launch_fixture_init_marker" ]] || {
	printf 'same-owner fallback launch did not re-enter its parent-held claim before registry startup: status=%s\n' "$launch_fixture_status" >&2
	sed -n '1,80p' "$TEST_ROOT/fallback-launch-owner.err" >&2 || true
	exit 1
}
launch_fixture_claim_path="$(find "$launch_fixture_claim_root" -mindepth 1 -maxdepth 1 -type f -print -quit)"
[[ -f "$launch_fixture_claim_path" && ! -L "$launch_fixture_claim_path" ]] || {
	printf 'same-owner fallback launch did not preserve parent-held claim\n' >&2
	exit 1
}
rg -Fq -- "token=$launch_fixture_token" "$launch_fixture_claim_path" || {
	printf 'same-owner fallback launch changed parent-held claim owner\n' >&2
	exit 1
}

rm -f "$launch_fixture_init_marker"
launch_fixture_competing_status=0
if CODEX_BIN=codex \
	CODEX_HOME="$launch_fixture_codex_home" \
	LUNA_TEST_REGISTRY_INIT_MARKER="$launch_fixture_init_marker" \
	PATH="$launch_fixture_bin:$PATH" \
	bash "$launch_fixture_scripts/run-worker.sh" launch \
		--repo "$launch_fixture_repo" \
		--task-id fallback-launch-competing \
		--scope "$launch_fixture_scope" \
		--sandbox read-only \
		--prompt-file "$launch_fixture_prompt" \
		>"$TEST_ROOT/fallback-launch-competing.out" 2>"$TEST_ROOT/fallback-launch-competing.err"; then
	launch_fixture_competing_status=0
else
	launch_fixture_competing_status=$?
fi
[[ "$launch_fixture_competing_status" -eq 6 && ! -e "$launch_fixture_init_marker" ]] || {
	printf 'competing fallback launch bypassed parent-held claim: status=%s\n' "$launch_fixture_competing_status" >&2
	sed -n '1,80p' "$TEST_ROOT/fallback-launch-competing.err" >&2 || true
	exit 1
}
rg -Fq -- "token=$launch_fixture_token" "$launch_fixture_claim_path" || {
	printf 'competing fallback launch changed existing claim owner\n' >&2
	exit 1
}
bash "$launch_fixture_scripts/cross-path-claim.sh" release \
	--repo "$launch_fixture_repo" \
	--scope "$launch_fixture_scope" \
	--token "$launch_fixture_token" >/dev/null
[[ -z "$(find "$launch_fixture_claim_root" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]] || {
	printf 'fallback launch regression fixture left a live claim\n' >&2
	exit 1
}

printf 'PASS: atomic cross-path claim serialization\n'
