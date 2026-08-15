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

## Initialize without tracked-project mutation

Run once per repository or after runtime cleanup:

```sh
skill_root='/absolute/path/to/luna-local-review-loop'
repo_root='/absolute/path/to/repository'
"$skill_root/scripts/init.sh" --repo "$repo_root"
```

Init validates `codex`, `jq`, Git, every runner utility, project-local Caveman, and project-local code-reviewer. It stores the registry below `${LUNA_REGISTRY_ROOT:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/luna-local-review-loop-${UID}}` using a deterministic creation key. The selected state root must be owned by the current UID and grant no group or other permissions. First initialization creates one random, untracked `luna-local-review-loop.instance` marker inside the physical Git directory and atomically records the authoritative external registry path in `luna-local-review-loop.registry` beside it. Later operations follow that locator even when `--state-root`, `LUNA_REGISTRY_ROOT`, `XDG_RUNTIME_DIR`, or `TMPDIR` changes, so one checkout cannot silently create parallel registries. The instance marker combines with the Git directory's device/inode identity, and the registry retains that path-independent physical-checkout discriminator, so a moved checkout with a missing marker cannot silently create new state while workers remain live. Moving the same checkout otherwise preserves live workers and updates the stored canonical repository root, while a copied checkout replaces its copied locator and receives isolated state; a replacement repository cannot inherit old state. A linked worktree must also have a Git-admin backlink to its supplied checkout; copied linked-worktree aliases are rejected before registry selection. A live project-local schema-v1 registry blocks only first-time external-state creation; once valid external state exists, recovery access remains available even if legacy state reappears. Init never edits `.gitignore`, `skills-lock.json`, `.agents/skills`, or tracked project files, and never installs from the network. If a skill is missing, init prints explicit universal-target install commands; the parent decides whether to run them and reviews the resulting project changes.

## Route work

- Parent-direct only when clearly trivial: normally at most two minutes, one file, no meaningful external side effect, and cheaper than worker coordination.
- Use Luna Max for everything else. Luna is mandatory when work may touch three or more files or exceed five minutes. Bias toward Luna in the grey zone.
- Decompose independent tasks into non-overlapping owned paths, one expected result, one validator, one sandbox, and explicit exclusions. Each worker receives one task only and is retired at terminal state. Never reuse a worker for another task.
- Apply repository command gates before launch. Commands reserved for the parent, including elevated tests, stay parent-owned even if the worker sandbox could run them.

## Launch an atomic registered worker

Write the full task to a temporary prompt file outside the repository diff. Include task ID, immutable scope, owned paths, validator, repository rules, Caveman requirement, no-stage/no-commit rule, structured evidence expectations, and an explicit ban on daemonization, persistent background services, double-forking, or other deliberate lifecycle escape.

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

The launcher atomically reserves the task together with its initial invocation claim, starts a non-ephemeral handshake, captures the Codex session ID from JSONL even when the command exits immediately, binds and activates that session with the same invocation token, resumes it from the canonical target repository with prompt-file stdin and the registered sandbox reapplied, and writes streaming logs outside the project. It returns only the final structured result on stdout. A live invocation owner exclusively controls binding, activation, and retirement through its exact token; tokenless recovery is allowed only after that owner is confirmed exited.

Never add `--ephemeral` to a resumable worker. The durable identity is the Codex session ID (`01...`). A live `exec_command.session_id` integer is only a transient inner process-control handle. A `functions.exec` cell ID and a shell PID are neither worker identities nor accepted registry handles. The registry intentionally stores none of those process handles.

The launcher uses `--ignore-user-config` so unrelated MCP servers/connectors do not start. Add task-relevant context to the prompt or target repository configuration; do not re-enable the full user connector set merely for convenience.

The registry atomically claims each live invocation and pins its PID to a validated process-start identity, so PID reuse is treated as a stale claim. A stale claim may be replaced only while holding the registry mutation lock and only after the previous invocation's recorded descendant tracker exists, is clean, and retains no process identities whenever a child was recorded. Missing tracker evidence blocks reclaim and retirement. The lock owner and each Codex process-group leader are also pinned to process-start identities. Lock release/recovery compare the retained inode, so a contender cannot delete a newer owner; group recovery ignores a reused PGID unless its leader instance matches, while the descendant tracker remains the independent cleanup proof. Symlinked or non-regular locks are rejected. The runner resolves the validated Codex executable to an absolute path before changing directories and revalidates every launch utility before both launch and continuation claims. Every Codex launch runs in its own process group and waits behind a start gate until the ancestry tracker publishes readiness, then persists the PGID and leader identity before releasing the gate. A separate ancestry tracker records observed descendants, pins each PID to its process-start identity, and verifies each known parent instance before adopting its current children. Every worker and descendant also inherits a private FIFO lease, so a fast-reparented background process keeps cleanup active even when its intermediate parent disappeared between snapshots. Before publishing clean state, the tracker independently enumerates visible invocation-token processes. If the lease proves something remains live but the host cannot identify it safely, the runner refuses retirement and preserves recoverable active state. This blocks clearing or retirement while a recorded or lease-proven process instance remains live without allowing a reused parent PID to capture an unrelated process tree. This is cooperative local lifecycle safety, not an OS containment boundary: every worker prompt must forbid daemonization, persistent background services, double-forking, closing the lifecycle lease, and deliberate lifecycle escape. Put persistent services under parent-owned orchestration or an explicit container/cgroup boundary. Zombie members count as exited. Ambiguous access is handled conservatively as still live, requiring manual inspection instead of unsafe retirement. If the runner receives `INT` or `TERM`, it signals and drains the Codex group plus tracked descendants before token-checked registry retirement. Artifact directories and files must remain real, non-symlinked, single-link files below the external registry path; artifact attempts advance from the greatest existing numeric suffix, and stale symlink or hard-link targets are never overwritten. Never bypass these controls by deleting registry state manually.

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

Only retired `failed` or `interrupted` attempts permit exact-scope retry. The retry inherits its parent's stored sandbox when `--sandbox` is omitted; an explicit sandbox must match, so retry cannot escalate permissions. A failed attempt may have only one retry child, and no retry is permitted while another live worker owns that scope. If the child also fails, link the next retry to that child. The ledger keeps the complete linear retry chain.

## Judge evidence and review

Each structured worker result contains outcome, concise summary, changed files, validator commands/status/evidence, unresolved items, and any required parent action. `needs_parent_action` requires a non-empty parent action; terminal outcomes require `null`. Streaming JSONL and repeated diffs stay in the external artifact directory shown on stderr, with process warnings in separate stderr logs.

1. Collect all worker results and inspect the actual repository diff.
2. Run every parent-owned or still-required validator under repository rules. A missing or failed validator remains unresolved.
3. Invoke the parent `code-reviewer` skill over the complete change and applicable `AGENTS.md` guidance.
4. Route each real finding as a fresh one-task worker unless it independently qualifies as trivial parent-direct work.
5. Validate fixes and repeat parent review until explicitly approved.
6. The parent alone stages, commits, pushes, manages CI/PRs, replies to reviews, and resolves threads.

## Close every lifecycle

The runner atomically records and retires `completed` and `blocked` outcomes. `needs_parent_action` remains active until continued or explicitly finished. Explicit `finish` accepts only `failed`, `blocked`, or `interrupted`; `completed` requires both a validated structured result and the token-owning active runner. Finish is registry-only and remains available if worker artifacts are missing. Tokenless low-level retirement is rejected while the recorded invocation owner is live; only that owner may retire with its exact token. Dead-process probes run in the C locale, count zombies as exited, and block on ambiguous access. For a crash, cancellation, abandoned task, or goal shutdown, finish it explicitly:

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
Recovery and cleanup commands validate an existing external registry without requiring Codex or project skills, so launch-prerequisite damage cannot prevent retirement and assertions.
