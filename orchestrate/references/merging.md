# Merging and Git Hygiene

## Merge Checks

Run every check, after `git fetch origin`, before each merge. A failed check stops the merge until it's fixed or the owner decides.

1. **The base is right:** `gh pr view <n> --json baseRefName` names the open train, or the default branch for a hotfix or a train. A stacked pull request whose lower one has merged is retargeted first, or it merges into a branch nothing ships.
2. **It holds its target:** the branch contains the base it merges into, `git merge-base --is-ancestor origin/<base> origin/<branch>`. A train's pull request contains all of the default branch.
3. **No file is deleted** that the spec doesn't remove: `git diff --diff-filter=D --name-only origin/<base>...origin/<branch>` lists nothing unexpected.
4. **It merges clean:** `git merge-tree --write-tree origin/<base> origin/<branch>` exits 0.
5. **Numbers are unique:** in that merged tree, no two migrations and no two ADRs share a number. Whoever merges second renumbers their own.
6. **Only Cadre bookkeeping follows the review:** every commit after the reviewed head touches only `.cadre/`, apart from the Low fixes you diffed. Anything else needs a review round.
7. **The reviewed head is the merged head:** merge with `gh pr merge <n> --merge --match-head-commit <SHA>`, naming the head the review covered, plus only the Low fixes.

## Git Hygiene

- Stage named paths only: `git add <path> ...`.
- Push over HTTPS with `gh`'s credentials when SSH fails: run `gh auth setup-git`, then push to the `https://github.com/<owner>/<repo>.git` URL.
- Push to feature and train branches only, never to the default branch.
- Merge without `--admin`, unless the owner calls an emergency.
- After a branch merges, delete it locally with `git branch -d`, which refuses a branch that isn't merged.
