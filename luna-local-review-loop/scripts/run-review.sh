#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3

REPO_INPUT='.'
PROMPT_FILE=''
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
[[ -f "$PROMPT_FILE" && ! -L "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || die "$EXIT_USAGE" "review prompt is not a readable regular file: $PROMPT_FILE."
[[ -x "$(command -v "$CODEX_BIN" 2>/dev/null || true)" ]] || die "$EXIT_PREREQUISITE" "Codex CLI is unavailable: $CODEX_BIN."

REPO_ROOT="$(cd -P "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve repository path: $REPO_INPUT."
[[ -d "$REPO_ROOT/.git" || -f "$REPO_ROOT/.git" ]] || die "$EXIT_USAGE" "review repository is not a Git checkout: $REPO_ROOT."

exec "$CODEX_BIN" exec \
	--ignore-user-config \
	--strict-config \
	-m gpt-5.6-sol \
	-c 'model_reasoning_effort=high' \
	-s read-only \
	-C "$REPO_ROOT" \
	--json \
	- <"$PROMPT_FILE"
