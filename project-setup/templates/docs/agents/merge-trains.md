# Merge Pull Requests in Trains

A merge train is a branch, `train/YYYY-MM-DD`, that batches reviewed pull requests, so CI runs once on all of them together, on the train's pull request to `<<DEFAULT_BRANCH>>`, instead of once on each. A release follows each train ([decision](../product-decisions.md#batch-reviewed-pull-requests-in-merge-trains)).

Never push to `<<DEFAULT_BRANCH>>` or merge with `gh pr merge --admin`, unless the owner calls an emergency.

One train is open at a time: the newest `train/*` branch with no pull request to `<<DEFAULT_BRANCH>>` yet. Whoever merges pull requests cuts it, names it for the day they cut it, with `-2` for a second one that day, and tells authors its name.

## Open a Pull Request

- **Open it as a draft, based on the open train.** A pull request that builds on another is based on that one's branch. Once the lower one merges into a train, retarget it at the open train before it merges, or it merges into a branch nothing ships.
- **No CI runs on it.** Before every push, run the checks `AGENTS.md` lists under "Check your work", and report their results where you'd report CI's.
- **Merge the train into your branch, not `<<DEFAULT_BRANCH>>`**, to catch up or to settle a conflict.

## Merge Into a Train

- **Merge a pull request once its review is done** ([review.md](review.md)), with a merge commit: `gh pr merge <n> --merge --match-head-commit <sha>`.
- **Numbered files clash when branches meet.** When two pull requests in a train each add the next migration or ADR number, whoever merges second renumbers their own: merge the train in, move their migration or ADR to the next free number, fix every link to it, and push before merging. Renumber only what production never applied.
- **A migration that drops or renames** a table or column joins a later train than the code that stops using it, so the release still running works on the new schema.
- **A conflict in dated entries,** such as the decision register's, keeps both, the train's first.
- **A conflict in code** goes back to the author, who merges the train into their branch.
- **An issue counts as done for unblocking** once its pull request is in a train, though it stays open until the train reaches `<<DEFAULT_BRANCH>>`.

## Ship Features Whole

Production gets each train as it stands, so a train holds only whole features: whatever it shows a person, that person can use. A control ships in the same train as what it controls, or stays behind a flag that's off until the rest has shipped.

## Send a Train

1. **Freeze it:** open its pull request to `<<DEFAULT_BRANCH>>`, titled `Train YYYY-MM-DD: #a, #b, …`. List each pull request, and give a `Closes #n` line for each issue they close, since GitHub closes an issue only when its pull request merges into the default branch. Carry over every notice line from the pull requests it holds ([notices.md](notices.md)), when notices are on. Walk the train's features whole before you open it.
2. **Cut the next train** from the frozen train's head, and retarget each open pull request at it. Reviewed pull requests merge there from now on.
3. **When CI fails,** fix it on the frozen train with a commit that names the pull request it fixes, then merge the frozen train into the next train. Or take the pull request out: revert its merge on the frozen train, merge the frozen train into the next train, drop its `Closes` lines, and send it back to its author.
4. **Bring it up to date with `<<DEFAULT_BRANCH>>`** when that has moved, as after a hotfix: merge it into the train, renumbering the train's migrations after the hotfix's, which runs CI again.
5. **Merge it** once, after `git fetch origin`, `git merge-base --is-ancestor origin/<<DEFAULT_BRANCH>> origin/train/YYYY-MM-DD` succeeds and CI passed on the train's head. Merge with `gh pr merge <n> --merge --match-head-commit <sha>`, naming the head CI passed on, then release.
6. **Delete the train's branch** once `gh pr list --base train/YYYY-MM-DD` lists nothing. GitHub moves an open pull request whose base is deleted to the default branch.

## Hotfixes

A fix production needs before the next train goes straight to `<<DEFAULT_BRANCH>>` in a pull request of its own, so CI runs. Release it, then bring the frozen train, if one waits on CI, and the open train up to date, as step 4 says.
