#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --commit-id <sha> --event <REQUEST_CHANGES|COMMENT|APPROVE> --body-file <path> --comments-file <path> --output <path>" >&2
  exit 1
}

commit_id=""
event=""
body_file=""
comments_file=""
output_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit-id) commit_id="$2"; shift 2 ;;
    --event) event="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    --comments-file) comments_file="$2"; shift 2 ;;
    --output) output_file="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$commit_id" && -n "$event" && -n "$body_file" && -n "$comments_file" && -n "$output_file" ]] || usage
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

[[ -f "$body_file" ]] || { echo "Missing body file: $body_file" >&2; exit 1; }
[[ -f "$comments_file" ]] || { echo "Missing comments file: $comments_file" >&2; exit 1; }

body_content="$(cat "$body_file")"

jq -e 'if type=="array" then . else error("comments file must be a JSON array") end' "$comments_file" >/dev/null

jq -n \
  --arg commit_id "$commit_id" \
  --arg event "$event" \
  --arg body "$body_content" \
  --slurpfile comments "$comments_file" \
  '{commit_id:$commit_id,event:$event,body:$body,comments:($comments[0] // [])}' \
  > "$output_file"

echo "$output_file"
