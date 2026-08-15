#!/usr/bin/env bash

# Shared atomic registry lock. The owner PID is written before the lock is
# published, so a crash cannot leave an ownerless acquired lock.

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
	local expected_pid="$2"
	local observed_pid=''
	local witness="$REGISTRY_DIR/.lock-observed.$$.$attempt"

	[[ -f "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] || return 1
	rm -f "$witness" 2>/dev/null || true
	ln -n "$LOCK_DIR" "$witness" 2>/dev/null || return 1
	if [[ ! "$LOCK_DIR" -ef "$witness" ]]; then
		rm -f "$witness" 2>/dev/null || true
		return 1
	fi
	IFS= read -r observed_pid <"$witness" || observed_pid=''
	if [[ "$observed_pid" != "$expected_pid" ]]; then
		rm -f "$witness" 2>/dev/null || true
		return 1
	fi
	if [[ -n "$observed_pid" ]] && ! pid_is_confirmed_nonexistent "$observed_pid"; then
		rm -f "$witness" 2>/dev/null || true
		return 1
	fi
	if [[ -f "$LOCK_DIR" && ! -L "$LOCK_DIR" && "$LOCK_DIR" -ef "$witness" ]]; then
		rm -f "$LOCK_DIR" 2>/dev/null || true
	fi
	rm -f "$witness" 2>/dev/null || true
}

acquire_lock() {
	local attempt=0
	local owner_pid=''

	LOCK_OWNER_FILE="$(mktemp "$REGISTRY_DIR/.lock-owner.XXXXXX")" || die "$EXIT_FILESYSTEM" "cannot create registry-lock owner candidate in $REGISTRY_DIR."
	printf '%s\n' "$$" >"$LOCK_OWNER_FILE" || die "$EXIT_FILESYSTEM" "cannot record registry-lock owner in $LOCK_OWNER_FILE."
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
		owner_pid=''
		IFS= read -r owner_pid <"$LOCK_DIR" || owner_pid=''
		case "$owner_pid" in
		0 | *[!0-9]*) owner_pid='' ;;
		esac
		if [[ -z "$owner_pid" ]] || pid_is_confirmed_nonexistent "$owner_pid"; then
			remove_stale_lock_file "$attempt" "$owner_pid" || true
		fi
		attempt=$((attempt + 1))
		[[ "$attempt" -lt 50 ]] || die "$EXIT_LOCK" "registry lock is busy: $LOCK_DIR. Inspect its owner and remove only a confirmed-stale lock."
		sleep 0.1
	done
	LOCK_HELD=1
}
