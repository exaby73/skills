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

Init is validation-only and idempotent. It does not edit the target repository. When required project skills are missing, it prints the explicit universal-target install commands. Run those only as a separate, intentional project change.

Before creating external state, init checks the previous project-local schema-v1 registry path. If that registry still contains a reserved, bound, active, or stopping worker, init refuses to continue and prints recovery instructions. Recover and retire those workers with the previous skill version first; the new version never silently abandons live legacy state.

## Registry schema

Schema version 2 has two arrays:

- `identity_ledger`: append-only lifetime history. Each row has immutable `task_id`, exact `scope`, optional `retry_of`, optional Codex `session_id`, lifecycle timestamps, and terminal evidence.
- `workers`: only reserved, bound, or active tasks. Atomic terminal completion removes the worker while retaining its ledger row.

Statuses are `reserved`, `bound`, `active`, and `retired`. A retired row has terminal status `completed`, `failed`, `blocked`, or `interrupted` plus evidence.

Scopes are permanently unique unless a new task explicitly uses `retry_of` to reference a retired failed/interrupted attempt with the exact same scope. Each failed attempt accepts at most one retry child, retries form a linear chain, and a live scope owner blocks another retry. Task IDs and Codex session IDs are always globally unique within the repository ledger.

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

1. reserve immutable task and scope;
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

Only that JSON result is emitted on stdout. The external artifact directory printed on stderr contains the handshake JSONL, each resume JSONL, separate stderr logs, and each final result. A registry-backed invocation claim serializes the first resume, later continuations, and explicit retirement; stale claims are reclaimed under the registry's atomic mutation lock. Runner termination first signals and waits for its Codex child, then retires the task and releases ownership. This prevents concurrent or orphaned session resumes and keeps long streams, repeated diffs, reconnect noise, or unrelated warnings from burying or corrupting the final report.

## Low-level registry commands

| Command | Purpose |
|---|---|
| `init` / `path` | Validate prerequisites and initialize/print external registry path |
| `reserve` | Append a fresh immutable task, optionally linked with `--retry-of` |
| `bind` | Bind one globally unique Codex session to one reserved task |
| `activate` | Activate the exact bound task/session |
| `checkpoint` | Save evidence while keeping a task active |
| `claim-invocation` / `release-invocation` | Atomically serialize one live runner per task and reclaim a dead owner |
| `complete-and-retire` | Atomically record terminal evidence and remove live worker entry |
| `query` / `active` | Read ledger task or live workers |
| `assert-no-active` / `assert-empty` | Prove no reserved, bound, or active workers remain |

Low-level commands exist for recovery and inspection. Normal launches should use `run-worker.sh` so registry and process state transition together.

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

The test covers non-mutating init, live legacy-registry refusal, external persistent state, single-child retry chains, a fast handshake with no invocation handle, portable artifact counting, atomic stale-claim recovery, serialized exact-session continuation without PTY/EOF, child termination before retirement, strict structured-output and stderr separation, disabled user MCP config, recovery without launch prerequisites, atomic retirement, and cleanup assertions.
