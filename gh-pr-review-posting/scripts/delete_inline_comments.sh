#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --repo <owner/repo> (--ids 1,2,3 | --ids-file /tmp/comment-ids.txt)" >&2
  exit 1
}

repo=""
ids_csv=""
ids_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --ids) ids_csv="$2"; shift 2 ;;
    --ids-file) ids_file="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$repo" ]] || usage
[[ -n "$ids_csv" || -n "$ids_file" ]] || usage

if [[ -n "$ids_file" ]]; then
  [[ -f "$ids_file" ]] || { echo "Missing ids file: $ids_file" >&2; exit 1; }
  mapfile -t ids < <(grep -Eo '[0-9]+' "$ids_file")
else
  IFS=',' read -r -a ids <<< "$ids_csv"
fi

for id in "${ids[@]}"; do
  [[ -n "$id" ]] || continue
  gh api --method DELETE "/repos/$repo/pulls/comments/$id" >/dev/null
  echo "deleted $id"
done
