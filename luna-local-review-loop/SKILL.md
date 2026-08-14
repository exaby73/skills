---
name: luna-local-review-loop
description: Route local repository implementation, documentation, testing, validation, and review fixes between the parent and fresh GPT-5.6 Luna Max workers, using parent-owned durable goal and plan state, least-privilege permission brokerage, explicit one-task ownership, a persistent worker registry, and repeated parent code-reviewer passes until local approval. Use when Codex must decide whether local changes remain parent-direct or run through subagents while keeping worker execution and validation evidence bounded.
---

# Luna Local Review Loop

Use this skill to route local repository work between the parent and Luna Max, then finish with an approved parent review. Read [README.md](README.md) for the operator contract and use the bundled scripts as the registry source of truth.

The registry requires `activate` to receive the current handle and a latest
identity-ledger history entry with `kind: "resume"`; the launch handle and an
omitted handle are rejected. `init` rejects a symbolic-link `.gitignore`
instead of replacing it. Lock reclamation treats a failed `kill -0` as
ambiguous and removes a lock only after a confirmed-nonexistent PID probe.

## Identify the role

- Determine whether this invocation is the parent or a delegated worker before acting. Only the parent may decompose work, reserve or bind worker identities, launch, collect, retire, or coordinate workers, and only the parent runs the parent-owned review and delivery loop.
- A delegated worker executes its assigned task directly. It must never spawn, delegate to, or coordinate another worker. It skips parent-only routing, launch, orchestration, delivery, and review-monitor steps; it validates the exact scope and reports evidence to the parent.
- Both parent and delegated workers must read and use the target repository's project-local `.agents/skills/caveman/SKILL.md` for user-facing output before repository work. The parent ensures this dependency through `init`; each delegated worker verifies the same project-local path before acting. Never substitute a global or active-skills-root copy.

## Own durable state

- When the user request or repository rules require a goal, have the parent define or retrieve it. The parent owns and manages the durable goal and plan state, including scope, acceptance criteria, validators, evidence, status, completion, and blocking decisions. Workers may report evidence against that state, but never own durable goal or plan state. When no goal is requested or required, do not create one merely to delegate work.
- Keep the parent responsible for decomposition, worker launch and collection, cross-worker decisions, permission brokerage, and final local review with `code-reviewer`.
- Define an explicit scope, owned paths, expected result, and validator for every worker task. Have the worker execute the task, run the validator, interpret its result, and report the changed-file summary, result, validator command and output, and unresolved limitations; have the parent judge completion from that evidence.
- Require workers to leave staging and commits untouched. Workers must never stage or commit.

## Parent-owned delivery state

- The parent exclusively owns commits, pushes, CI collection and remediation, pull-request lifecycle, review replies and resolution, and review-monitor/automation management.
- Workers only report GitHub/CI evidence made available to them and never mutate delivery state. They do not perform delivery operations, manage CI, or change pull-request or review state.

## Route work (parent only)

- Let the parent execute directly only when the task is clearly trivial: expected to take no more than 2 minutes, normally touch no more than 1 file, have no meaningful external side effect or long validation, and cost less to do directly than to start and coordinate a worker. Examples include generating a commit message or making a single targeted file edit.
- Use Luna Max for everything else. Luna Max is mandatory when a task may touch 3 or more files or may exceed 5 minutes. In the grey zone, bias toward Luna.
- Treat the approximately 95% Luna / 5% parent-direct split as operating intent, not a quota. Parent-direct work still obeys repository rules and required validation.

## Launch Luna Max (parent only)

The worker identity is not known before `codex exec` starts. Reserve the task and exact scope first, launch a handshake that does no repository work, capture the emitted session ID and process/agent handle, and bind them exactly once. The handshake invocation then ends. Resume that exact session with stdin pending, record its fresh resume handle, activate with that current handle, and only then feed the reserved task prompt and EOF. A one-shot `codex exec` prompt cannot wait for a later parent message.

```zsh
skill_root='/absolute/path/to/luna-local-review-loop'
repo_root='/absolute/path/to/repository'
task_id='issue-123-worker-1'
task_sandbox='workspace-write' # use read-only for investigation, planning, or review; workspace-write for repository changes
readonly task_sandbox
task_scope="owned paths: src/a.ts; exact task: implement validator; sandbox: $task_sandbox; validator: pnpm check; no staging or commits"

"$skill_root/scripts/registry.sh" reserve \
  --repo "$repo_root" \
  --task-id "$task_id" \
  --scope "$task_scope"

launch_argv=(codex exec \
  -m 'gpt-5.6-luna' \
  -c 'model_reasoning_effort="max"' \
  -s "$task_sandbox" \
  -C "$repo_root" \
  'Handshake only. Do not read, write, test, or otherwise work in the repository. Reply exactly READY_TO_BIND, then stop so the parent can bind this session and resume it with the reserved task.')

# Start launch_argv through supported orchestration and let the handshake exit.
# Capture identifiers returned by Codex and the orchestration layer.
# Do not substitute a background-shell PID from $!.
captured_session_id='<session ID emitted by codex exec>'
launch_handle='<completed handshake process or agent handle returned by orchestration>'
"$skill_root/scripts/registry.sh" bind \
  --repo "$repo_root" \
  --task-id "$task_id" \
  --session-id "$captured_session_id" \
  --handle "$launch_handle"

# Through supported orchestration, start this exact argv with stdin pending:
# codex exec resume -m gpt-5.6-luna -c model_reasoning_effort=max "$captured_session_id" -
# Capture the fresh live process/agent handle before writing stdin.
captured_handle='<fresh resume process or agent handle returned by orchestration>'
"$skill_root/scripts/registry.sh" record-resume-handle \
  --repo "$repo_root" \
  --task-id "$task_id" \
  --session-id "$captured_session_id" \
  --handle "$captured_handle"
"$skill_root/scripts/registry.sh" activate \
  --repo "$repo_root" \
  --task-id "$task_id" \
  --session-id "$captured_session_id" \
  --handle "$captured_handle"

task_prompt="$(printf '%s\n' \
  "TASK ID: $task_id" \
  "RESERVED SCOPE: $task_scope" \
  'Execute only this reserved task. Read repository instructions and the project-local Caveman skill first. Report changed files, result, validator command/output, and limitations. Do not stage or commit.')"
# Only after activation succeeds, invoke the supported orchestration stdin-write
# operation for captured_handle with task_prompt, then close that stdin (EOF).
# Collect output until this exact resumed process exits.
```

Choose `task_sandbox` before reservation and the handshake, include it in the immutable task scope, and launch the session with that value. Same-session resume inherits the session sandbox; `codex exec resume` does not accept `-s`, so do not retry it with a sandbox override. Use the minimum sandbox that permits the scoped task: `read-only` for investigation, planning, or review tasks requiring no writes; `workspace-write` for implementation, documentation, tests, or other repository changes. The resumed worker prompt must release only the reserved one-task scope after activation. Never treat the handshake prompt as the task prompt. Any broader access still goes through permission brokerage. Never use a replacement identity, `--last`, or an unrecorded session. Stop if Luna Max cannot run and ask the user to choose Luna High, Terra High, or no subagents rather than silently changing the model or reasoning effort.

Every worker session is fresh and owns exactly one task. Once terminal, its session and handle are permanently retired; start later work or a new finding with a fresh task and fresh identity.

## Resume the same task after permission brokerage (parent only)

Same-session `codex exec resume` can return a new outer orchestration process or agent handle. Preserve the bound session and immutable task, but record each fresh handle before sending the approved command result:

```zsh
captured_session_id='<exact bound session ID>'

# Through supported orchestration, start this exact argv with stdin pending:
# codex exec resume -m gpt-5.6-luna -c model_reasoning_effort=max "$captured_session_id" -
# Capture the fresh process/agent handle returned by that orchestration.
# Do not substitute a background-shell PID from $!.
captured_handle='<fresh process or agent handle returned by orchestration>'

"$skill_root/scripts/registry.sh" record-resume-handle \
  --repo "$repo_root" \
  --task-id "$task_id" \
  --session-id "$captured_session_id" \
  --handle "$captured_handle"

# Only after record-resume-handle succeeds, feed the exact approved command,
# exit status, and captured output to the still-pending stdin.
```

Use `record-resume-handle` only for the exact task ID and exact bound session ID, with the globally unused process/agent handle returned by supported orchestration. A shell PID is not an orchestration handle. Never use `--last`, a replacement session, or a different model. After recording, pass the current handle to later `update` and `retire`; old handles must fail exact validation. Handle history remains in the append-only identity ledger after worker pruning.

## Orchestrate work and close the loop (parent only)

Before reserve or worker execution, read the applicable repository instructions, including `AGENTS.md` and any local instruction files. Hand off every command class those instructions reserve for the parent or require elevated execution. Apply this gate even when the worker sandbox would allow the command: if a repository requires every pnpm test command to run elevated, including `pnpm test` and `pnpm run test:*`, the parent owns and runs all of those tests through the required elevated path and the worker must not run them.

1. Decompose the request into worker-sized tasks and attach a concrete validator to each task.
2. Apply the repository-instruction gate, reserve the exact scope, and launch only after the reserve succeeds. Run independent workers in parallel only when their scopes are independent, owned paths do not overlap, and each has an explicit validator. Otherwise, run tasks sequentially and collect each result before starting dependent work.
3. Bind the handshake session ID and launch handle exactly once. Resume that exact session with stdin pending, record the fresh resume handle, activate with that handle, and then feed the exact reserved task and EOF. Collect the worker’s changed-file summary, result, validator command and output, and any unresolved limitation. Treat a failed or unrun validator as unresolved work.
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
- Do not substitute a command, broaden permissions, or ask the worker to work around the block. Stop and ask the user when the exact command is unsafe, out of scope, or its permission is ambiguous.
- Apply this brokerage to tests, containers, Docker, network access, external-file operations, and any other command requiring an approval unavailable to a non-interactive worker.
- After the parent runs the exact approved command, use the resume handshake above. Start the exact same session with stdin pending, capture the new outer handle, record it, then feed the captured result so the same worker can interpret it and continue that same task:

  ```zsh
  codex exec resume -m gpt-5.6-luna -c model_reasoning_effort=max '<captured-session-id>' -
  ```

  Keep stdin pending until `record-resume-handle` succeeds. Then feed the exact command, exit status, and captured output. Use the captured session ID and newly recorded current handle, not `--last`, a new worker, or a different model; this continuation is only for the same task and exact scope. If the repository instruction gate requires an elevated pnpm test, the parent runs that exact command and returns its result before resuming.

## Close every worker lifecycle

Before the parent marks a goal complete or blocked, it must collect evidence, interrupt or terminate real workers only through supported orchestration, wait for shutdown, record terminal state and evidence with `registry.sh update` using the current handle, permanently retire every exact bound session with `registry.sh retire` using the current handle, prune terminal entries with `registry.sh prune`/`clear`, and run both `assert-no-active` and `assert-empty`. A reserved launch that never bound an identity is retired by task ID with launch-failure evidence. If cleanup cannot be completed, the goal is not complete or safely blocked; report the concrete blocker and preserve the registry for recovery. The registry never kills arbitrary processes and never deletes Codex history.

Keep the loop local, evidence-based, and bounded by the stated task scopes and validators.
