# Luna Local Review Loop

This skill delegates bounded local repository tasks to fresh GPT-5.6 Luna Max sessions while keeping durable goals, validation judgment, review, and delivery parent-owned.

## Why the protocol exists

Workers must be resumable, isolated to one task, auditable after context compaction, and completely retired before a goal ends. The protocol therefore keeps an append-only identity ledger outside the repository and uses the Codex session ID as its only durable worker identity.

The launcher deliberately avoids several unreliable mechanisms:

- no `--ephemeral`, because resumable sessions need persisted rollout state;
- no orchestration/process handles in the registry, because fast commands may expose only an outer cell ID or no live handle at all;
- no PTY or manual EOF, because prompts are sent through ordinary file-backed stdin after activation;
- no full streaming transcript on stdout, because structured final output is separated from JSONL logs;
- no default user MCP startup, because `--ignore-user-config` disables unrelated connectors;
- no project-local registry or automatic skill installation, because runtime setup must not create unrelated repository changes.

## Requirements

- Bash 3 or newer, Git, `jq`, and the small POSIX/macOS utilities validated by `scripts/init.sh`.
- Codex CLI with `exec resume`, `--json`, `--output-schema`, `--output-last-message`, and `--ignore-user-config` support.
- Target repository project skills:
  - `.agents/skills/caveman/SKILL.md`
  - `.agents/skills/code-reviewer/SKILL.md`
- A writable Codex runtime-state directory, normally `$CODEX_HOME` or `~/.codex`, independent from the worker repository sandbox.

## Initialize

```sh
./luna-local-review-loop/scripts/init.sh --repo /absolute/path/to/repository
```

The deterministic registry path is:

```text
${LUNA_REGISTRY_ROOT:-${TMPDIR:-/tmp}/luna-local-review-loop}/<repository-checksum>/registry.json
```

Print it with:

```sh
./luna-local-review-loop/scripts/registry.sh path --repo /absolute/path/to/repository
```

Init is validation-only and idempotent. It physically resolves existing path components before normalizing missing suffixes, rejects repository-local state before creation, and rejects a symlinked repository-fingerprint directory before chmod or write. Each registry also records a durable identity derived from the physical Git directory. If a different repository later occupies the same path, init refuses to attach the old registry and tells the parent to recover it with the original checkout. It does not edit the target repository. When required project skills are missing, it prints the explicit universal-target install commands. Run those only as a separate, intentional project change.

Before creating external state for the first time, init checks the previous project-local schema-v1 registry path. If that registry still contains a reserved, bound, active, or stopping worker, init refuses to continue and prints recovery instructions. Recover and retire those workers with the previous skill version first; the new version never silently abandons live legacy state. Once a valid external registry exists, it remains authoritative and recovery commands continue to open it even if an old project-local registry later reappears.

## Registry schema

Schema version 2 has two arrays:

- `identity_ledger`: append-only lifetime history. Each row has immutable `task_id`, exact `scope`, immutable `sandbox`, optional `retry_of`, optional Codex `session_id`, lifecycle timestamps, and terminal evidence.
- `workers`: only reserved, bound, or active tasks. Atomic terminal completion removes the worker while retaining its ledger row.

Statuses are `reserved`, `bound`, `active`, and `retired`. A retired row has terminal status `completed`, `failed`, `blocked`, or `interrupted` plus evidence.

Scopes are permanently unique unless a new task explicitly uses `retry_of` to reference a retired failed/interrupted attempt with the exact same scope. A retry inherits the original sandbox when `--sandbox` is omitted and rejects an explicit mismatch, so recovery cannot escalate a read-only task to workspace-write. Each failed attempt accepts at most one retry child, retries form a linear chain, and a live scope owner blocks another retry. Task IDs and Codex session IDs are always globally unique within the repository ledger.

## Identity and handle contract

Three values may be visible during orchestration:

| Value | Example | Meaning | Registry use |
|---|---|---|---|
| Codex session/thread ID | `01a...` | Durable resumable worker identity | Stored and uniqueness-checked |
| Inner command process handle | `96558` | Transient handle returned by a live process tool | Never stored; only optional live process control |
| Outer tool cell ID | `1135` | Wrapper execution cell | Never accepted |

A shell PID is also never accepted. Because `run-worker.sh` waits for the short handshake and parses its JSONL file, fast completion does not lose the Codex session ID and does not require a live process handle.

## High-level lifecycle

Launch:

```sh
scripts/run-worker.sh launch \
  --repo /absolute/path/to/repository \
  --task-id issue-123-worker-1 \
  --scope 'owned paths: src/a.ts; task: implement validator; validator: pnpm check; sandbox: workspace-write; no commits' \
  --sandbox workspace-write \
  --prompt-file /absolute/path/to/task.txt
```

This single command performs:

1. atomically reserve immutable task/scope and claim the initial invocation;
2. non-ephemeral handshake with Luna Max;
3. extract and bind `thread.started.thread_id`;
4. activate exact task/session;
5. resume exact session using prompt-file stdin;
6. save JSONL stream and structured result outside the project;
7. either atomically complete-and-retire, atomically block-and-retire, or checkpoint `needs_parent_action`.

Continue after an approved parent action:

```sh
scripts/run-worker.sh continue \
  --repo /absolute/path/to/repository \
  --task-id issue-123-worker-1 \
  --prompt-file /absolute/path/to/parent-command-result.txt
```

Explicitly stop a non-terminal worker:

```sh
scripts/run-worker.sh finish \
  --repo /absolute/path/to/repository \
  --task-id issue-123-worker-1 \
  --status interrupted \
  --evidence 'parent terminated failed invocation'
```

Explicit finish accepts only `failed`, `blocked`, or `interrupted`; a completed task must come from a validated structured result. Because finish mutates only registry state, it remains usable when the worker never created artifacts or external artifacts were removed.

Retry a failed/interrupted exact scope:

```sh
scripts/run-worker.sh launch \
  --repo /absolute/path/to/repository \
  --task-id issue-123-worker-1-retry-1 \
  --scope 'the exact original scope' \
  --retry-of issue-123-worker-1 \
  --prompt-file /absolute/path/to/task.txt
```

## Structured result

`references/worker-result.schema.json` requires:

- `outcome`: `completed`, `blocked`, or `needs_parent_action`;
- `summary`: concise final result;
- `changedFiles`: changed path list;
- `validators`: command, passed/failed/not-run state, and evidence;
- `unresolved`: remaining limitations;
- `parentAction`: a non-empty exact action for `needs_parent_action`; `null` for terminal outcomes.

Only that JSON result is emitted on stdout. The external artifact directory printed on stderr contains the handshake JSONL, each resume JSONL, separate stderr logs, and each final result. Artifact roots and task directories are rejected when symlinked or resolved outside their real parent. A registry-backed invocation claim serializes the first resume, later continuations, and explicit retirement; continuation claims atomically require active state, and the initial claim is stored in the same mutation as reservation. Every Codex child waits behind a start gate until its PID is durable. Stale claims are reclaimed under the registry mutation lock only after that child PID is confirmed exited; zombies count as exited, while PID reuse or ambiguous process access blocks recovery rather than risking unsafe retirement. A successful reclaim clears the proven-dead child PID before the next invocation records its own child. Stale mutation locks are claimed with an in-directory recovery marker and atomically renamed aside so a contender cannot delete a new owner. Runner termination first signals and waits for whichever registry or Codex child is active, then retires the task using its invocation token. This prevents concurrent or orphaned registry transitions and session resumes while keeping long streams, repeated diffs, reconnect noise, or unrelated warnings from burying or corrupting the final report.

## Low-level registry commands

| Command | Purpose |
|---|---|
| `init` / `path` | Validate prerequisites and initialize/print external registry path |
| `reserve` | Append a fresh immutable task, optionally linked with `--retry-of` and an atomic initial invocation claim |
| `bind` | Bind one globally unique Codex session to one reserved task |
| `activate` | Activate the exact bound task/session |
| `checkpoint` | Save evidence while keeping a task active |
| `claim-invocation` / `release-invocation` | Atomically serialize one live runner per task, require active continuation state, and reclaim only a dead owner whose recorded child is gone |
| `record-child` / `clear-child` | Persist and clear the gated Codex child's PID |
| `complete-and-retire` | Atomically record terminal evidence and remove live worker entry |
| `query` / `active` | Read ledger task or live workers |
| `assert-no-active` / `assert-empty` | Prove no reserved, bound, or active workers remain |

Low-level commands exist for recovery and inspection. Tokenless retirement is allowed only when no invocation owns the task or the recorded owner is confirmed exited; a live owner must use its exact invocation token. Process probes force the stable C locale, treat zombies as exited, and remain conservative when access is ambiguous. Normal launches should use `run-worker.sh` so registry and process state transition together.

## Permission brokerage

Workers are non-interactive. When repository rules reserve a command for the parent or the worker lacks permission, return `needs_parent_action` with the exact command, reason, expected side effects, and permission needed. The parent checks scope and safety, performs only the authorized action, captures exit status/output, then uses `continue` for the same registered task.

Do not broaden the sandbox, replace the session, use `--last`, or start a new worker to continue the task. If the action is unsafe, ambiguous, or out of scope, retire the task as blocked or interrupted and ask the user.

## Cleanup invariant

Each session serves one task only. At goal completion or blocking, the parent terminates live invocations through supported orchestration, retires every remaining task with evidence, and runs:

```sh
scripts/registry.sh assert-no-active --repo /absolute/path/to/repository
scripts/registry.sh assert-empty --repo /absolute/path/to/repository
```

If either fails, the goal is not safely terminal. The external registry survives context compaction and can be located again from the repository path. It never kills processes or deletes Codex history.

## Validation

Run without network access:

```sh
./luna-local-review-loop/scripts/test-init.sh
```

The test covers non-mutating init, repository-instance binding, symlink-safe external state and artifact paths, first-creation legacy-registry refusal, external recovery when legacy state reappears, inverse ledger/worker consistency, external persistent state, conservative stale-process detection, stale mutation-lock contention, sandbox-preserving single-child retry chains, atomic initial reservation ownership, live-owner token enforcement, active-only continuation claims, a fast handshake with no invocation handle, portable artifact counting, stale-child clearing during atomic reclaim, serialized exact-session continuation without PTY/EOF, normal, zombie, and hard-kill child recovery, strict finish statuses, artifact-independent recovery, structured-output and stderr separation, disabled user MCP config, recovery without launch prerequisites, atomic retirement, and cleanup assertions.
