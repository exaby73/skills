#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_RUNTIME_STATE=11

REPO_INPUT='.'
PROMPT_FILE=''
PROMPT_SNAPSHOT_DIR=''
PROMPT_SNAPSHOT_FILE=''
CODEX_BIN="${CODEX_BIN:-codex}"

usage() {
	local exit_code="${1:-0}"
	cat <<'EOF'
Usage:
  run-review.sh --prompt-file FILE [--repo PATH]

Run one fresh, read-only Sol-High review from the CLI fallback path. The
prompt must contain the complete review contract, guidance, target revisions,
full current diff, and validation evidence.
EOF
	exit "$exit_code"
}

die() {
	local exit_code="$1"
	shift
	printf 'luna-local-review-loop: ERROR [%s] %s\n' "$exit_code" "$*" >&2
	exit "$exit_code"
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup_prompt_snapshot() {
	local exit_code=$?
	local cleanup_status=0
	trap - EXIT
	if [[ -n "$PROMPT_SNAPSHOT_DIR" ]]; then
		if [[ ! -d "$PROMPT_SNAPSHOT_DIR" || -L "$PROMPT_SNAPSHOT_DIR" ]]; then
			cleanup_status=1
		elif [[ -n "$PROMPT_SNAPSHOT_FILE" ]]; then
			if [[ -L "$PROMPT_SNAPSHOT_FILE" || ! -f "$PROMPT_SNAPSHOT_FILE" ]]; then
				cleanup_status=1
			else
				rm -- "$PROMPT_SNAPSHOT_FILE" || cleanup_status=1
			fi
		fi
		if [[ "$cleanup_status" -eq 0 ]]; then
			rmdir -- "$PROMPT_SNAPSHOT_DIR" || cleanup_status=1
		fi
	fi
	exec 9<&- 2>/dev/null || true
	exec 8<&- 2>/dev/null || true
	if [[ "$cleanup_status" -ne 0 ]]; then
		printf 'luna-local-review-loop: ERROR [%s] cannot safely remove private review prompt snapshot.\n' "$EXIT_RUNTIME_STATE" >&2
		exit "$EXIT_RUNTIME_STATE"
	fi
	exit "$exit_code"
}

verify_regular_single_link_descriptor() {
	local gnu_path="$1"
	local bsd_path="$2"
	local metadata
	local prompt_type
	local prompt_links
	if metadata="$(LC_ALL=C stat -Lc '%F|%h' "$gnu_path" 2>/dev/null)"; then
		:
	elif metadata="$(LC_ALL=C stat -f '%HT|%l' "$bsd_path" 2>/dev/null)"; then
		:
	else
		die "$EXIT_RUNTIME_STATE" 'cannot verify review prompt descriptor.'
	fi
	IFS='|' read -r prompt_type prompt_links <<<"$metadata"
	[[ "$prompt_type" == 'regular file' || "$prompt_type" == 'Regular File' ]] || die "$EXIT_RUNTIME_STATE" 'review prompt descriptor is not a regular file.'
	[[ "$prompt_links" == '1' ]] || die "$EXIT_RUNTIME_STATE" 'review prompt descriptor is multiply linked; refusing to review mutable input.'
}

open_verified_prompt_descriptor() {
	local prompt_parent
	local prompt_name
	if [[ "$PROMPT_FILE" == */* ]]; then
		prompt_parent="${PROMPT_FILE%/*}"
		prompt_name="${PROMPT_FILE##*/}"
	else
		prompt_parent='.'
		prompt_name="$PROMPT_FILE"
	fi
	prompt_parent="$(cd -P "$prompt_parent" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve review prompt parent: $PROMPT_FILE."
	PROMPT_FILE="$prompt_parent/$prompt_name"
	[[ -f "$PROMPT_FILE" && ! -L "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || die "$EXIT_USAGE" "review prompt is not a readable regular file: $PROMPT_FILE."
	exec 8<"$PROMPT_FILE" || die "$EXIT_RUNTIME_STATE" "cannot open review prompt descriptor: $PROMPT_FILE."
	verify_regular_single_link_descriptor /proc/$$/fd/8 /dev/fd/8

	PROMPT_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-review.XXXXXX")" || die "$EXIT_RUNTIME_STATE" 'cannot create private review prompt snapshot directory.'
	chmod 700 "$PROMPT_SNAPSHOT_DIR" || die "$EXIT_RUNTIME_STATE" 'cannot protect review prompt snapshot directory.'
	PROMPT_SNAPSHOT_FILE="$PROMPT_SNAPSHOT_DIR/prompt"
	cat <&8 >"$PROMPT_SNAPSHOT_FILE" || die "$EXIT_RUNTIME_STATE" 'cannot snapshot review prompt.'
	chmod 400 "$PROMPT_SNAPSHOT_FILE" || die "$EXIT_RUNTIME_STATE" 'cannot protect review prompt snapshot.'
	exec 9<"$PROMPT_SNAPSHOT_FILE" || die "$EXIT_RUNTIME_STATE" 'cannot open review prompt snapshot descriptor.'
	verify_regular_single_link_descriptor /proc/$$/fd/9 /dev/fd/9
}

[[ $# -gt 0 ]] || usage "$EXIT_USAGE"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo | -C)
		REPO_INPUT="${2:-}"
		shift 2
		;;
	--prompt-file)
		PROMPT_FILE="${2:-}"
		shift 2
		;;
	--help | -h)
		usage "$EXIT_OK"
		;;
	*)
		die "$EXIT_USAGE" "unknown argument: $1."
		;;
	esac
done

[[ -n "$PROMPT_FILE" ]] || die "$EXIT_USAGE" 'review requires --prompt-file.'
[[ -x "$(command -v "$CODEX_BIN" 2>/dev/null || true)" ]] || die "$EXIT_PREREQUISITE" "Codex CLI is unavailable: $CODEX_BIN."

REPO_ROOT="$(cd -P "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve repository path: $REPO_INPUT."
[[ -d "$REPO_ROOT/.git" || -f "$REPO_ROOT/.git" ]] || die "$EXIT_USAGE" "review repository is not a Git checkout: $REPO_ROOT."
trap cleanup_prompt_snapshot EXIT
open_verified_prompt_descriptor

codex_status=0
"$CODEX_BIN" exec \
	--ignore-user-config \
	--strict-config \
	-m gpt-5.6-sol \
	-c 'model_reasoning_effort=high' \
	-s read-only \
	-C "$REPO_ROOT" \
	--json \
	- <&9 || codex_status=$?
exit "$codex_status"
