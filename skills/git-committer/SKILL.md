---
name: git-committer
description: Generates conventional one line commit messages from a git diff
---

# Generating a git commit message

## Instructions

1. Run `git diff` and `git diff --staged` to get the diff of current changes
1. If there are staged files, generate commit message suggestions using only `git diff --staged` changes (ignore unstaged changes)
1. For more context, get the last 5 to 10 commit messages as well
1. Suggest a commit message:
    - The commit message should be a single line
    - The commit message should be a summary of the changes
    - The commit message should follow conventional commit conventions
    - If there too many changes, suggest multiple commit messages with a split of files between each commit message

## Best practices

1. Use present tense
1. After the tag (e.g. `feat:`), the first letter should be capitalized, unless it's a symbol like a function name
