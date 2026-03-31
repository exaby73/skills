#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --repo <owner/repo> --pr <number> --input <review-payload.json>" >&2
  exit 1
}

repo=""
pr_number=""
input_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --pr) pr_number="$2"; shift 2 ;;
    --input) input_file="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$repo" && -n "$pr_number" && -n "$input_file" ]] || usage
[[ -f "$input_file" ]] || { echo "Missing input file: $input_file" >&2; exit 1; }

response="$(gh api --method POST "/repos/$repo/pulls/$pr_number/reviews" --input "$input_file")"
echo "$response"

if command -v jq >/dev/null; then
  echo "$response" | jq -r '.id as $id | .html_url as $url | "review_id=\($id)\nreview_url=\($url)"'
fi
