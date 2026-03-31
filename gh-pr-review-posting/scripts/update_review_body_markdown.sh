#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --review-node-id <PRR_...> --body-file <path>" >&2
  exit 1
}

review_node_id=""
body_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --review-node-id) review_node_id="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$review_node_id" && -n "$body_file" ]] || usage
[[ -f "$body_file" ]] || { echo "Missing body file: $body_file" >&2; exit 1; }

body="$(cat "$body_file")"

gh api graphql \
  -f query='mutation($id:ID!, $body:String!) { updatePullRequestReview(input:{pullRequestReviewId:$id, body:$body}) { pullRequestReview { id body url } } }' \
  -f id="$review_node_id" \
  -f body="$body"
