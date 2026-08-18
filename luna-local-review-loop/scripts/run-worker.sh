#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly EXIT_OK=0
readonly EXIT_USAGE=2
readonly EXIT_PREREQUISITE=3
readonly EXIT_CONFLICT=6
readonly EXIT_RUNTIME_STATE=11
readonly EXIT_WORKER=12

# Start promptly for launch readiness, then back off after stable observations.
# The lease and independent token enumeration keep cleanup safe without a
# sustained 10 ms process-table loop.
readonly TRACKER_MIN_INTERVAL='0.05'
readonly TRACKER_STABLE_INTERVAL='0.10'
readonly TRACKER_MAX_INTERVAL='0.25'

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR='.'
[[ -n "$SCRIPT_DIR" ]] || SCRIPT_DIR='/'
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd -P)"
readonly SCRIPT_DIR
readonly REGISTRY_SCRIPT="$SCRIPT_DIR/registry.sh"
readonly CLAIM_SCRIPT="$SCRIPT_DIR/cross-path-claim.sh"
readonly RESULT_SCHEMA="$SCRIPT_DIR/../references/worker-result.schema.json"

MODE='launch'
REPO_INPUT='.'
REPO_ROOT=''
TASK_ID=''
SCOPE=''
RETRY_OF=''
PROMPT_FILE=''
TASK_SANDBOX=''
MODEL='gpt-5.6-luna'
REASONING_EFFORT='max'
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_VERSION_VALIDATED=0
SHA256_COMMAND=''
FINISHED=0
SESSION_ID=''
INVOCATION_TOKEN=''
INVOCATION_CLAIMED=0
CROSS_PATH_CLAIMED=0
CROSS_PATH_CLAIM_REENTERED=0
CROSS_PATH_TOKEN=''
ACTIVE_CODEX_PID=''
ACTIVE_CODEX_PGID=''
ACTIVE_CODEX_INSTANCE=''
ACTIVE_HELPER_PID=''
ACTIVE_TRACKER_PID=''
ACTIVE_TRACKER_STATE=''
ACTIVE_LEASE_PID=''
ACTIVE_LEASE_INSTANCE=''
PRESERVE_REGISTRY_STATE=0
TERMINAL_RETIREMENT_COMPLETE=0
# Bash 3 has no allocated-FD syntax; FD 8 carries the launch snapshot and
# FD 9 remains reserved for each Codex child lease.
readonly PROMPT_DESCRIPTOR_SOURCE='fd8'
# Every fallback prompt carries this boundary so a worker cannot create a nested worker.
readonly WORKER_BOUNDARY_INSTRUCTION='You are the sole worker for this immutable task. Perform the owned scope directly; never spawn, delegate to, or hand work to another subagent.'
PROMPT_DESCRIPTOR_OPEN=0
PROMPT_STAGING_PATH=''
PROMPT_STAGING_IDENTITY=''

usage() {
	local exit_code="${1:-0}"
	cat <<'EOF'
Usage:
  run-worker.sh launch --task-id ID --scope TEXT --prompt-file FILE [--retry-of ID] [--sandbox read-only|workspace-write] [--repo PATH]
  run-worker.sh continue --task-id ID --prompt-file FILE [--repo PATH]
  run-worker.sh finish --task-id ID --status failed|blocked|interrupted --evidence TEXT [--repo PATH]

Launch atomically reserves, creates and binds a resumable Codex session with a
read-only handshake, activates it, and sends the task without a PTY or manual
EOF. Continue resumes the exact registered session. Structured final output is
printed to stdout; streaming logs stay below the project-local registry directory.
`--retry-of` resumes an exact scope from a retired failed, blocked, or
interrupted attempt while preserving its sandbox.
EOF
	exit "$exit_code"
}

die() {
	local exit_code="$1"
	shift
	printf 'luna-local-review-loop: ERROR [%s] %s\n' "$exit_code" "$*" >&2
	exit "$exit_code"
}

runtime_state_is_writable() {
	local codex_home="${CODEX_HOME:-${HOME:-}/.codex}"
	local probe=''
	[[ -n "$codex_home" && -d "$codex_home" && -w "$codex_home" ]] || die "$EXIT_RUNTIME_STATE" "Codex runtime state is not writable: ${codex_home:-unknown}. The parent must allow the owning Codex state directory separately from the worker repository sandbox, then retry."
	probe="$(mktemp "$codex_home/.luna-runtime-probe.XXXXXX" 2>/dev/null)" || die "$EXIT_RUNTIME_STATE" "Codex runtime state denied a real write probe: $codex_home. The parent must allow that exact runtime directory separately from the worker repository sandbox, then retry."
	rm -f "$probe" || die "$EXIT_RUNTIME_STATE" "Codex runtime write probe could not be removed: $probe. Inspect it before retrying."
}

resolve_codex_home() {
	local codex_home="${CODEX_HOME:-${HOME:-}/.codex}"
	[[ -n "$codex_home" ]] || die "$EXIT_RUNTIME_STATE" 'Codex runtime state path is empty.'
	case "$codex_home" in
	/*) ;;
	*) codex_home="$PWD/$codex_home" ;;
	esac
	codex_home="$(cd -P "$codex_home" 2>/dev/null && pwd -P)" || die "$EXIT_RUNTIME_STATE" "cannot resolve Codex runtime state path: $codex_home."
	CODEX_HOME="$codex_home"
	export CODEX_HOME
}

require_workspace_write_boundary() {
	local version_output=''
	local version=''
	local major=''
	local minor=''
	local patch=''
	if [[ "$CODEX_VERSION_VALIDATED" -eq 1 ]]; then
		return 0
	fi
	version_output="$( "$CODEX_BIN" --version 2>/dev/null )" || die "$EXIT_PREREQUISITE" "Codex CLI version probe failed; workspace-write reservation refused because the compiled recursive project .agents read-only metadata boundary cannot be proven."
	[[ "$version_output" =~ ^codex-cli[[:space:]][0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$EXIT_PREREQUISITE" "Codex CLI version is not fail-closed parseable as 'codex-cli X.Y.Z': ${version_output:-empty}. Workspace-write reservation refused."
	version="${version_output#codex-cli }"
	IFS='.' read -r major minor patch <<<"$version"
	[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || die "$EXIT_PREREQUISITE" "Codex CLI version is not fail-closed parseable as 'codex-cli X.Y.Z': $version_output. Workspace-write reservation refused."
	if (( 10#$major < 0 || (10#$major == 0 && 10#$minor < 147) || (10#$major == 0 && 10#$minor == 147 && 10#$patch < 0) )); then
		die "$EXIT_PREREQUISITE" "Codex CLI $version is too old for workspace-write registry protection; require >= 0.147.0 with the compiled recursive project .agents read-only metadata boundary. Read-only tasks remain supported."
	fi
	CODEX_VERSION_VALIDATED=1
}

preflight_workspace_write_launch() {
	local effective_sandbox="$TASK_SANDBOX"
	local retry_worker=''
	if [[ -z "$effective_sandbox" ]]; then
		if [[ -n "$RETRY_OF" ]]; then
			retry_worker="$( "$REGISTRY_SCRIPT" query --task-id "$RETRY_OF" --repo "$REPO_INPUT" 2>/dev/null )" || die "$EXIT_RUNTIME_STATE" "cannot inspect retry sandbox before reservation: $RETRY_OF."
			effective_sandbox="$(jq -r '.sandbox // empty' <<<"$retry_worker")"
			case "$effective_sandbox" in
			read-only | workspace-write) ;;
			*) die "$EXIT_RUNTIME_STATE" "retry registry returned invalid sandbox before reservation: $RETRY_OF." ;;
			esac
		else
			effective_sandbox='workspace-write'
		fi
	fi
	[[ "$effective_sandbox" == workspace-write ]] || return 0
	require_workspace_write_boundary
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

validate_common() {
	local codex_discovered=''
	local codex_parent=''
	local codex_name=''
	local command_name=''
	local missing=''
	local prompt_parent=''
	local prompt_name=''
	local repo_candidate=''
	local required_commands=(bash dirname git jq mkdir rm rmdir mv ln kill ps sleep awk stat cat mktemp date chmod sed od tr sort head mkfifo)
	for command_name in "${required_commands[@]}"; do
		if ! command -v "$command_name" >/dev/null 2>&1; then
			missing="${missing}${missing:+, }${command_name}"
		fi
		done
	[[ -z "$missing" ]] || die "$EXIT_PREREQUISITE" "missing runtime prerequisite(s): $missing. Install them through the approved host mechanism, then retry."
	select_sha256_command || die "$EXIT_PREREQUISITE" 'missing SHA-256 prerequisite: install shasum or sha256sum.'
	codex_discovered="$(command -v "$CODEX_BIN" 2>/dev/null)" || die "$EXIT_PREREQUISITE" "Codex CLI not found: $CODEX_BIN."
	case "$codex_discovered" in /*) ;; *) codex_discovered="$PWD/$codex_discovered" ;; esac
	codex_parent="${codex_discovered%/*}"
	codex_name="${codex_discovered##*/}"
	codex_parent="$(cd -P "$codex_parent" 2>/dev/null && pwd -P)" || die "$EXIT_PREREQUISITE" "cannot resolve Codex CLI parent: $codex_discovered."
	CODEX_BIN="$codex_parent/$codex_name"
	[[ -f "$CODEX_BIN" && -x "$CODEX_BIN" ]] || die "$EXIT_PREREQUISITE" "Codex CLI is not an executable file: $CODEX_BIN."
	[[ -f "$RESULT_SCHEMA" ]] || die "$EXIT_PREREQUISITE" "worker result schema not found: $RESULT_SCHEMA."
	[[ -f "$CLAIM_SCRIPT" && ! -L "$CLAIM_SCRIPT" ]] || die "$EXIT_PREREQUISITE" "cross-path claim primitive is unavailable: $CLAIM_SCRIPT."
	[[ -d "$REPO_INPUT" ]] || die "$EXIT_USAGE" "repository path does not exist or is not a directory: $REPO_INPUT."
	repo_candidate="$(cd -P "$REPO_INPUT" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve repository path: $REPO_INPUT."
	REPO_ROOT="$(git -C "$repo_candidate" rev-parse --show-toplevel 2>/dev/null)" || die "$EXIT_USAGE" "repository path is not inside a Git repository: $REPO_INPUT."
	REPO_ROOT="$(cd -P "$REPO_ROOT" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve repository root: $REPO_INPUT."
	case "$repo_candidate" in
	"$REPO_ROOT" | "$REPO_ROOT"/*) ;;
	*) die "$EXIT_USAGE" "Git recorded a different checkout root than the supplied path: $repo_candidate -> $REPO_ROOT." ;;
	esac
	[[ "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ && "$TASK_ID" != . && "$TASK_ID" != .. ]] || die "$EXIT_USAGE" 'task-id must be an artifact-safe name containing only letters, numbers, dot, underscore, or hyphen, and must not be dot or dot-dot.'
	if [[ -n "$RETRY_OF" ]]; then
		[[ "$RETRY_OF" =~ ^[A-Za-z0-9._-]+$ && "$RETRY_OF" != . && "$RETRY_OF" != .. ]] || die "$EXIT_USAGE" 'retry-of must be an artifact-safe task ID.'
	fi
	[[ -f "$PROMPT_FILE" && ! -L "$PROMPT_FILE" ]] || die "$EXIT_USAGE" "prompt-file must be a regular non-symlink file: $PROMPT_FILE."
	case "$PROMPT_FILE" in /*) ;; *) PROMPT_FILE="$PWD/$PROMPT_FILE" ;; esac
	prompt_parent="${PROMPT_FILE%/*}"
	prompt_name="${PROMPT_FILE##*/}"
	prompt_parent="$(cd -P "$prompt_parent" 2>/dev/null && pwd -P)" || die "$EXIT_USAGE" "cannot resolve prompt-file parent: $PROMPT_FILE."
	PROMPT_FILE="$prompt_parent/$prompt_name"
	case "$TASK_SANDBOX" in '' | read-only | workspace-write) ;; *) die "$EXIT_USAGE" 'sandbox must be read-only or workspace-write.' ;; esac
	resolve_codex_home
	runtime_state_is_writable
}

finish_on_error() {
	local exit_code=$?
	local registry_cleanup_status=0
	local claim_release_status=0
	close_prompt_descriptor
	cleanup_prompt_staging
	if [[ "$FINISHED" -eq 0 && "$PRESERVE_REGISTRY_STATE" -eq 0 && "$INVOCATION_CLAIMED" -eq 1 && -n "$TASK_ID" && -n "$INVOCATION_TOKEN" ]]; then
		if ! "$REGISTRY_SCRIPT" complete-and-retire --task-id "$TASK_ID" --status failed --evidence "worker launcher exited $exit_code before a structured terminal result" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT" >/dev/null 2>&1; then
			registry_cleanup_status=1
		else
			TERMINAL_RETIREMENT_COMPLETE=1
			INVOCATION_CLAIMED=0
		fi
	fi
	if [[ "$FINISHED" -eq 0 && "$PRESERVE_REGISTRY_STATE" -eq 0 && "$registry_cleanup_status" -eq 0 && "$CROSS_PATH_CLAIMED" -eq 1 && ( "$CROSS_PATH_CLAIM_REENTERED" -eq 0 || "$INVOCATION_CLAIMED" -eq 1 || "$TERMINAL_RETIREMENT_COMPLETE" -eq 1 ) ]]; then
		release_cross_path_claim || claim_release_status=$?
	fi
	INVOCATION_CLAIMED=0
	[[ "$registry_cleanup_status" -eq 0 && "$claim_release_status" -eq 0 ]] || exit_code="$EXIT_RUNTIME_STATE"
	exit "$exit_code"
}

prepare_invocation() {
	[[ -n "$INVOCATION_TOKEN" ]] || INVOCATION_TOKEN="invocation-$$-${RANDOM:-0}-$(date -u '+%Y%m%dT%H%M%S')"
}

prepare_cross_path_token() {
	[[ -n "$TASK_ID" ]] || die "$EXIT_USAGE" 'cross-path claim requires the immutable task ID.'
	[[ -n "$CROSS_PATH_TOKEN" ]] || CROSS_PATH_TOKEN="task-$TASK_ID"
}

acquire_cross_path_claim() {
	local mode="${1:-initial}"
	[[ -n "$SCOPE" ]] || die "$EXIT_USAGE" 'cross-path claim requires the immutable task scope.'
	prepare_cross_path_token
	CROSS_PATH_CLAIM_REENTERED=0
	local claim_status=0
	local claim_args=(acquire --repo "$REPO_INPUT" --scope "$SCOPE" --token "$CROSS_PATH_TOKEN")
	case "$mode" in
	initial | recover) ;;
	reenter) claim_args+=(--reenter); CROSS_PATH_CLAIM_REENTERED=1 ;;
	*) die "$EXIT_USAGE" "unknown cross-path claim acquisition mode: $mode." ;;
	esac
	bash "$CLAIM_SCRIPT" "${claim_args[@]}" >/dev/null || claim_status=$?
	if [[ "$mode" == recover && "$claim_status" -eq 6 ]]; then
		claim_args+=(--reenter)
		CROSS_PATH_CLAIM_REENTERED=1
		claim_status=0
		bash "$CLAIM_SCRIPT" "${claim_args[@]}" >/dev/null || claim_status=$?
	fi
	case "$claim_status" in
	0) ;;
	6) die "$EXIT_CONFLICT" "cross-path claim is already held for task scope: $SCOPE." ;;
	*) die "$EXIT_RUNTIME_STATE" "cross-path claim is unavailable for task scope: $SCOPE; stopping before worker startup." ;;
	esac
	CROSS_PATH_CLAIMED=1
}

release_cross_path_claim() {
	if [[ "$CROSS_PATH_CLAIMED" -eq 1 ]]; then
		bash "$CLAIM_SCRIPT" release --repo "$REPO_INPUT" --scope "$SCOPE" --token "$CROSS_PATH_TOKEN" >/dev/null || return 1
		CROSS_PATH_CLAIMED=0
	fi
}

claim_invocation() {
	prepare_invocation
	local claim_args=(claim-invocation --task-id "$TASK_ID" --pid "$$" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT")
	[[ "$MODE" != continue ]] || claim_args+=(--require-status active)
	run_registry_quiet "${claim_args[@]}"
	INVOCATION_CLAIMED=1
}

release_invocation() {
	if [[ "$INVOCATION_CLAIMED" -eq 1 ]]; then
		run_registry_quiet release-invocation --task-id "$TASK_ID" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT"
		INVOCATION_CLAIMED=0
	fi
}

stop_active_lease() {
	if [[ -n "$ACTIVE_LEASE_PID" ]]; then
		process_instance_matches "$ACTIVE_LEASE_PID" "$ACTIVE_LEASE_INSTANCE" && kill -TERM "$ACTIVE_LEASE_PID" 2>/dev/null || true
		wait "$ACTIVE_LEASE_PID" 2>/dev/null || true
	fi
	ACTIVE_LEASE_PID=''
	ACTIVE_LEASE_INSTANCE=''
}

stop_active_child_and_exit() {
	local signal_name="$1"
	local exit_code="$2"
	local cleanup_status=0
	if [[ -n "$ACTIVE_HELPER_PID" ]] && kill -0 "$ACTIVE_HELPER_PID" 2>/dev/null; then
		kill -s "$signal_name" "$ACTIVE_HELPER_PID" 2>/dev/null || true
		wait "$ACTIVE_HELPER_PID" 2>/dev/null || true
	fi
	if ! stop_codex_process_group "$signal_name"; then
		cleanup_status=1
	fi
	if [[ "$cleanup_status" -eq 0 ]] && ! stop_tracked_worker_processes "$signal_name"; then
		cleanup_status=1
	fi
	if [[ "$cleanup_status" -ne 0 ]]; then
		PRESERVE_REGISTRY_STATE=1
		exit "$exit_code"
	fi
	stop_active_lease
	ACTIVE_HELPER_PID=''
	ACTIVE_CODEX_PID=''
	ACTIVE_CODEX_PGID=''
	ACTIVE_CODEX_INSTANCE=''
	exit "$exit_code"
}

write_descendant_state() {
	local status="$1"
	local root_pid="$2"
	local known_file="$3"
	local state_path="$4"
	local temp_path
	temp_path="$(mktemp "${state_path}.tmp.XXXXXX")" || return 1
	if ! jq -Rn --arg status "$status" --arg root "$root_pid" '
      [inputs
        | capture("^(?<pid>[1-9][0-9]*)[|](?<instance>.+)$")
        | {pid:(.pid | tonumber), instance:.instance}]
      | {status:$status, root_pid:($root | tonumber), processes:.}
    ' <"$known_file" >"$temp_path"; then
		rm -f "$temp_path"
		return 1
	fi
	mv "$temp_path" "$state_path"
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

process_instance_matches() {
	local pid="$1"
	local expected="$2"
	local current=''
	local process_state=''
	current="$(process_instance_identity "$pid")" || return 1
	[[ "$current" == "$expected" ]] || return 1
	process_state="$(ps -p "$pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"
	case "$process_state" in '' | Z*) return 1 ;; esac
	return 0
}

process_has_invocation_token() {
	local pid="$1"
	local expected="LUNA_WORKER_PROCESS_TOKEN=$INVOCATION_TOKEN"
	[[ -n "$INVOCATION_TOKEN" ]] || return 1
	LC_ALL=C ps eww -p "$pid" -o command= 2>/dev/null \
		| awk -v expected="$expected" '{ for (field = 1; field <= NF; field++) if ($field == expected) found = 1 } END { exit found ? 0 : 1 }'
}

process_instance_allows_signal() {
	local pid="$1"
	local expected="$2"
	process_instance_matches "$pid" "$expected" || return 1
	case "$expected" in
	proc:*) return 0 ;;
	ps:*) process_has_invocation_token "$pid" ;;
	*) return 1 ;;
	esac
}

record_process_instance() {
	local pid="$1"
	local destination="$2"
	local instance=''
	instance="$(process_instance_identity "$pid")" || return 1
	printf '%s|%s\n' "$pid" "$instance" >>"$destination"
}

record_token_bearing_processes() {
	local destination="$1"
	local expected="LUNA_WORKER_PROCESS_TOKEN=$INVOCATION_TOKEN"
	local snapshot
	local pid
	[[ -n "$INVOCATION_TOKEN" ]] || return 1
	snapshot="$(mktemp "${destination}.tokens.XXXXXX")" || return 1
	if ! LC_ALL=C ps axeww -o pid=,stat=,command= 2>/dev/null \
		| awk -v expected="$expected" 'NF >= 3 && $2 !~ /^Z/ { for (field = 3; field <= NF; field++) if ($field == expected) { print $1; next } }' >"$snapshot"; then
		rm -f "$snapshot"
		return 1
	fi
	while IFS= read -r pid; do
		record_process_instance "$pid" "$destination" || true
	done <"$snapshot"
	rm -f "$snapshot"
	sort -t '|' -k1,1n -u -o "$destination" "$destination"
}

monitor_descendant_tree() {
	local root_pid="$1"
	local state_path="$2"
	local lease_pid="$3"
	local lease_instance="$4"
	local known_file
	local snapshot
	local additions
	local live_count
	local root_live
	local lease_live
	local root_instance
	local pid
	local instance
	local recorded_count
	local tracker_status
	local current_signature
	local last_observation_signature=''
	local stable_cycles=0
	local tracker_interval="$TRACKER_MIN_INTERVAL"
	known_file="$(mktemp "${state_path}.known.XXXXXX")" || exit 1
	snapshot="$(mktemp "${state_path}.snapshot.XXXXXX")" || exit 1
	additions="$(mktemp "${state_path}.additions.XXXXXX")" || exit 1
	trap 'rm -f "$known_file" "$snapshot" "$additions"' EXIT
	root_instance="$(process_instance_identity "$root_pid")" || exit 1
	printf '%s|%s\n' "$root_pid" "$root_instance" >"$known_file"
	while true; do
		ps -ax -o pid=,ppid=,stat= 2>/dev/null | awk 'NF >= 3 {print $1 "|" $2 "|" $3}' >"$snapshot" || exit 1
		while true; do
			: >"$additions"
			while IFS='|' read -r pid instance; do
				process_instance_matches "$pid" "$instance" && printf '%s|%s\n' "$pid" "$instance" >>"$additions"
			done <"$known_file"
			mv "$additions" "$known_file"
			additions="$(mktemp "${state_path}.additions.XXXXXX")" || exit 1
			awk -F '|' 'NR == FNR { known[$1] = 1; next } $3 !~ /^Z/ && known[$2] && !known[$1] { print $1 }' "$known_file" "$snapshot" >"$additions"
			[[ -s "$additions" ]] || break
			recorded_count=0
			while IFS= read -r pid; do
				if record_process_instance "$pid" "$known_file"; then
					recorded_count=$((recorded_count + 1))
				fi
			done <"$additions"
			[[ "$recorded_count" -gt 0 ]] || break
			sort -t '|' -k1,1n -u -o "$known_file" "$known_file"
		done
		: >"$additions"
		while IFS='|' read -r pid instance; do
			process_instance_matches "$pid" "$instance" && printf '%s|%s\n' "$pid" "$instance" >>"$additions"
		done <"$known_file"
		mv "$additions" "$known_file"
		additions="$(mktemp "${state_path}.additions.XXXXXX")" || exit 1
		live_count="$(awk 'END { print NR + 0 }' "$known_file")"
		root_live=0
		process_instance_matches "$root_pid" "$root_instance" && root_live=1
		lease_live=0
		process_instance_matches "$lease_pid" "$lease_instance" && lease_live=1
		tracker_status='active'
		if [[ "$root_live" -eq 0 && "$live_count" -eq 0 && "$lease_live" -eq 0 ]]; then
			record_token_bearing_processes "$known_file" || exit 1
			live_count="$(awk 'END { print NR + 0 }' "$known_file")"
			[[ "$live_count" -gt 0 ]] || tracker_status='clean'
		fi
		current_signature="$tracker_status|$root_live|$lease_live|$(<"$known_file")"
		write_descendant_state "$tracker_status" "$root_pid" "$known_file" "$state_path" || exit 1
		[[ "$tracker_status" == 'clean' ]] && exit 0

		if [[ "$current_signature" == "$last_observation_signature" ]]; then
			stable_cycles=$((stable_cycles + 1))
		else
			stable_cycles=0
		fi
		last_observation_signature="$current_signature"
		case "$stable_cycles" in
		0) tracker_interval="$TRACKER_MIN_INTERVAL" ;;
		1) tracker_interval="$TRACKER_STABLE_INTERVAL" ;;
		*) tracker_interval="$TRACKER_MAX_INTERVAL" ;;
		esac
		sleep "$tracker_interval"
	done
}

tracked_worker_processes() {
	local state_path="$1"
	[[ -f "$state_path" && ! -L "$state_path" ]] || return 1
	jq -r '.processes[] | "\(.pid)|\(.instance)"' "$state_path" 2>/dev/null
}

tracked_worker_processes_are_empty() {
	local state_path="$1"
	local pid
	local instance
	while IFS='|' read -r pid instance; do
		process_instance_matches "$pid" "$instance" && return 1
	done < <(tracked_worker_processes "$state_path") || return 1
	return 0
}

tracker_process_is_live() {
	local tracker_pid="$1"
	local process_state=''
	process_state="$(ps -p "$tracker_pid" -o stat= 2>/dev/null | awk 'NF {print $1; exit}')"
	case "$process_state" in '' | Z*) return 1 ;; *) return 0 ;; esac
}

stop_tracked_worker_processes() {
	local signal_name="$1"
	local attempt=0
	local kill_attempt=0
	local unsafe_signal=0
	local pid
	local instance
	[[ -n "$ACTIVE_TRACKER_STATE" ]] || return 0
	while [[ -n "$ACTIVE_TRACKER_PID" ]] && tracker_process_is_live "$ACTIVE_TRACKER_PID" && [[ "$attempt" -lt 100 ]]; do
		unsafe_signal=0
		while IFS='|' read -r pid instance; do
			if process_instance_matches "$pid" "$instance"; then
				if process_instance_allows_signal "$pid" "$instance"; then
					kill -s "$signal_name" "$pid" 2>/dev/null || true
				else
					unsafe_signal=1
				fi
			fi
		done < <(tracked_worker_processes "$ACTIVE_TRACKER_STATE")
		[[ "$unsafe_signal" -eq 0 ]] || return 1
		sleep 0.05
		attempt=$((attempt + 1))
	done
	while [[ -n "$ACTIVE_TRACKER_PID" ]] && tracker_process_is_live "$ACTIVE_TRACKER_PID" && [[ "$kill_attempt" -lt 50 ]]; do
		unsafe_signal=0
		while IFS='|' read -r pid instance; do
			if process_instance_matches "$pid" "$instance"; then
				if process_instance_allows_signal "$pid" "$instance"; then
					kill -KILL "$pid" 2>/dev/null || true
				else
					unsafe_signal=1
				fi
			fi
		done < <(tracked_worker_processes "$ACTIVE_TRACKER_STATE")
		[[ "$unsafe_signal" -eq 0 ]] || return 1
		sleep 0.05
		kill_attempt=$((kill_attempt + 1))
	done
	if [[ -n "$ACTIVE_TRACKER_PID" ]]; then
		tracker_process_is_live "$ACTIVE_TRACKER_PID" && return 1
		wait "$ACTIVE_TRACKER_PID" 2>/dev/null || return 1
	fi
	if [[ -n "$ACTIVE_LEASE_PID" ]]; then
		process_instance_matches "$ACTIVE_LEASE_PID" "$ACTIVE_LEASE_INSTANCE" && return 1
		wait "$ACTIVE_LEASE_PID" 2>/dev/null || return 1
	fi
	tracked_worker_processes_are_empty "$ACTIVE_TRACKER_STATE" || return 1
	jq -e '.status == "clean"' "$ACTIVE_TRACKER_STATE" >/dev/null 2>&1 || return 1
	ACTIVE_TRACKER_PID=''
	ACTIVE_LEASE_PID=''
	ACTIVE_LEASE_INSTANCE=''
}

process_group_is_empty() {
	local pgid="$1"
	local live_count=''
	case "$pgid" in '' | 0 | *[!0-9]*) return 1 ;; esac
	live_count="$(ps -ax -o pgid=,stat= 2>/dev/null | awk -v target="$pgid" '$1 == target && $2 !~ /^Z/ {count++} END {print count + 0}')" || return 1
	[[ "$live_count" -eq 0 ]]
}

wait_for_process_group_exit() {
	local pgid="$1"
	local attempt=0
	while ! process_group_is_empty "$pgid" && [[ "$attempt" -lt 50 ]]; do
		sleep 0.05
		attempt=$((attempt + 1))
	done
	process_group_is_empty "$pgid"
}

stop_codex_process_group() {
	local signal_name="$1"
	local pgid="$ACTIVE_CODEX_PGID"
	local leader_pid="$ACTIVE_CODEX_PID"
	local leader_instance="$ACTIVE_CODEX_INSTANCE"
	[[ -n "$pgid" ]] || return 0
	if ! process_group_is_empty "$pgid"; then
		[[ -n "$leader_pid" && "$leader_pid" == "$pgid" && -n "$leader_instance" ]] || return 1
		jobs -pr | awk -v target="$leader_pid" '$1 == target { found = 1 } END { exit found ? 0 : 1 }' || return 1
		process_instance_matches "$leader_pid" "$leader_instance" || return 1
		kill -s "$signal_name" -- "-$pgid" 2>/dev/null || true
		if ! wait_for_process_group_exit "$pgid"; then
			kill -KILL -- "-$pgid" 2>/dev/null || true
			wait_for_process_group_exit "$pgid" || return 1
		fi
	fi
	[[ -z "$leader_pid" ]] || wait "$leader_pid" 2>/dev/null || true
	ACTIVE_CODEX_PID=''
	ACTIVE_CODEX_PGID=''
	ACTIVE_CODEX_INSTANCE=''
}

wait_for_helper() {
	local child_status=0
	wait "$ACTIVE_HELPER_PID" || child_status=$?
	ACTIVE_HELPER_PID=''
	return "$child_status"
}

run_registry_quiet() {
	"$REGISTRY_SCRIPT" "$@" >/dev/null &
	ACTIVE_HELPER_PID=$!
	wait_for_helper
}

create_real_child_directory() {
	local parent="$1"
	local name="$2"
	local label="$3"
	local parent_real
	local path
	local resolved
	local created=0
	local owner=''
	local mode=''
	parent_real="$(cd -P "$parent" 2>/dev/null && pwd -P)" || die "$EXIT_RUNTIME_STATE" "cannot resolve $label parent directory: $parent."
	path="$parent/$name"
	[[ ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "$label must be a real directory, not a symlink: $path."
	if [[ ! -e "$path" ]]; then
		if ! mkdir "$path" 2>/dev/null; then
			[[ -d "$path" && ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "cannot create $label: $path."
		else
			created=1
		fi
	fi
	[[ -d "$path" && ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "$label must be a real directory: $path."
	resolved="$(cd -P "$path" 2>/dev/null && pwd -P)" || die "$EXIT_RUNTIME_STATE" "cannot resolve $label: $path."
	[[ "$resolved" == "$parent_real/$name" ]] || die "$EXIT_RUNTIME_STATE" "$label resolved outside its parent: $path -> $resolved."
	if owner="$(stat -c '%u' "$resolved" 2>/dev/null)"; then :
	elif owner="$(stat -f '%u' "$resolved" 2>/dev/null)"; then :
	else die "$EXIT_RUNTIME_STATE" "cannot inspect $label ownership: $resolved."; fi
	[[ "$owner" == "$UID" ]] || die "$EXIT_RUNTIME_STATE" "$label must be owned by UID $UID: $resolved is owned by UID $owner."
	if [[ "$created" -eq 1 ]]; then
		chmod 0700 "$resolved" || die "$EXIT_RUNTIME_STATE" "cannot restrict $label permissions: $resolved."
	else
		if mode="$(stat -c '%a' "$resolved" 2>/dev/null)"; then :
		elif mode="$(stat -f '%Lp' "$resolved" 2>/dev/null)"; then :
		else die "$EXIT_RUNTIME_STATE" "cannot inspect $label permissions: $resolved."; fi
		[[ "$mode" == 700 ]] || die "$EXIT_RUNTIME_STATE" "$label must have mode 0700: $resolved has mode $mode."
	fi
	printf '%s\n' "$resolved"
}

require_real_child_directory() {
	local parent="$1"
	local name="$2"
	local label="$3"
	local parent_real
	local path
	local resolved
	local owner=''
	parent_real="$(cd -P "$parent" 2>/dev/null && pwd -P)" || die "$EXIT_RUNTIME_STATE" "cannot resolve $label parent directory: $parent."
	path="$parent/$name"
	[[ -d "$path" && ! -L "$path" ]] || die "$EXIT_WORKER" "$label is missing or symlinked: $path."
	resolved="$(cd -P "$path" 2>/dev/null && pwd -P)" || die "$EXIT_RUNTIME_STATE" "cannot resolve $label: $path."
	[[ "$resolved" == "$parent_real/$name" ]] || die "$EXIT_RUNTIME_STATE" "$label resolved outside its parent: $path -> $resolved."
	if owner="$(stat -c '%u' "$resolved" 2>/dev/null)"; then :
	elif owner="$(stat -f '%u' "$resolved" 2>/dev/null)"; then :
	else die "$EXIT_RUNTIME_STATE" "cannot inspect $label ownership: $resolved."; fi
	[[ "$owner" == "$UID" ]] || die "$EXIT_RUNTIME_STATE" "$label must be owned by UID $UID: $resolved is owned by UID $owner."
	local mode=''
	if mode="$(stat -c '%a' "$resolved" 2>/dev/null)"; then :
	elif mode="$(stat -f '%Lp' "$resolved" 2>/dev/null)"; then :
	else die "$EXIT_RUNTIME_STATE" "cannot inspect $label permissions: $resolved."; fi
	[[ "$mode" == 700 ]] || die "$EXIT_RUNTIME_STATE" "$label must have mode 0700: $resolved has mode $mode."
	printf '%s\n' "$resolved"
}

resolve_registry_directory() {
	local registry_path="$1"
	local expected_registry_path="$REPO_ROOT/.agents/agent-registry/registry.json"
	local registry_dir=''
	[[ "$registry_path" == "$expected_registry_path" ]] || die "$EXIT_RUNTIME_STATE" "registry path is not the exact project-local authority: $registry_path."
	registry_dir="$(dirname "$registry_path")" || die "$EXIT_RUNTIME_STATE" "cannot derive registry directory from authoritative registry path: $registry_path."
	[[ "$registry_dir" == "$REPO_ROOT/.agents/agent-registry" ]] || die "$EXIT_RUNTIME_STATE" "registry directory is not the exact project-local authority directory: $registry_dir."
	printf '%s\n' "$registry_dir"
}

artifact_link_count() {
	local path="$1"
	local count=''
	if count="$(stat -c '%h' "$path" 2>/dev/null)"; then
		:
	elif count="$(stat -f '%l' "$path" 2>/dev/null)"; then
		:
	else
		return 1
	fi
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$count"
}

require_owned_artifact_file() {
	local path="$1"
	local label="$2"
	local link_count=''
	local owner=''
	local mode=''
	[[ -f "$path" && ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "$label must be a real regular file: $path."
	link_count="$(artifact_link_count "$path")" || die "$EXIT_RUNTIME_STATE" "cannot inspect $label link count: $path."
	[[ "$link_count" -eq 1 ]] || die "$EXIT_RUNTIME_STATE" "$label must have exactly one hard link: $path."
	if owner="$(stat -c '%u' "$path" 2>/dev/null)"; then :
	elif owner="$(stat -f '%u' "$path" 2>/dev/null)"; then :
	else die "$EXIT_RUNTIME_STATE" "cannot inspect $label ownership: $path."; fi
	[[ "$owner" == "$UID" ]] || die "$EXIT_RUNTIME_STATE" "$label must be owned by UID $UID: $path is owned by UID $owner."
	if mode="$(stat -c '%a' "$path" 2>/dev/null)"; then :
	elif mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then :
	else die "$EXIT_RUNTIME_STATE" "cannot inspect $label permissions: $path."; fi
	[[ "$mode" == 600 ]] || die "$EXIT_RUNTIME_STATE" "$label must have mode 0600: $path has mode $mode."
}

artifact_identity() {
	local path="$1"
	local identity=''
	if identity="$(stat -c '%d:%i' "$path" 2>/dev/null)"; then
		:
	elif identity="$(stat -f '%d:%i' "$path" 2>/dev/null)"; then
		:
	else
		return 1
	fi
	[[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
	printf '%s\n' "$identity"
}

remember_prompt_staging() {
	PROMPT_STAGING_PATH="$1"
	PROMPT_STAGING_IDENTITY=''
	PROMPT_STAGING_IDENTITY="$(artifact_identity "$PROMPT_STAGING_PATH")" || die "$EXIT_RUNTIME_STATE" "cannot record task prompt staging identity: $PROMPT_STAGING_PATH"
}

remove_prompt_staging() {
	local current_identity=''
	local link_count=''
	[[ -n "$PROMPT_STAGING_PATH" ]] || return 0
	if [[ ! -e "$PROMPT_STAGING_PATH" && ! -L "$PROMPT_STAGING_PATH" ]]; then
		PROMPT_STAGING_PATH=''
		PROMPT_STAGING_IDENTITY=''
		return 0
	fi
	[[ -n "$PROMPT_STAGING_IDENTITY" ]] || return 1
	[[ -f "$PROMPT_STAGING_PATH" && ! -L "$PROMPT_STAGING_PATH" ]] || return 1
	link_count="$(artifact_link_count "$PROMPT_STAGING_PATH" 2>/dev/null)" || return 1
	[[ "$link_count" -eq 1 ]] || return 1
	current_identity="$(artifact_identity "$PROMPT_STAGING_PATH" 2>/dev/null)" || return 1
	[[ "$current_identity" == "$PROMPT_STAGING_IDENTITY" ]] || return 1
	rm "$PROMPT_STAGING_PATH" 2>/dev/null || return 1
	PROMPT_STAGING_PATH=''
	PROMPT_STAGING_IDENTITY=''
}

cleanup_prompt_staging() {
	remove_prompt_staging || true
}

open_prompt_descriptor() {
	local prompt_path="$1"
	require_owned_artifact_file "$prompt_path" 'task prompt snapshot'
	exec 8<"$prompt_path" || die "$EXIT_RUNTIME_STATE" "cannot open task prompt snapshot: $prompt_path"
	PROMPT_DESCRIPTOR_OPEN=1
}

close_prompt_descriptor() {
	if [[ "$PROMPT_DESCRIPTOR_OPEN" -eq 1 ]]; then
		exec 8<&- || true
		PROMPT_DESCRIPTOR_OPEN=0
	fi
}

create_owned_artifact_file() {
	local path="$1"
	local label="$2"
	[[ ! -e "$path" && ! -L "$path" ]] || die "$EXIT_RUNTIME_STATE" "$label already exists; refusing to overwrite it: $path."
	if ! (set -o noclobber; : >"$path") 2>/dev/null; then
		die "$EXIT_RUNTIME_STATE" "cannot exclusively create $label: $path."
	fi
	require_owned_artifact_file "$path" "$label"
}

snapshot_prompt_file() {
	local source_path="$1"
	local snapshot_path="$2"
	local include_worker_boundary="${3:-0}"
	create_owned_artifact_file "$snapshot_path" 'task prompt snapshot'
	if [[ "$snapshot_path" == "$PROMPT_STAGING_PATH" ]]; then
		remember_prompt_staging "$snapshot_path"
	fi
	if [[ "$include_worker_boundary" == 1 ]]; then
		printf '%s\n\n' "$WORKER_BOUNDARY_INSTRUCTION" >"$snapshot_path" || die "$EXIT_RUNTIME_STATE" "cannot write worker boundary to task prompt: $snapshot_path"
	fi
	if ! cat "$source_path" >>"$snapshot_path"; then
		die "$EXIT_RUNTIME_STATE" "cannot snapshot validated task prompt: $source_path"
	fi
	if [[ "$include_worker_boundary" == 1 ]]; then
		printf '\n\n%s\n' "$WORKER_BOUNDARY_INSTRUCTION" >>"$snapshot_path" || die "$EXIT_RUNTIME_STATE" "cannot finish worker boundary in task prompt: $snapshot_path"
	fi
	require_owned_artifact_file "$snapshot_path" 'task prompt snapshot'
}

run_gated_codex() {
	local artifact_dir="$1"
	local stream_log="$2"
	local stream_stderr="$3"
	local stdin_source="$4"
	local codex_cwd="$5"
	shift 5
	local gate_path="$artifact_dir/.start-$INVOCATION_TOKEN"
	local lease_path="$artifact_dir/.lease-$INVOCATION_TOKEN"
	local lease_ready_path="$artifact_dir/.lease-ready-$INVOCATION_TOKEN"
	local parent_pid="$$"
	local child_status=0
	local child_pid
	local child_pgid
	if [[ "$stdin_source" == "$PROMPT_DESCRIPTOR_SOURCE" ]]; then
		[[ "$PROMPT_DESCRIPTOR_OPEN" -eq 1 ]] || return 1
	fi
	require_owned_artifact_file "$stream_log" 'Codex JSONL artifact'
	require_owned_artifact_file "$stream_stderr" 'Codex stderr artifact'
	[[ ! -e "$gate_path" && ! -L "$gate_path" ]] || die "$EXIT_RUNTIME_STATE" "Codex start gate already exists; refusing to overwrite it: $gate_path."
	[[ ! -e "$lease_path" && ! -L "$lease_path" ]] || die "$EXIT_RUNTIME_STATE" "Codex lease already exists; refusing to overwrite it: $lease_path."
	[[ ! -e "$lease_ready_path" && ! -L "$lease_ready_path" ]] || die "$EXIT_RUNTIME_STATE" "Codex lease-ready marker already exists; refusing to overwrite it: $lease_ready_path."
	create_owned_artifact_file "$lease_ready_path" 'Codex lease-ready marker'
	if ! mkfifo "$lease_path"; then
		rm -f "$lease_ready_path"
		return 1
	fi
	if ! chmod 0600 "$lease_path"; then
		rm -f "$lease_path" "$lease_ready_path"
		return 1
	fi
	if ! exec 7>>"$lease_ready_path"; then
		rm -f "$lease_path" "$lease_ready_path"
		return 1
	fi
	cat "$lease_path" >/dev/null &
	ACTIVE_LEASE_PID=$!
	ACTIVE_LEASE_INSTANCE="$(process_instance_identity "$ACTIVE_LEASE_PID")" || {
		kill -TERM "$ACTIVE_LEASE_PID" 2>/dev/null || true
		wait "$ACTIVE_LEASE_PID" 2>/dev/null || true
		ACTIVE_LEASE_PID=''
		exec 7>&-
		rm -f "$lease_path"
		return 1
	}
	set -m
	(
		exec 9>"$lease_path"
		printf '%s\n' ready >&7
		export LUNA_WORKER_PROCESS_TOKEN="$INVOCATION_TOKEN"
		cd "$codex_cwd" || exit 126
		while [[ ! -f "$gate_path" ]]; do
			kill -0 "$parent_pid" 2>/dev/null || exit 125
			sleep 0.05
		done
		if [[ "$stdin_source" == "$PROMPT_DESCRIPTOR_SOURCE" ]]; then
			exec 7>&-
			exec "$@" <&8
		elif [[ -n "$stdin_source" ]]; then
			exec 8<&-
			exec 7>&-
			exec "$@" <"$stdin_source"
		else
			exec 8<&-
			exec 7>&-
			exec "$@" </dev/null
		fi
		) >>"$stream_log" 2>>"$stream_stderr" &
	set +m
	ACTIVE_CODEX_PID=$!
	child_pid="$ACTIVE_CODEX_PID"
	while [[ ! -s "$lease_ready_path" ]]; do
		kill -0 "$child_pid" 2>/dev/null || break
		process_instance_matches "$ACTIVE_LEASE_PID" "$ACTIVE_LEASE_INSTANCE" || break
		sleep 0.01
	done
	if [[ ! -s "$lease_ready_path" ]]; then
		kill -TERM "$child_pid" 2>/dev/null || true
		wait "$child_pid" 2>/dev/null || true
		kill -TERM "$ACTIVE_LEASE_PID" 2>/dev/null || true
		wait "$ACTIVE_LEASE_PID" 2>/dev/null || true
		ACTIVE_CODEX_PID=''
		ACTIVE_LEASE_PID=''
		ACTIVE_LEASE_INSTANCE=''
		exec 7>&-
		rm -f "$lease_path" "$lease_ready_path"
		return 1
	fi
	exec 7>&-
	rm -f "$lease_path" "$lease_ready_path"
	ACTIVE_CODEX_INSTANCE="$(process_instance_identity "$child_pid")" || {
		kill -TERM "$child_pid" 2>/dev/null || true
		wait "$child_pid" 2>/dev/null || true
		stop_active_lease
		ACTIVE_CODEX_PID=''
		ACTIVE_CODEX_INSTANCE=''
		return 1
	}
	child_pgid="$(ps -p "$child_pid" -o pgid= 2>/dev/null | awk 'NF {print $1; exit}')"
	ACTIVE_CODEX_PGID="$child_pgid"
	if [[ "$child_pgid" != "$child_pid" ]]; then
		kill -TERM "$child_pid" 2>/dev/null || true
		wait "$child_pid" 2>/dev/null || true
		stop_active_lease
		ACTIVE_CODEX_PID=''
		ACTIVE_CODEX_PGID=''
		ACTIVE_CODEX_INSTANCE=''
		return 1
	fi
	ACTIVE_TRACKER_STATE="$artifact_dir/.descendants-$INVOCATION_TOKEN.json"
	if [[ -e "$ACTIVE_TRACKER_STATE" || -L "$ACTIVE_TRACKER_STATE" ]]; then
		require_owned_artifact_file "$ACTIVE_TRACKER_STATE" 'previous descendant tracker state'
		jq -e '.status == "clean" and (.root_pid | type == "number" and . > 0 and floor == .) and .processes == []' "$ACTIVE_TRACKER_STATE" >/dev/null 2>&1 || die "$EXIT_RUNTIME_STATE" "previous descendant tracker has not proved a clean process tree: $ACTIVE_TRACKER_STATE."
		rm "$ACTIVE_TRACKER_STATE" || die "$EXIT_RUNTIME_STATE" "cannot replace validated clean descendant tracker state: $ACTIVE_TRACKER_STATE."
	fi
	monitor_descendant_tree "$child_pid" "$ACTIVE_TRACKER_STATE" "$ACTIVE_LEASE_PID" "$ACTIVE_LEASE_INSTANCE" >/dev/null 2>&1 &
	ACTIVE_TRACKER_PID=$!
	while [[ ! -s "$ACTIVE_TRACKER_STATE" ]]; do
		kill -0 "$ACTIVE_TRACKER_PID" 2>/dev/null || break
		sleep 0.01
	done
	jq -e '.status == "active"' "$ACTIVE_TRACKER_STATE" >/dev/null 2>&1 || {
		stop_codex_process_group TERM || true
		stop_tracked_worker_processes TERM || true
		stop_active_lease
		return 1
	}
	if ! run_registry_quiet record-child --task-id "$TASK_ID" --pgid "$child_pgid" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT"; then
		stop_codex_process_group TERM || true
		stop_tracked_worker_processes TERM || true
		stop_active_lease
		return 1
	fi
	if ! create_owned_artifact_file "$gate_path" 'Codex start gate'; then
		stop_codex_process_group TERM || true
		stop_tracked_worker_processes TERM || true
		stop_active_lease
		return 1
	fi
	wait "$child_pid" || child_status=$?
	ACTIVE_CODEX_PID=''
	ACTIVE_CODEX_INSTANCE=''
	rm -f "$gate_path"
	ACTIVE_CODEX_PGID=''
	stop_tracked_worker_processes TERM || return 1
	require_owned_artifact_file "$stream_log" 'Codex JSONL artifact'
	require_owned_artifact_file "$stream_stderr" 'Codex stderr artifact'
	if ! run_registry_quiet clear-child --task-id "$TASK_ID" --pgid "$child_pgid" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT"; then
		ACTIVE_CODEX_PGID=''
		return 1
	fi
	ACTIVE_CODEX_PGID=''
	return "$child_status"
}

trap 'stop_active_child_and_exit INT 130' INT
trap 'stop_active_child_and_exit TERM 143' TERM
trap 'stop_active_child_and_exit HUP 129' HUP

extract_session_id() {
	local log_path="$1"
	jq -r 'select(.type == "thread.started") | (.thread_id // .threadId // empty)' "$log_path" 2>/dev/null | head -n 1
}

validate_result() {
	local result_path="$1"
	jq -e '
    type == "object"
    and (.outcome == "completed" or .outcome == "blocked" or .outcome == "needs_parent_action")
    and (.summary | type == "string" and length > 0)
    and (.changedFiles | type == "array" and all(.[]; type == "string"))
    and (.validators | type == "array" and all(.[]; (.command | type == "string" and length > 0) and (.status == "passed" or .status == "failed" or .status == "not_run") and (.evidence | type == "string" and length > 0)))
    and (.unresolved | type == "array" and all(.[]; type == "string"))
    and (if .outcome == "needs_parent_action"
         then (.parentAction | type == "string" and length > 0)
         elif .outcome == "completed"
         then .parentAction == null and (.unresolved | length == 0) and (.validators | length > 0) and all(.validators[]; .status == "passed")
         else .parentAction == null
         end)
  ' "$result_path" >/dev/null
}

resume_task() {
	local artifact_dir="$1"
	local resume_prompt_source="$2"
	local attempt
	local stream_log
	local stream_stderr
	local result_path
	local existing_artifact
	local continuation_prompt=''
	attempt=0
	for existing_artifact in "$artifact_dir"/stream-*.jsonl "$artifact_dir"/stream-*.stderr.log "$artifact_dir"/result-*.json; do
		[[ -e "$existing_artifact" || -L "$existing_artifact" ]] || continue
		require_owned_artifact_file "$existing_artifact" 'existing worker artifact'
		if [[ "${existing_artifact##*/}" =~ ^(stream|result)-([0-9]+)(\.jsonl|\.stderr\.log|\.json)$ ]]; then
			[[ "${BASH_REMATCH[2]}" -le "$attempt" ]] || attempt="${BASH_REMATCH[2]}"
		fi
	done
	attempt=$((attempt + 1))
	stream_log="$artifact_dir/stream-$attempt.jsonl"
	stream_stderr="$artifact_dir/stream-$attempt.stderr.log"
	result_path="$artifact_dir/result-$attempt.json"
	create_owned_artifact_file "$stream_log" 'Codex JSONL artifact'
	create_owned_artifact_file "$stream_stderr" 'Codex stderr artifact'
	create_owned_artifact_file "$result_path" 'worker result artifact'
	if [[ "$resume_prompt_source" != "$PROMPT_DESCRIPTOR_SOURCE" ]]; then
		continuation_prompt="$artifact_dir/parent-prompt-$attempt"
		snapshot_prompt_file "$resume_prompt_source" "$continuation_prompt" 1
		resume_prompt_source="$continuation_prompt"
	fi

	local codex_status=0
	run_gated_codex "$artifact_dir" "$stream_log" "$stream_stderr" "$resume_prompt_source" "$REPO_ROOT" "$CODEX_BIN" exec resume \
		--ignore-user-config \
		--strict-config \
		-m "$MODEL" \
		-c "model_reasoning_effort=$REASONING_EFFORT" \
		-c "sandbox_mode=\"$TASK_SANDBOX\"" \
		--json \
		--output-schema "$RESULT_SCHEMA" \
		--output-last-message "$result_path" \
		-- "$SESSION_ID" - || codex_status=$?
	if [[ "$resume_prompt_source" == "$PROMPT_DESCRIPTOR_SOURCE" ]]; then
		close_prompt_descriptor
	fi
	if [[ "$codex_status" -ne 0 ]]; then
		die "$EXIT_WORKER" "Codex resume failed for task $TASK_ID. Logs: $stream_log and $stream_stderr"
	fi
	validate_result "$result_path" || die "$EXIT_WORKER" "worker returned invalid structured output: $result_path."
	require_owned_artifact_file "$result_path" 'worker result artifact'

	local outcome
	local evidence
	outcome="$(jq -r '.outcome' "$result_path")"
	evidence="$(jq -r '.summary' "$result_path")"
	case "$outcome" in
	completed)
		run_registry_quiet complete-and-retire --task-id "$TASK_ID" --status completed --evidence "$evidence" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT"
		TERMINAL_RETIREMENT_COMPLETE=1
		INVOCATION_CLAIMED=0
		release_cross_path_claim || die "$EXIT_RUNTIME_STATE" "cannot release cross-path claim after completing task $TASK_ID."
		FINISHED=1
		;;
	blocked)
		run_registry_quiet complete-and-retire --task-id "$TASK_ID" --status blocked --evidence "$evidence" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT"
		TERMINAL_RETIREMENT_COMPLETE=1
		INVOCATION_CLAIMED=0
		release_cross_path_claim || die "$EXIT_RUNTIME_STATE" "cannot release cross-path claim after blocking task $TASK_ID."
		FINISHED=1
		;;
	needs_parent_action)
		run_registry_quiet checkpoint --task-id "$TASK_ID" --evidence "$evidence" --repo "$REPO_INPUT"
		release_invocation
		FINISHED=1
		;;
	esac
	cat "$result_path"
	printf '\nWorker artifacts: %s\n' "$artifact_dir" >&2
}

launch_worker() {
	trap finish_on_error EXIT
	[[ -n "$SCOPE" ]] || die "$EXIT_USAGE" 'launch requires non-empty --scope.'
	validate_common
	preflight_workspace_write_launch
	local registry_path
	local registry_dir
	local artifact_root
	local artifact_dir
	local prompt_staging
	local prompt_snapshot
	prepare_invocation
	acquire_cross_path_claim
	registry_path="$($REGISTRY_SCRIPT init --repo "$REPO_INPUT" --print-path)"
	registry_dir="$(resolve_registry_directory "$registry_path")"
	artifact_root="$(create_real_child_directory "$registry_dir" artifacts 'artifact root')"
	prompt_staging="$artifact_root/.prompt-$INVOCATION_TOKEN"
	PROMPT_STAGING_PATH="$prompt_staging"
	snapshot_prompt_file "$PROMPT_FILE" "$prompt_staging" 1
	local reserve_args=(reserve --task-id "$TASK_ID" --scope "$SCOPE" --pid "$$" --token "$INVOCATION_TOKEN" --repo "$REPO_INPUT")
	[[ -z "$RETRY_OF" ]] || reserve_args+=(--retry-of "$RETRY_OF")
	[[ -z "$TASK_SANDBOX" ]] || reserve_args+=(--sandbox "$TASK_SANDBOX")
	run_registry_quiet "${reserve_args[@]}"
	INVOCATION_CLAIMED=1
	TASK_SANDBOX="$("$REGISTRY_SCRIPT" query --task-id "$TASK_ID" --repo "$REPO_INPUT" | jq -r '.sandbox')"
	case "$TASK_SANDBOX" in read-only | workspace-write) ;; *) die "$EXIT_RUNTIME_STATE" "registry returned invalid sandbox for task $TASK_ID." ;; esac

	artifact_dir="$(create_real_child_directory "$artifact_root" "$TASK_ID" 'task artifact directory')"
	prompt_snapshot="$artifact_dir/.task-prompt"
	[[ ! -e "$prompt_snapshot" && ! -L "$prompt_snapshot" ]] || die "$EXIT_RUNTIME_STATE" 'task prompt snapshot already exists; refusing to overwrite it.'
	snapshot_prompt_file "$prompt_staging" "$prompt_snapshot"
	remove_prompt_staging || die "$EXIT_RUNTIME_STATE" "cannot safely release staged task prompt snapshot: $prompt_staging"
	require_owned_artifact_file "$prompt_snapshot" 'task prompt snapshot'
	open_prompt_descriptor "$prompt_snapshot"

	local launch_log
	local launch_stderr
	launch_log="$artifact_dir/launch.jsonl"
	launch_stderr="$artifact_dir/launch.stderr.log"
	create_owned_artifact_file "$launch_log" 'handshake JSONL artifact'
	create_owned_artifact_file "$launch_stderr" 'handshake stderr artifact'

	local codex_status=0
	run_gated_codex "$artifact_dir" "$launch_log" "$launch_stderr" '' "$REPO_ROOT" "$CODEX_BIN" exec \
		--ignore-user-config \
		--strict-config \
		-m "$MODEL" \
		-c "model_reasoning_effort=$REASONING_EFFORT" \
		-s read-only \
		-C "$REPO_ROOT" \
		--json \
		'Handshake only. Do not inspect or modify the repository. Reply exactly READY_TO_BIND.' || codex_status=$?
	if [[ "$codex_status" -ne 0 ]]; then
		SESSION_ID="$(extract_session_id "$launch_log")"
		[[ -z "$SESSION_ID" ]] || run_registry_quiet bind --task-id "$TASK_ID" --session-id "$SESSION_ID" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT"
		die "$EXIT_WORKER" "Codex handshake failed for task $TASK_ID. Logs: $launch_log and $launch_stderr"
	fi
	SESSION_ID="$(extract_session_id "$launch_log")"
	[[ -n "$SESSION_ID" ]] || die "$EXIT_WORKER" "Codex handshake emitted no thread.started session ID. Log: $launch_log"
	run_registry_quiet bind --task-id "$TASK_ID" --session-id "$SESSION_ID" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT"
	run_registry_quiet activate --task-id "$TASK_ID" --session-id "$SESSION_ID" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT"
	resume_task "$artifact_dir" "$PROMPT_DESCRIPTOR_SOURCE"
}

continue_worker() {
	validate_common
	local registry_path
	local registry_dir
	local artifact_root
	local artifact_dir
	local worker
	registry_path="$($REGISTRY_SCRIPT path --repo "$REPO_INPUT")"
	registry_dir="$(resolve_registry_directory "$registry_path")"
	artifact_root="$(require_real_child_directory "$registry_dir" artifacts 'artifact root')"
	artifact_dir="$(require_real_child_directory "$artifact_root" "$TASK_ID" 'task artifact directory')"
	trap finish_on_error EXIT
	worker="$($REGISTRY_SCRIPT query --task-id "$TASK_ID" --repo "$REPO_INPUT")"
	SESSION_ID="$(jq -r '.session_id' <<<"$worker")"
	SCOPE="$(jq -r '.scope' <<<"$worker")"
	TASK_SANDBOX="$(jq -r '.sandbox' <<<"$worker")"
	case "$TASK_SANDBOX" in read-only | workspace-write) ;; *) die "$EXIT_RUNTIME_STATE" "registry returned invalid sandbox for task $TASK_ID." ;; esac
	[[ "$TASK_SANDBOX" == read-only ]] || require_workspace_write_boundary
	acquire_cross_path_claim reenter
	claim_invocation
	resume_task "$artifact_dir" "$PROMPT_FILE"
}

finish_worker() {
	[[ -n "$TASK_ID" && -n "$FINISH_STATUS" && -n "$FINISH_EVIDENCE" ]] || die "$EXIT_USAGE" 'finish requires --task-id, --status, and --evidence.'
	case "$FINISH_STATUS" in failed | blocked | interrupted) ;; *) die "$EXIT_USAGE" 'finish status must be failed, blocked, or interrupted.' ;; esac
	local worker
	worker="$($REGISTRY_SCRIPT query --task-id "$TASK_ID" --repo "$REPO_INPUT")"
	SCOPE="$(jq -r '.scope' <<<"$worker")"
	trap finish_on_error EXIT
	acquire_cross_path_claim recover
	claim_invocation
	run_registry_quiet complete-and-retire --task-id "$TASK_ID" --status "$FINISH_STATUS" --evidence "$FINISH_EVIDENCE" --invocation-token "$INVOCATION_TOKEN" --repo "$REPO_INPUT"
	TERMINAL_RETIREMENT_COMPLETE=1
	INVOCATION_CLAIMED=0
	release_cross_path_claim || die "$EXIT_RUNTIME_STATE" "cannot release cross-path claim after finishing task $TASK_ID."
	FINISHED=1
}

[[ $# -gt 0 ]] || usage "$EXIT_USAGE"
case "$1" in launch | continue | finish)
	MODE="$1"
	shift
	;;
--help | -h) usage "$EXIT_OK" ;; esac
FINISH_STATUS=''
FINISH_EVIDENCE=''
while [[ $# -gt 0 ]]; do
	case "$1" in
	--task-id)
		TASK_ID="${2:-}"
		shift 2
		;;
	--scope)
		SCOPE="${2:-}"
		shift 2
		;;
	--retry-of)
		RETRY_OF="${2:-}"
		shift 2
		;;
	--prompt-file)
		PROMPT_FILE="${2:-}"
		shift 2
		;;
	--sandbox)
		TASK_SANDBOX="${2:-}"
		shift 2
		;;
	--repo | -C)
		REPO_INPUT="${2:-}"
		shift 2
		;;
	--status)
		FINISH_STATUS="${2:-}"
		shift 2
		;;
	--evidence)
		FINISH_EVIDENCE="${2:-}"
		shift 2
		;;
	--help | -h) usage "$EXIT_OK" ;;
	*) die "$EXIT_USAGE" "unknown argument: $1." ;;
	esac
done

case "$MODE" in
launch) launch_worker ;;
continue) continue_worker ;;
finish) finish_worker ;;
esac
