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
- no project-local registry or automatic skill installation, because runtime setup must not create unrelated tracked-project changes.

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

The initial deterministic registry path is:

```text
${LUNA_REGISTRY_ROOT:-${TMPDIR:-/tmp}/luna-local-review-loop}/<repository-checksum>/registry.json
```

Print it with:

```sh
./luna-local-review-loop/scripts/registry.sh path --repo /absolute/path/to/repository
```

Init is idempotent and does not edit tracked project files. It physically resolves existing path components before normalizing missing suffixes, rejects repository-local state before creation, and rejects a symlinked repository-fingerprint directory before chmod or write. On first initialization it creates one random, untracked `luna-local-review-loop.instance` marker inside the physical Git directory and combines it with that directory's device/inode identity. The registry separately stores that path-independent physical-checkout identity, allowing init to find and protect live state even when the checkout moved and its marker is missing. Later lookups scan the state root for the full marked identity, so moving the same checkout reuses its registry and updates the stored canonical root even though the directory retains its original creation checksum. A copied checkout receives a different physical Git-directory identity, and a replacement repository receives a different marker, so neither can attach to the original sessions. Linked worktrees additionally verify that their Git-admin backlink names the supplied checkout, which rejects a copied linked-worktree alias before it can reuse or rewrite live state. When required project skills are missing, init prints the explicit universal-target install commands. Run those only as a separate, intentional project change.

Before creating external state for the first time, init checks the previous project-local schema-v1 registry path. If that registry still contains a reserved, bound, active, or stopping worker, init refuses to continue and prints recovery instructions. Recover and retire those workers with the previous skill version first; the new version never silently abandons live legacy state. Once a valid external registry exists, it remains authoritative and recovery commands continue to open it even if an old project-local registry later reappears.

## Registry schema

Schema version 3 has two arrays:

- `identity_ledger`: append-only lifetime history. Each row has immutable `task_id`, exact `scope`, immutable `sandbox`, optional `retry_of`, optional Codex `session_id`, lifecycle timestamps, and terminal evidence.
- `workers`: only reserved, bound, or active tasks. A live invocation claim stores its token, PID, and grammar-validated process-start identity together; an active child stores its PGID and validated leader process-start identity together. PID or PGID reuse therefore cannot impersonate owned work. Atomic terminal completion removes the worker while retaining its ledger row.

Statuses are `reserved`, `bound`, `active`, and `retired`. A retired row has terminal status `completed`, `failed`, `blocked`, or `interrupted` plus evidence.

An empty schema-version-2 registry migrates automatically. A version-2 registry with live workers is preserved unchanged and rejected with recovery instructions; reinstall the previous skill version, retire those workers, then rerun this version.

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
5. resume the exact session from the canonical target repository using prompt-file stdin and an explicit override for the registry's immutable sandbox;
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

Only that JSON result is emitted on stdout. The external artifact directory printed on stderr contains the handshake JSONL, each resume JSONL, separate stderr logs, and each final result. Artifact roots and task directories must resolve safely; individual logs and results must be real, non-symlinked, single-link files created exclusively by the runner. Existing artifact attempts are validated before the next number is selected from the greatest numeric suffix, so sparse attempts cannot be overwritten. A registry-backed invocation claim serializes the first resume, later continuations, and explicit retirement; continuation claims atomically require active state, and the initial claim is stored in the same mutation as reservation. The validated Codex executable is canonicalized before repository-directory changes. Invocation PIDs, mutation-lock PIDs, and Codex group-leader PIDs are pinned to grammar-validated process-start identities, so reused numeric identities are stale rather than live ownership. Every Codex launch waits behind a start gate in its own process group until the ancestry tracker publishes readiness and that PGID plus leader identity are durable. The tracker records observed descendants and pins each PID to its process-start identity. Stale claims are reclaimed only after the matching original group is empty and the previous invocation's tracker is clean with an empty process list; a reused PGID is ignored unless its leader instance matches. Zombies count as exited, while ambiguous access blocks recovery rather than risking unsafe retirement. The mutation lock atomically publishes a regular hard-linked owner record. Release and stale recovery compare the retained inode and process instance, ownerless or PID-reused stale files are recoverable, and symlinked/non-regular locks are rejected. Runner termination drains the original Codex group and every recorded live process instance before token-checked retirement.

The ancestry tracker is cooperative lifecycle safety, not a container or OS security boundary. Every worker prompt must forbid daemonization, persistent background services, double-forking, and deliberate lifecycle escape. Persistent services belong to parent-owned orchestration or an explicit container/cgroup boundary where exhaustive containment is required.

## Low-level registry commands

| Command | Purpose |
|---|---|
| `init` / `path` | Validate prerequisites and initialize/print external registry path |
| `reserve` | Append a fresh immutable task, optionally linked with `--retry-of` and an atomic initial invocation claim |
| `bind` | Bind one globally unique Codex session; a live invocation owner must supply its exact token |
| `activate` | Activate the exact bound task/session under the same live-owner token rule |
| `checkpoint` | Save evidence while keeping a task active |
| `claim-invocation` / `release-invocation` | Atomically serialize one live runner per task, require active continuation state, and reclaim only a dead owner whose recorded child is gone |
| `record-child` / `clear-child` | Persist and clear the gated Codex process-group ID plus leader identity after proving tracked descendants stopped |
| `complete-and-retire` | Atomically record terminal evidence and remove live worker entry |
| `query` / `active` | Read ledger task or live workers |
| `assert-no-active` / `assert-empty` | Prove no reserved, bound, or active workers remain |

Low-level commands exist for recovery and inspection. Tokenless binding, activation, or retirement is allowed only when no invocation owns the task or the recorded owner is confirmed exited; a live owner must use its exact invocation token. `completed` additionally requires the token-owning active runner, so recovery commands cannot bypass structured-result validation. Process probes force the stable C locale, treat zombies as exited, and remain conservative when access is ambiguous. Normal launches should use `run-worker.sh` so registry and process state transition together.

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

The test covers tracked-project-nonmutating init, repository moves including missing-marker live-state protection, copied-checkout isolation, copied linked-worktree rejection, and replacement-repository refusal; complete runner-prerequisite checks; symlink-safe external state, lock, and artifact paths; first-creation legacy-registry refusal; external recovery when legacy state reappears; inverse ledger/worker consistency; duplicate-live-scope, CLI-valid persisted task IDs, option-like session-ID, malformed process ID and instance rejection, and missing group-leader identity rejection; external persistent state; conservative stale-process detection; ownerless, stale, PID-reused, and concurrent atomic-lock recovery; schema-valid sandbox-preserving single-child retry chains; atomic initial reservation ownership; invocation-owner and child-group process-instance pinning; live-owner token enforcement for bind, activation, and retirement; active-only continuation claims; previous-token tracker checks including clean states with retained processes; a fast handshake with no invocation handle; slow tracker readiness without a fixed deadline; relative-PATH Codex executable canonicalization; portable artifact counting; single-link artifact ownership; sparse attempt numbering; stale-group clearing during atomic reclaim; serialized exact-session continuation from the canonical repository with the registered sandbox and without PTY/EOF; normal, zombie, synchronized detached-descendant, descendant-group, and hard-kill recovery; descendant process-instance pinning; strict completed-result ownership; artifact-independent recovery; structured-output and stderr separation; disabled user MCP config; recovery without launch prerequisites; atomic retirement; and cleanup assertions.
