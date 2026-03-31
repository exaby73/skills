#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --repo <owner/repo> --input <json-file>" >&2
  echo "Input shape: [{\"id\":123,\"body\":\"Markdown\"}]" >&2
  exit 1
}

repo=""
input_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --input) input_file="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$repo" && -n "$input_file" ]] || usage
[[ -f "$input_file" ]] || { echo "Missing input file: $input_file" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

jq -c '.[]' "$input_file" | while IFS= read -r row; do
  id="$(jq -r '.id' <<< "$row")"
  body="$(jq -r '.body' <<< "$row")"
  tmp="$(mktemp /tmp/inline-comment-update-XXXX.json)"
  jq -n --arg body "$body" '{body:$body}' > "$tmp"
  gh api --method PATCH "/repos/$repo/pulls/comments/$id" --input "$tmp" >/dev/null
  rm -f "$tmp"
  echo "updated $id"
done
