# Piece: Merge Trains

A merge train batches reviewed pull requests on one `train/YYYY-MM-DD` branch, so CI runs once, on the train's pull request to the default branch. It pays off when several agents ship in parallel and CI is slow enough that running it on every pull request queues them. One agent shipping one pull request at a time gains nothing from it.

## Recommend

Recommend trains when the repository has CI (`ci=github-actions`) and the owner expects several agents to open pull requests at once. Otherwise recommend off; the owner can turn them on later by running this skill again.

## Write

1. [merge-trains.md](../templates/docs/agents/merge-trains.md) into `docs/agents/`, with `<<DEFAULT_BRANCH>>` filled. When `migration_dirs` names a folder, add the repository's own command for a new migration to "Open a Pull Request".
2. The `trains` line of the AGENTS.md section "Review pull requests", and the register entry "Batch reviewed pull requests in merge trains".
3. In the plan, list what the owner changes outside the repository, for them to do or approve:
   - CI's workflow triggers on pull requests to the default branch only, plus `workflow_dispatch` for a run by hand;
   - a ruleset on the default branch that requires a pull request and CI passing on a branch up to date with it.

## Done

The doc is written and routed, and the report names the first train for whoever merges to cut: `train/<today>`.
