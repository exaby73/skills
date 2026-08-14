---
name: luna-local-review-loop
description: Route local repository implementation, documentation, testing, validation, and review fixes between the parent and GPT-5.6 Luna Max workers, using parent-owned durable goal and plan state, least-privilege permission brokering, explicit task ownership, and repeated parent code-reviewer passes until local approval. Use when Codex must decide whether local changes remain parent-direct or run through subagents while keeping worker execution and validation evidence bounded.
---

# Luna Local Review Loop

Use this skill to route local repository work between the parent and Luna Max, then finish with an approved parent review. Require latest-head CI success only when remote delivery/CI applies, and before pull-request readiness.

## Identify the role

- Determine whether this invocation is the parent or a delegated worker before acting. Only the parent may decompose work, launch, collect, retire, or coordinate workers, and only the parent runs the parent-owned review and delivery loop.
- A delegated worker executes its assigned task directly. It must never spawn, delegate to, or coordinate subagents or nested workers. It skips parent-only routing, launch, orchestration, delivery, and review-monitor steps; it validates its assigned scope and reports evidence to the parent.

## Own durable state

- When the user request or repository rules require a goal, have the parent define or retrieve it. The parent owns and manages the durable goal and plan state, including scope, acceptance criteria, validators, evidence, status, completion, and blocking decisions. Workers may report evidence against that state, but never own durable goal or plan state. When no goal is requested or required, do not create one merely to delegate work.
- Keep the parent responsible for decomposition, worker launch and collection, cross-worker decisions, permission brokerage, and final local review with `code-reviewer`.
- Define an explicit scope, owned paths, expected result, and validator for every worker task. Have the worker execute the task, run the validator, interpret its result, and report the changed-file summary, result, validator command and output, and unresolved limitations; have the parent judge completion from the evidence.
- Require workers to leave staging and commits untouched. Workers must never stage or commit.

## Parent-owned delivery state

- The parent exclusively owns commits, pushes, CI collection and remediation, pull-request lifecycle, review replies and resolution, and review-monitor/automation management.
- Workers only report GitHub/CI evidence made available to them and never mutate delivery state. They do not perform delivery operations, manage CI, or change pull-request or review state.

## Route work (parent only)

- Let the parent execute directly only when the task is clearly trivial: expected to take no more than 2 minutes, normally touch no more than 1 file, have no meaningful external side effects or long validation, and cost less to do directly than to start and coordinate a worker. Examples include generating a commit message or making a single targeted file edit.
- Use Luna Max for everything else. Luna Max is mandatory when a task may touch 3 or more files or may exceed 5 minutes. In the grey zone, bias toward Luna.
- Treat the approximately 95% Luna / 5% parent-direct split as operating intent, not a quota. Parent-direct work still obeys repository rules and required validation.

## Launch Luna Max (parent only)

Run every executable task routed to Luna Max with this command shape, using safe quoting. Preserve the fresh worker session only so the parent can resume that same task when permission brokerage is needed:

```zsh
codex exec \
  -m 'gpt-5.6-luna' \
  -c 'model_reasoning_effort="max"' \
  -s '<least-privilege-sandbox>' \
  -C '/absolute/path/to/repository' \
  '<task>'
```

- Capture the session ID reported by `codex exec` and retain it with the worker task. The parent must use that exact session for every continuation of that same task; never use `--last` or launch a replacement worker to return brokered output.
- Define least privilege as the minimum permission that still permits all required task actions: use read-only only for investigation, planning, or review tasks requiring no writes; use `workspace-write` for implementation, documentation, tests, or any other task that must modify repository files. Any broader access still goes through permission brokerage. Never use `danger-full-access` or bypass approvals.
- Stop if Luna Max cannot run. Ask the user to explicitly choose Luna High, Terra High, or no subagents; never silently change the model or reasoning effort.

## Enforce worker lifecycle (parent only)

- Create every worker session fresh for exactly one explicitly scoped task. Before work starts, record its task, worker or session ID, process or agent handle, and state in a parent-owned active-worker registry. Never reuse or reassign a worker or session, and never resume it for another task or finding. Resumption is allowed only to continue that same task, including returning output from an exact command the parent ran through blocked-command permission brokerage. Once that task reaches a terminal result, retire its session permanently; start later work or a new finding in a fresh worker session.
- Before marking any goal complete or blocked, or whenever a goal otherwise ends, collect final evidence from every worker, interrupt or terminate every still-running worker, wait for shutdown, retire every session ID, clear the active-worker registry, and verify that no worker remains active. Retiring a session means marking its ID unusable for future work; do not invent destructive deletion of persisted Codex history when the CLI lacks supported deletion.

## Orchestrate work and close the loop (parent only)

Before worker execution, read the applicable repository instructions and hand off every command class they reserve for the parent or require elevated execution. Apply this gate even when the worker sandbox would allow the command: for example, if repository rules require every pnpm test command to run elevated, including `pnpm test` and `pnpm run test:*`, the parent must own and run those tests through the required elevated path and the worker must not run them.

1. Decompose the request into worker-sized tasks and attach a concrete validator to each task.
2. Apply the routing gate to each task before execution. Launch Luna workers only in the target repository. Run workers in parallel only when scopes are independent, owned paths do not overlap, and each worker has an explicit validator. Otherwise, run tasks sequentially and collect each result before starting dependent work.
3. Collect the worker’s changed-file summary, result, validator command and output, and any unresolved limitation. Treat a failed or unrun validator as unresolved work.
4. Invoke the parent `code-reviewer` skill against the complete local change and relevant repository context.
5. Route every local review finding and remote CI failure through the same threshold. After a push, the parent watches and collects CI evidence, then routes each failure and its fix as a fresh Luna Max task; let the parent handle it directly only when it independently qualifies as a clearly trivial parent-direct task. Include the finding or failure evidence, exact owned scope, and validator; do not silently fold a worker-routed issue into another task.
6. Re-run the parent `code-reviewer` review after each finding or CI failure fix and validation. Repeat the routed-fix/review cycle until the parent review explicitly approves the local change. When remote delivery/CI applies, re-check CI on the latest head after fixes and require success before reporting pull-request readiness.

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
- After the parent runs the exact approved command, resume the recorded worker session with its captured result so the same worker can interpret it and continue that same task:

  ```zsh
  codex exec resume '<captured-worker-session-id>' -
  ```

  Feed the resumed prompt the exact command, exit status, and captured output. Use the captured session ID, not `--last` or a new worker; this continuation is only for that same task.

Keep the loop local, evidence-based, and bounded by the stated task scopes and validators.
