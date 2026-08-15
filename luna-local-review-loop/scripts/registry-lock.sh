#!/usr/bin/env bash

# Shared atomic registry lock. The owner PID and process-start identity are
# written before the lock is published, so a crash cannot leave an ownerless
# acquired lock.

LOCK_OWNER_FILE=''

release_lock() {
	if [[ "$LOCK_HELD" -eq 1 && -n "$LOCK_OWNER_FILE" ]]; then
		if [[ -f "$LOCK_DIR" && ! -L "$LOCK_DIR" && "$LOCK_DIR" -ef "$LOCK_OWNER_FILE" ]]; then
			rm -f "$LOCK_DIR" 2>/dev/null || true
		fi
		LOCK_HELD=0
	fi
	if [[ -n "$LOCK_OWNER_FILE" ]]; then
		rm -f "$LOCK_OWNER_FILE" 2>/dev/null || true
		LOCK_OWNER_FILE=''
	fi
}

remove_stale_lock_file() {
	local attempt="$1"
	local expected_record="$2"
	local observed_record=''
	local witness="$REGISTRY_DIR/.lock-observed.$$.$attempt"

	[[ -f "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] || return 1
	rm -f "$witness" 2>/dev/null || true
	ln -n "$LOCK_DIR" "$witness" 2>/dev/null || return 1
	if [[ ! "$LOCK_DIR" -ef "$witness" ]]; then
		rm -f "$witness" 2>/dev/null || true
		return 1
	fi
	IFS= read -r observed_record <"$witness" || observed_record=''
	if [[ "$observed_record" != "$expected_record" ]]; then
		rm -f "$witness" 2>/dev/null || true
		return 1
	fi
	if ! lock_owner_is_confirmed_stale "$observed_record"; then
		rm -f "$witness" 2>/dev/null || true
		return 1
	fi
	if [[ -f "$LOCK_DIR" && ! -L "$LOCK_DIR" && "$LOCK_DIR" -ef "$witness" ]]; then
		rm -f "$LOCK_DIR" 2>/dev/null || true
	fi
	rm -f "$witness" 2>/dev/null || true
}

lock_process_instance_identity() {
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

lock_owner_is_confirmed_stale() {
	local owner_record="$1"
	local owner_pid=''
	local owner_instance=''
	local current_instance=''
	case "$owner_record" in
	*'|'*)
		owner_pid="${owner_record%%|*}"
		owner_instance="${owner_record#*|}"
		;;
	*) owner_pid="$owner_record" ;;
	esac
	case "$owner_pid" in '' | 0 | *[!0-9]*) return 0 ;; esac
	pid_is_confirmed_nonexistent "$owner_pid" && return 0
	if [[ -z "$owner_instance" ]]; then
		return 1
	fi
	[[ "$owner_instance" =~ ^proc:[0-9]+$ || "$owner_instance" =~ ^ps:.+ ]] || return 1
	if current_instance="$(lock_process_instance_identity "$owner_pid")"; then
		[[ "$current_instance" != "$owner_instance" ]]
		return
	fi
	pid_is_confirmed_nonexistent "$owner_pid"
}

acquire_lock() {
	local attempt=0
	local owner_record=''
	local owner_instance=''

	LOCK_OWNER_FILE="$(mktemp "$REGISTRY_DIR/.lock-owner.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create registry-lock owner candidate in $REGISTRY_DIR."
	owner_instance="$(lock_process_instance_identity "$$")" || die "$EXIT_LOCK" "cannot identify registry-lock owner process instance for PID $$."
	printf '%s|%s\n' "$$" "$owner_instance" >"$LOCK_OWNER_FILE" || die "$EXIT_FILESYSTEM" "cannot record registry-lock owner in $LOCK_OWNER_FILE."
	trap release_lock EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	while true; do
		[[ ! -L "$LOCK_DIR" ]] || die "$EXIT_FILESYSTEM" "registry lock must not be a symlink: $LOCK_DIR."
		if ln -n "$LOCK_OWNER_FILE" "$LOCK_DIR" 2>/dev/null; then
			break
		fi
		[[ ! -L "$LOCK_DIR" ]] || die "$EXIT_FILESYSTEM" "registry lock must not be a symlink: $LOCK_DIR."
		[[ -f "$LOCK_DIR" ]] || die "$EXIT_FILESYSTEM" "registry lock must be an atomic regular file: $LOCK_DIR. Preserve it for inspection before retrying."
		owner_record=''
		IFS= read -r owner_record <"$LOCK_DIR" || owner_record=''
		if lock_owner_is_confirmed_stale "$owner_record"; then
			remove_stale_lock_file "$attempt" "$owner_record" || true
		fi
		attempt=$((attempt + 1))
		[[ "$attempt" -lt 50 ]] || die "$EXIT_LOCK" "registry lock is busy: $LOCK_DIR. Inspect its owner and remove only a confirmed-stale lock."
		sleep 0.1
	done
	LOCK_HELD=1
}
