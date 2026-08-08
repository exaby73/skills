---
name: luna-local-review-loop
description: Delegate local repository implementation, documentation, testing, validation, and review fixes to ephemeral GPT-5.6 Luna Max workers with least-privilege permission brokering, explicit task ownership, and repeated parent code-reviewer passes until local approval. Use when Codex must orchestrate multi-step local changes through subagents while keeping worker execution and validation evidence bounded.
---

# Luna Local Review Loop

Use this skill to coordinate local repository work through Luna Max workers and finish with an approved parent review.

## Set ownership

- Keep the parent responsible for the goal, decomposition, worker launch and collection, cross-worker decisions, permission brokerage, and final local review with `code-reviewer`.
- Delegate executable investigation, implementation, documentation, tests, validation, and review fixes to Luna Max workers; keep the parent as orchestrator and final reviewer.
- Define an explicit scope, owned paths, expected result, and validator for every worker task. Have the worker own the task, run the validator, and interpret its result; have the parent judge completion from the evidence.
- Require workers to leave staging and commits untouched. Workers must never stage or commit.

## Launch Luna Max

Run every executable task with this command shape, using safe quoting:

```zsh
codex exec \
  --ephemeral \
  -m 'gpt-5.6-luna' \
  -c 'model_reasoning_effort="max"' \
  -s '<least-privilege-sandbox>' \
  -C '/absolute/path/to/repository' \
  '<task>'
```

- Define least privilege as the minimum permission that still permits all required task actions: use read-only only for investigation, planning, or review tasks requiring no writes; use `workspace-write` for implementation, documentation, tests, or any other task that must modify repository files. Any broader access still goes through permission brokerage. Never use `danger-full-access` or bypass approvals.
- Stop if Luna Max cannot run. Ask the user to explicitly choose Luna High, Terra High, or no subagents; never silently change the model or reasoning effort.

## Orchestrate local work

1. Decompose the request into worker-sized tasks and attach a concrete validator to each task.
2. Launch workers only in the target repository. Run workers in parallel only when scopes are independent, owned paths do not overlap, and each worker has an explicit validator. Otherwise, run tasks sequentially and collect each result before starting dependent work.
3. Collect the worker’s changed-file summary, result, validator command and output, and any unresolved limitation. Treat a failed or unrun validator as unresolved work.
4. Invoke the parent `code-reviewer` skill against the complete local change and relevant repository context.
5. Turn every review finding into a fresh Luna Max worker task. Include the finding, evidence, exact owned scope, and validator; do not resolve the finding from the parent or silently fold it into another task.
6. Re-run the parent `code-reviewer` review after each finding’s fix and validation. Repeat the fresh-worker/fresh-review cycle until the parent review explicitly approves the local change.

## Broker blocked permissions

Require a non-interactive worker that cannot proceed to stop and return all four items:

```text
BLOCKED COMMAND: <exact command>
REASON: <why it is blocked>
EXPECTED SIDE EFFECTS: <what the command may change>
PERMISSION NEEDED: <specific permission>
```

- Review the exact command for safety, scope, and least privilege. If it is safe and in scope, run only that exact command through the parent approval path and return its output to the worker for interpretation.
- Do not substitute a command, broaden its scope, or ask the worker to work around the block. Stop and ask the user when the exact command is unsafe, out of scope, or its permission is ambiguous.
- Apply this brokerage to tests, containers, Docker, network access, external-file operations, and any other command requiring an approval unavailable to a non-interactive worker.

Keep the loop local, evidence-based, and bounded by the stated task scopes and validators.
