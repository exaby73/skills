#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
TEMP_ROOT="$(mktemp -d)"
readonly TEMP_ROOT

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'test-init: FAIL: %s\n' "$*" >&2
  exit 1
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

readonly REPO_ROOT="$TEMP_ROOT/repository"
readonly FAKE_BIN="$TEMP_ROOT/bin"
readonly NPM_LOG="$TEMP_ROOT/npx.log"

mkdir -p "$REPO_ROOT" "$FAKE_BIN"
git -C "$REPO_ROOT" init -q

printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/codex"
chmod 0755 "$FAKE_BIN/codex"

cat > "$FAKE_BIN/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_NPX_LOG"
case "$*" in
  '-y skills add https://github.com/google-gemini/gemini-cli --skill code-reviewer -y')
    mkdir -p .agents/skills/code-reviewer
    printf '%s\n' '# code-reviewer' > .agents/skills/code-reviewer/SKILL.md
    ;;
  '-y skills add https://github.com/juliusbrussee/caveman --skill caveman -y')
    mkdir -p .agents/skills/caveman
    printf '%s\n' '# caveman' > .agents/skills/caveman/SKILL.md
    ;;
  *)
    printf 'unexpected npx argv: %s\n' "$*" >&2
    exit 64
    ;;
esac
EOF
chmod 0755 "$FAKE_BIN/npx"

PATH="$FAKE_BIN:$PATH" FAKE_NPX_LOG="$NPM_LOG" "$SCRIPT_DIR/init.sh" --repo "$REPO_ROOT" >/dev/null

[[ -f "$REPO_ROOT/.agents/skills/code-reviewer/SKILL.md" ]] || fail 'code-reviewer was not installed project-locally'
[[ -f "$REPO_ROOT/.agents/skills/caveman/SKILL.md" ]] || fail 'Caveman was not installed project-locally'
[[ -f "$REPO_ROOT/.agents/agent-registry/registry.json" ]] || fail 'registry was not initialized'
[[ "$(file_mode "$REPO_ROOT/.gitignore")" == '644' ]] || fail 'new .gitignore mode is not 0644'
[[ "$(awk '$0 == ".agents/agent-registry/" { count += 1 } END { print count + 0 }' "$REPO_ROOT/.gitignore")" == '1' ]] || fail 'registry ignore entry is not unique'
[[ "$(wc -l < "$NPM_LOG" | tr -d ' ')" == '2' ]] || fail 'expected exactly two dependency install calls'
grep -Fxq -- '-y skills add https://github.com/google-gemini/gemini-cli --skill code-reviewer -y' "$NPM_LOG" || fail 'code-reviewer install argv changed'
grep -Fxq -- '-y skills add https://github.com/juliusbrussee/caveman --skill caveman -y' "$NPM_LOG" || fail 'Caveman install argv changed'

for expected_mode in 444 600 640 755; do
  chmod 0644 "$REPO_ROOT/.gitignore"
  printf '%s\n' '.agents/agent-registry/' 'existing-entry' '.agents/agent-registry/' > "$REPO_ROOT/.gitignore"
  chmod "$expected_mode" "$REPO_ROOT/.gitignore"
  PATH="$FAKE_BIN:$PATH" FAKE_NPX_LOG="$NPM_LOG" "$SCRIPT_DIR/init.sh" --repo "$REPO_ROOT" >/dev/null

  [[ "$(file_mode "$REPO_ROOT/.gitignore")" == "$expected_mode" ]] || fail "existing .gitignore mode $expected_mode was not preserved"
  [[ "$(awk '$0 == ".agents/agent-registry/" { count += 1 } END { print count + 0 }' "$REPO_ROOT/.gitignore")" == '1' ]] || fail 'idempotent init did not deduplicate the registry ignore entry'
done
[[ "$(wc -l < "$NPM_LOG" | tr -d ' ')" == '2' ]] || fail 'idempotent init reinstalled existing dependencies'

printf 'test-init: PASS\n'
