<!-- project-setup template: the section to add to .cadre/guidelines.md, through
cadre:create on a new Cadre project or cadre:refresh on an existing one. Never
write it into .cadre/ directly. Delete this comment. -->
### Delivering through Cadre

- Start a phase that runs in the project's own checkout with no `worktreePath` or `branch`. Cadre reads a checkout named that way as a worktree the phase owns, and refuses every quick and revise in the repository until the track completes.
- Record a track's clean review in Cadre in the pull request that merges it. A track merged while still `ready_for_review` keeps its journal holding the checkout, blocks quicks, and can't be archived.
- After a track or quick merges, delete its local branch with `git branch -d`, which refuses a branch that isn't merged. Cadre treats a node whose recorded branch still exists locally as live work, and refuses quicks while it does.
- Compute each handoff source's SHA-256 from the file before you checkpoint, and never record a placeholder hash. A placeholder poisons the learning that later tracks inherit.
- Keep `.cadre/` out of every formatter and pre-commit hook, such as `.prettierignore`: Cadre's receipts check the bytes of its files.
- Before you merge a stacked pull request, check its base. Once the pull request under it has merged, retarget it at the branch that ships, or it merges into a branch nothing ships.
