#!/usr/bin/env bash
set -euo pipefail

format="md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format|--ext)
      shift
      if [[ $# -eq 0 ]]; then
        echo "missing value for --format/--ext" >&2
        exit 1
      fi
      format="$1"
      ;;
    *)
      echo "unsupported argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

normalize_format() {
  local raw="$1"
  raw="${raw#.}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "$raw" | tr -cd 'a-z0-9')"
  case "$raw" in
    ""|markdown|md) echo "md" ;;
    text|plain|txt) echo "txt" ;;
    yaml|yml) echo "yml" ;;
    bash|shell|sh) echo "sh" ;;
    json|html|xml|csv|sql|toml|ini|rst|tex) echo "$raw" ;;
    *) echo "$raw" ;;
  esac
}

copy_to_clipboard() {
  local file_path="$1"
  if command -v pbcopy >/dev/null 2>&1; then
    cat "$file_path" | pbcopy
    return 0
  fi
  if command -v wl-copy >/dev/null 2>&1; then
    cat "$file_path" | wl-copy
    return 0
  fi
  if command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard < "$file_path"
    return 0
  fi
  if command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input < "$file_path"
    return 0
  fi
  if command -v clip.exe >/dev/null 2>&1; then
    cat "$file_path" | clip.exe
    return 0
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    < "$file_path" powershell.exe -NoProfile -Command "Set-Clipboard -Value ([Console]::In.ReadToEnd())"
    return 0
  fi
  return 1
}

if [[ -t 0 ]]; then
  echo "expected input text on stdin" >&2
  exit 1
fi

ext="$(normalize_format "$format")"
tmp_base="$(mktemp "/tmp/codex-output-XXXXXX")"
tmp_file="${tmp_base}.${ext}"
mv "$tmp_base" "$tmp_file"
cat > "$tmp_file"

if ! copy_to_clipboard "$tmp_file"; then
  echo "warning: clipboard command not found; file was created but not copied" >&2
fi

echo "$tmp_file"
