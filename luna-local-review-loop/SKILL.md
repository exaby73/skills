---
name: luna-local-review-loop
description: Route local repository implementation, documentation, testing, validation, and review fixes between a parent and fresh GPT-5.6 Luna Max workers. Use for non-trivial local work requiring one-task worker isolation, resumable registered sessions, least-privilege permission brokerage, structured results, mandatory cleanup, and parent-owned code review and delivery.
---

# Luna Local Review Loop

Route local work to fresh Luna Max workers, then have the parent validate and review the combined result. Read [README.md](README.md) before first use. Treat the bundled scripts as the worker-registry source of truth.

## Identify the role

- The parent owns decomposition, launch, permissions, durable goals/plans, validation judgment, review, commits, delivery, CI, and GitHub state.
- A worker owns exactly one immutable task. It never delegates, stages, commits, pushes, reviews the combined change, or manages GitHub/CI state.
- Both roles read the target repository's `AGENTS.md` hierarchy and project-local `.agents/skills/caveman/SKILL.md` before work. Both use Caveman for user-facing output. Never substitute a global Caveman copy.
- The parent alone invokes the project-local `code-reviewer` skill. Never delegate parent review to Luna. Obey any project rule that fixes the parent reviewer model/reasoning configuration.

## Initialize without repository mutation

Run once per repository or after runtime cleanup:

```sh
skill_root='/absolute/path/to/luna-local-review-loop'
repo_root='/absolute/path/to/repository'
"$skill_root/scripts/init.sh" --repo "$repo_root"
```

Init validates `codex`, `jq`, Git, project-local Caveman, and project-local code-reviewer. It stores the registry below `${LUNA_REGISTRY_ROOT:-${TMPDIR:-/tmp}/luna-local-review-loop}` using a deterministic repository key. It never edits `.gitignore`, `skills-lock.json`, `.agents/skills`, or another repository file, and never installs from the network. If a skill is missing, init prints explicit universal-target install commands; the parent decides whether to run them and reviews the resulting project changes.

## Route work

- Parent-direct only when clearly trivial: normally at most two minutes, one file, no meaningful external side effect, and cheaper than worker coordination.
- Use Luna Max for everything else. Luna is mandatory when work may touch three or more files or exceed five minutes. Bias toward Luna in the grey zone.
- Decompose independent tasks into non-overlapping owned paths, one expected result, one validator, one sandbox, and explicit exclusions. Each worker receives one task only and is retired at terminal state. Never reuse a worker for another task.
- Apply repository command gates before launch. Commands reserved for the parent, including elevated tests, stay parent-owned even if the worker sandbox could run them.

## Launch an atomic registered worker

Write the full task to a temporary prompt file outside the repository diff. Include task ID, immutable scope, owned paths, validator, repository rules, Caveman requirement, no-stage/no-commit rule, and structured evidence expectations.

```sh
task_id='issue-123-validator'
task_scope='owned paths: src/a.ts; task: implement validator; validator: pnpm check; sandbox: workspace-write; no staging or commits'

"$skill_root/scripts/run-worker.sh" launch \
  --repo "$repo_root" \
  --task-id "$task_id" \
  --scope "$task_scope" \
  --sandbox workspace-write \
  --prompt-file '/absolute/path/to/task-prompt.txt'
```

The launcher atomically reserves the task, starts a non-ephemeral handshake, captures the Codex session ID from JSONL even when the command exits immediately, binds and activates that session, resumes it with prompt-file stdin, and writes streaming logs outside the project. It returns only the final structured result on stdout.

Never add `--ephemeral` to a resumable worker. The durable identity is the Codex session ID (`01...`). A live `exec_command.session_id` integer is only a transient inner process-control handle. A `functions.exec` cell ID and a shell PID are neither worker identities nor accepted registry handles. The registry intentionally stores none of those process handles.

The launcher uses `--ignore-user-config` so unrelated MCP servers/connectors do not start. Add task-relevant context to the prompt or target repository configuration; do not re-enable the full user connector set merely for convenience.

Use `read-only` for investigation/review and `workspace-write` for implementation. The parent shell must separately allow the owning Codex runtime-state directory (normally `$CODEX_HOME` or `~/.codex`) to be written. This runtime permission is distinct from the worker repository sandbox. If the launcher reports exit 11, stop and obtain that narrow outer permission; never broaden the repository sandbox as a workaround.

## Continue the exact task after parent action

If the structured result is `needs_parent_action`, the registry keeps that task active. The parent reviews and, if safe and authorized, performs only the exact requested action. Put the command, exit status, and captured output in a new temporary prompt file, then resume the exact registered session:

```sh
"$skill_root/scripts/run-worker.sh" continue \
  --repo "$repo_root" \
  --task-id "$task_id" \
  --prompt-file '/absolute/path/to/parent-result.txt'
```

No PTY, manual EOF, `--last`, replacement session, or process handle is used. Continue may only resume an active registered task. Repeat only for the same immutable scope.

If a launch failed or was interrupted, retire it with evidence, then retry the exact scope using a fresh task ID linked to the failed attempt:

```sh
"$skill_root/scripts/run-worker.sh" launch \
  --repo "$repo_root" \
  --task-id 'issue-123-validator-retry-1' \
  --scope "$task_scope" \
  --retry-of "$task_id" \
  --prompt-file '/absolute/path/to/task-prompt.txt'
```

Only retired `failed` or `interrupted` attempts permit exact-scope retry. The ledger keeps both identities and their link.

## Judge evidence and review

Each structured worker result contains outcome, concise summary, changed files, validator commands/status/evidence, unresolved items, and any required parent action. Streaming JSONL and repeated diffs stay in the external artifact directory shown on stderr.

1. Collect all worker results and inspect the actual repository diff.
2. Run every parent-owned or still-required validator under repository rules. A missing or failed validator remains unresolved.
3. Invoke the parent `code-reviewer` skill over the complete change and applicable `AGENTS.md` guidance.
4. Route each real finding as a fresh one-task worker unless it independently qualifies as trivial parent-direct work.
5. Validate fixes and repeat parent review until explicitly approved.
6. The parent alone stages, commits, pushes, manages CI/PRs, replies to reviews, and resolves threads.

## Close every lifecycle

The runner atomically records and retires `completed` and `blocked` outcomes. `needs_parent_action` remains active until continued or explicitly finished. For a crash, cancellation, abandoned task, or goal shutdown, finish it explicitly:

```sh
"$skill_root/scripts/run-worker.sh" finish \
  --repo "$repo_root" \
  --task-id "$task_id" \
  --status interrupted \
  --evidence 'parent stopped the task after process failure'
```

Before completing or blocking any parent goal, terminate any real live invocation through supported orchestration, retire every reserved/bound/active registry entry with evidence, then run both checks:

```sh
"$skill_root/scripts/registry.sh" assert-no-active --repo "$repo_root"
"$skill_root/scripts/registry.sh" assert-empty --repo "$repo_root"
```

If cleanup cannot be proven, the parent goal is not safely terminal. Preserve the external registry/artifacts and report the blocker. The registry never kills arbitrary processes and never deletes Codex history.
