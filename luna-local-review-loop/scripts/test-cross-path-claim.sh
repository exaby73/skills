#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CLAIM_SCRIPT="$SCRIPT_DIR/cross-path-claim.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/luna-cross-path-claim.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

REPO_ROOT="$TEST_ROOT/repository"
mkdir -m 0700 "$REPO_ROOT"
git init -q "$REPO_ROOT"
SCOPE='same canonical checkout and immutable scope'

set +e
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$SCOPE" --token token-a >"$TEST_ROOT/a.out" 2>"$TEST_ROOT/a.err" &
pid_a=$!
bash "$CLAIM_SCRIPT" acquire --repo "$REPO_ROOT" --scope "$SCOPE" --token token-b >"$TEST_ROOT/b.out" 2>"$TEST_ROOT/b.err" &
pid_b=$!
status_a=0
status_b=0
wait "$pid_a" || status_a=$?
wait "$pid_b" || status_b=$?
set -e

if [[ "$status_a" -eq 0 && "$status_b" -eq 6 ]]; then
	winner=token-a
	elif [[ "$status_b" -eq 0 && "$status_a" -eq 6 ]]; then
	winner=token-b
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
bash "$CLAIM_SCRIPT" release --repo "$REPO_ROOT" --scope "$SCOPE" --token "$winner" >/dev/null

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

printf 'PASS: atomic cross-path claim serialization\n'
