# Luna Local Review Loop Registry

This package gives the parent a small, persistent, local registry for Luna worker ownership. It survives context compaction and a new parent agent, makes the exact task/session/scope queryable with `jq`, and prevents a pruned identity from being reused for a different task.

The registry records ownership and terminal evidence; it does not launch, resume, interrupt, terminate, or delete workers. The parent must use supported orchestration for real process control and must own final cleanup.

## Prerequisites and dependent skills

`init` checks these local prerequisites before mutating the target repository:

- Bash 3 or newer.
- `git`, `jq`, `mktemp`, `mkdir`, `mv`, `rm`, `rmdir`, `date`, `kill`, `ps`, `sleep`, `head`, `awk`, `cmp`, `chmod`, and `stat` on `PATH`.
- `codex` on `PATH`; the launch and same-task resume contract depends on it.
- The target repository's project-local `.agents/skills/code-reviewer/SKILL.md`. If it is missing, `npx` must be available so init can install it.
- The target repository's project-local `.agents/skills/caveman/SKILL.md`. If it is missing, `npx` must be available so init can install it.

Parent and delegated workers must read and use the project-local Caveman skill for user-facing output. A global or active-skills-root Caveman copy does not satisfy target-repository setup.

When either project-local skill is missing, init runs its exact command from the target repository root:

```zsh
npx -y skills add https://github.com/google-gemini/gemini-cli --skill code-reviewer -y
npx -y skills add https://github.com/juliusbrussee/caveman --skill caveman -y
```

The first `-y` suppresses npx's package-install prompt. The final `-y` skips Skills CLI confirmation prompts and lets `skills` auto-detect project scope from the repository root. Init never uses `-g`. Existing project-local skills skip their corresponding `npx` command, so repeated init stays idempotent. These conditional installs are the only init operations that may use the network.

If a prerequisite is missing or either skill setup fails, init exits with code `3` and reports the exact command or path to check plus the next action. A global copy of either dependency does not satisfy project setup.

The source checkout may not itself be the active skills root. In that case pass `--skills-root /absolute/path/to/skills` to init.

## Initialize

The skill-level routing form is:

```text
$luna-local-review-loop init
```

The bundled executable form is:

```zsh
skill_root='/absolute/path/to/luna-local-review-loop'
skills_root='/absolute/path/to/active/skills'
repo_root='/absolute/path/to/repository'

"$skill_root/scripts/init.sh" --repo "$repo_root" --skills-root "$skills_root"
# Equivalent dispatch through the registry script:
"$skill_root/scripts/registry.sh" init --repo "$repo_root" --skills-root "$skills_root"
```

Without `--repo`, init resolves the current directory to its Git repository root. `--repo PATH` may point at a repository or a directory inside one; `-C PATH` is an alias. Without `--skills-root`, the script checks the parent directory of this skill package.

Init is idempotent:

1. It verifies the target Git root and every documented local prerequisite, including `codex`.
2. It verifies project-local code-reviewer setup, conditionally installing it from the repository root when absent.
3. It verifies project-local Caveman setup, conditionally installing it from the repository root when absent.
4. It creates `.agents/agent-registry/` and acquires a local atomic `mkdir` lock.
5. It ensures the exact `.agents/agent-registry/` line occurs once in the repository-root `.gitignore`, preserving an existing file's mode and using `0644` for a new file.
6. It atomically creates `.agents/agent-registry/registry.json` when absent, or validates the existing version-1 registry without overwriting it.

If an existing registry has a different `repository_root` or fails validation, init stops and preserves it for investigation. Do not copy a registry from another checkout.

Validate init without network access by running `scripts/test-init.sh`. Its temporary Git repository and fake `npx` verify both exact project-local install commands, idempotence, registry creation, a new `.gitignore` mode of `0644`, and preservation of an existing custom mode.

## Location, locking, and atomic writes

For a repository rooted at `repo_root`, the durable files are:

```text
repo_root/.gitignore
repo_root/.agents/agent-registry/registry.json
repo_root/.agents/agent-registry/.lock/   # transient local lock, ignored
```

Every mutation takes the `.lock` directory using atomic `mkdir`, writes a temporary JSON file in the same directory, validates it with `jq`, and renames it into place. Readers see either the old valid registry or the new valid registry. The lock records the owning shell PID and is released on normal exit and interruption. `kill -0` is used only to probe whether a lock owner still exists; the registry never sends a termination signal to a worker. If a command times out on a lock, inspect the PID and remove only a confirmed-stale `.lock` directory; never remove the registry or use registry data to stop a process.

## Version-1 schema

The top-level object is:

```json
{
  "schema_version": 1,
  "registry": "luna-local-review-loop",
  "repository_root": "/absolute/repository/root",
  "created_at": "2026-08-14T12:00:00Z",
  "updated_at": "2026-08-14T12:00:00Z",
  "identity_ledger": [],
  "workers": []
}
```

`identity_ledger` is append-only for retention: each task row is added once and never deleted. Its task ID, scope, and session ID remain immutable; `handle` is the explicit current handle, while `handle_history` is strictly append-only. A `reserve` operation appends the exact task ID and one-line scope with `session_id: null`, `handle: null`, and an empty `handle_history`. The one permitted `bind` transition fills the session, current handle, and `bound_at` exactly once, and records the launch handle as the first history item. Every same-session resume appends one immutable history item with its handle, `recorded_at` timestamp, and `kind: "resume"`, then updates the explicit current `handle` in both the ledger row and worker entry. The row and its handle history remain queryable after worker pruning, so every old handle stays unavailable for reuse.

A bound ledger row has this handle-history shape:

```json
{
  "task_id": "issue-123-worker-1",
  "scope": "owned paths: src/a.ts; exact task: implement validator; no commits",
  "session_id": "codex-session-id",
  "handle": "resume-worker-handle-2",
  "handle_history": [
    { "handle": "launch-worker-handle", "recorded_at": "2026-08-14T12:01:00Z", "kind": "launch" },
    { "handle": "resume-worker-handle-1", "recorded_at": "2026-08-14T12:10:00Z", "kind": "resume" },
    { "handle": "resume-worker-handle-2", "recorded_at": "2026-08-14T12:20:00Z", "kind": "resume" }
  ],
  "reserved_at": "2026-08-14T12:00:00Z",
  "bound_at": "2026-08-14T12:01:00Z"
}
```

Each current worker object starts like this:

```json
{
  "task_id": "issue-123-worker-1",
  "scope": "owned paths: src/a.ts; exact task: implement validator; no commits",
  "session_id": null,
  "handle": null,
  "status": "reserved",
  "created_at": "2026-08-14T12:00:00Z",
  "updated_at": "2026-08-14T12:00:00Z",
  "bound_at": null,
  "activated_at": null,
  "terminal_at": null,
  "retired_at": null,
  "terminal_status": null,
  "terminal_evidence": "",
  "terminal_notes": "",
  "notes": "reserved before launch"
}
```

After binding, the worker has the same non-null session ID, current handle, and `bound_at` as its ledger row and moves to `bound`. `activate` then moves it to `active`. A worker's task ID, scope, session ID, and binding are immutable; only `record-resume-handle` may replace its current handle, and only while the task is `bound` or `active` and uses its exact bound session. Statuses are `reserved`, `bound`, `active`, `stopping`, `completed`, `failed`, `blocked`, `interrupted`, and `retired`; the first four are non-terminal. Terminal workers must be permanently retired before pruning.

## Query with jq

Set the registry path once:

```zsh
registry_path="$repo_root/.agents/agent-registry/registry.json"
```

Useful recovery queries:

```zsh
# The current worker entry, including a reserved null identity.
jq '.workers | map(select(.task_id == "issue-123-worker-1"))' "$registry_path"

# The permanent reservation and, after bind, the permanent attached identity.
jq '.identity_ledger | map(select(.task_id == "issue-123-worker-1"))' "$registry_path"

# Every launch/resume handle, including handles no longer current.
jq '.identity_ledger[] | select(.task_id == "issue-123-worker-1") | .handle_history' "$registry_path"

# All entries that still require parent cleanup or continuation.
jq '.workers | map(select(.status == "reserved" or .status == "bound" or .status == "active" or .status == "stopping"))' "$registry_path"

# Compact ownership table for current entries.
jq -r '.workers[] | [.task_id, .scope, (.session_id // ""), (.handle // ""), .status, .updated_at] | @tsv' "$registry_path"

# Confirm current exact bound identity after context compaction.
jq -e '[.workers[] | select(.task_id == "issue-123-worker-1" and .scope == "owned paths: src/a.ts; exact task: implement validator; no commits" and .session_id == "codex-session-id" and .handle == "resume-worker-handle-2")] | length == 1' "$registry_path"

# Recover old handles after worker prune; never use them for mutation.
jq -e '[.identity_ledger[] | select(.task_id == "issue-123-worker-1") | .handle_history[] | select(.handle == "launch-worker-handle" and .kind == "launch")] | length == 1' "$registry_path"

# Show the no-reuse ledger, including identities whose worker entry was pruned.
jq '.identity_ledger' "$registry_path"
```

The `list`, `active`, and `query` commands emit JSON arrays, so their output can be piped to `jq` as well. A query of a pruned worker is intentionally not a new ownership source; recover the permanent identity from `identity_ledger` and continue only the exact same task when a current entry still exists.

## Command reference

All commands accept `--repo PATH` or `-C PATH`; lifecycle commands require that init has already succeeded.

| Command | Purpose |
| --- | --- |
| `init [--repo PATH] [--skills-root PATH]` | Verify prerequisites and dependent skill; create or validate the registry. |
| `reserve --task-id ID --scope TEXT [--notes TEXT]` | Permanently reserve a fresh task and exact one-line scope before launch with null identity. |
| `register --task-id ID --scope TEXT [--notes TEXT]` | Compatibility spelling for `reserve`; it never accepts a session ID or handle. |
| `bind` or `attach --task-id ID --session-id ID --handle ID` | Write the emitted session ID and process/agent handle exactly once, then move the worker to `bound`. |
| `record-resume-handle --task-id ID --session-id ID --handle ID` | Append a fresh same-session execution handle with timestamp and `kind: "resume"`; update the current handle. Only exact-session tasks in `bound` or `active` state are allowed. |
| `activate --task-id ID --session-id ID [--handle ID]` | Change the exact bound worker to `active`; repeated activation is a safe no-op. |
| `list` | Emit all current worker entries as JSON. |
| `active` or `list --active` | Emit `reserved`, `bound`, `active`, and `stopping` entries. |
| `query --task-id ID`, `--session-id ID`, or `--handle ID` | Emit matching current entries; combine selectors for an exact recovery query. Add `--active-only` to exclude terminal entries. |
| `update --task-id ID --status STATE [--session-id ID] [--handle ID] [--evidence TEXT] [--notes TEXT]` | Update the exact worker through a legal transition. A bound worker requires its exact session ID and current handle; terminal states require evidence. |
| `retire --task-id ID [--session-id ID] [--handle ID] [--evidence TEXT] [--notes TEXT]` | Permanently record retirement for the exact worker using its current handle. An unbound launch failure may still be retired by task ID with evidence. |
| `prune` or `clear` | Remove retired worker entries only after all non-terminal and unretired terminal entries are gone. The identity ledger remains. |
| `prune --task-id ID` | Remove one named retired entry only; it refuses active or unretired terminal entries. |
| `assert-no-active` | Exit successfully only when no reserved, bound, active, or stopping entry remains. |
| `assert-empty` | Exit successfully only when `workers` is empty; the identity ledger intentionally remains. |

Use `completed`, `failed`, `blocked`, or `interrupted` with `update`; use `retire` for the final state. A mismatch exits without changing the registry. A second bind, a reused task ID or scope, a duplicate history handle, or a session/handle already belonging to another task exits with code `6`.

Stable exit codes are:

| Code | Meaning |
| ---: | --- |
| `0` | Success. |
| `2` | Invalid command or arguments. |
| `3` | Missing runtime prerequisite or dependent skill. |
| `4` | Invalid/non-Git repository or uninitialized registry. |
| `5` | Registry schema or repository-root mismatch. |
| `6` | Identity conflict or illegal same-task transition. |
| `7` | Requested current worker entry was not found. |
| `8` | Active workers remain, a worker is not permanently retired, or the registry is not empty. |
| `9` | Lock acquisition timed out. |
| `10` | Filesystem or atomic-write failure. |

## One-task worker lifecycle

The parent owns this sequence for every launch:

1. Read repository instructions and identify command classes reserved for the parent. In repositories that require elevated pnpm tests, the parent owns every `pnpm test` and `pnpm run test:*` command; the worker must not run them.
2. Choose a fresh stable task ID and write an exact one-task scope with owned paths, expected result, validator, and boundaries.
3. Reserve before launch. The reservation must be durable before `codex exec` starts:

   ```zsh
   task_id='issue-123-worker-1'
   task_scope='owned paths: src/a.ts; exact task: implement validator; validator: pnpm check; no staging or commits'
   "$skill_root/scripts/registry.sh" reserve \
     --repo "$repo_root" \
     --task-id "$task_id" \
     --scope "$task_scope"
   ```

4. Launch a fresh handshake without `--last` or any session-shortening mode. The prompt must forbid repository work and end the one-shot invocation after emitting the bind marker:

   ```zsh
   launch_argv=(codex exec \
     -m 'gpt-5.6-luna' \
     -c 'model_reasoning_effort="max"' \
     -s 'workspace-write' \
     -C "$repo_root" \
     'Handshake only. Do not read, write, test, or otherwise work in the repository. Reply exactly READY_TO_BIND, then stop so the parent can bind this session and resume it with the reserved task.')
   # Start launch_argv through supported orchestration and let it exit.
   # Capture Codex session ID and orchestration handle; never substitute shell $!.
   captured_session_id='<session ID emitted by codex exec>'
   launch_handle='<completed handshake process or agent handle returned by orchestration>'
   ```

5. Bind the captured handshake identity exactly once. Then resume the exact session with stdin pending, record that fresh live handle, activate with it, and only then feed the exact reserved task prompt and EOF. A second bind and every cross-task session or handle reuse are refused:

   ```zsh
   "$skill_root/scripts/registry.sh" bind \
     --repo "$repo_root" \
     --task-id "$task_id" \
     --session-id "$captured_session_id" \
     --handle "$launch_handle"
   # Through supported orchestration, start with stdin pending:
   # codex exec resume -m gpt-5.6-luna -c model_reasoning_effort=max "$captured_session_id" -
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
   # Only now, invoke the supported orchestration stdin-write operation for
   # captured_handle with task_prompt, then close that stdin (EOF). Collect
   # output until this exact resumed process exits.
   ```

6. For every later permission return, repeat the exact-session resume handshake: keep stdin pending, capture the new outer orchestration process handle, record it before feeding the approved output, then feed the exact command, exit status, and captured output:

   ```zsh
   # Through supported orchestration, start this exact argv with stdin pending:
   # codex exec resume -m gpt-5.6-luna -c model_reasoning_effort=max "$captured_session_id" -
   # Use the fresh process/agent handle returned by orchestration, never shell $!.
   captured_handle='<fresh process or agent handle returned by orchestration>'
   # Keep stdin pending until this succeeds.
   "$skill_root/scripts/registry.sh" record-resume-handle \
     --repo "$repo_root" \
     --task-id "$task_id" \
     --session-id "$captured_session_id" \
     --handle "$captured_handle"
   # Now feed exact approved command, exit status, and captured output.
   ```

   Use the exact bound session ID, never `--last`, a replacement session, or a different model. Later `update` and `retire` commands must use the newly recorded current handle. A stale handle is rejected.
7. Collect changed files, result, validator command/output, and limitations. Update `stopping` before shutdown when useful, then update a terminal state with concrete evidence using the current handle.
8. Through supported orchestration, interrupt or terminate the real worker, wait for it, and verify shutdown independently. The registry is not a process controller and no registry handle may be passed to an arbitrary termination command.
9. Permanently retire the exact bound session with its current handle, prune retired entries, then assert both no active workers and an empty `workers` array before the parent marks its goal complete or blocked. If launch fails before binding, retire the reserved task by task ID with launch-failure evidence.

## Compaction and new-parent recovery

After context compaction or when a new parent takes over:

1. Resolve the repository root and read `registry.json` directly or run `active`/`query`.
2. For every non-terminal entry, compare the recorded task ID, exact scope, bound session ID, and current handle with the parent’s durable goal/plan and supported orchestration state. Read `identity_ledger[].handle_history` to recover every prior handle. A `reserved` entry has intentionally null identity and must be bound only to the identity emitted by its own fresh launch.
3. Continue an exact bound session only when it is still the same task and scope. Use the recorded session ID explicitly. For each resume, record the new outer handle before feeding stdin. Never use `--last`, infer ownership from a process name, attach a session to a new task, or mutate with an old handle.
4. If the real worker is gone, collect the available output and mark it `completed`, `failed`, `blocked`, or `interrupted` with evidence, then permanently retire and prune it. If ownership is ambiguous, stop and ask the user or parent rather than inventing an identity.
5. Start later work with a new task ID, scope, session ID, and launch handle. A pruned identity retains every handle in `identity_ledger[].handle_history`, so a mistaken reuse fails instead of silently polluting another task.

## Permission brokerage

A blocked non-interactive worker must stop and report:

```text
BLOCKED COMMAND: <exact command>
REASON: <why it is blocked>
EXPECTED SIDE EFFECTS: <what the command may change>
PERMISSION NEEDED: <specific permission>
```

The parent reviews the exact command, checks that it is safe and in scope, runs only that exact command through the required approval path, and returns the exact exit status and captured output to the same worker session. If it is unsafe or ambiguous, ask the user. Do not substitute a command, broaden access, or ask the worker to work around the block.

For the same-task return, start the exact captured session with stdin pending, capture and record its new outer handle, then feed the parent-run result:

```zsh
# Through supported orchestration, start this exact argv with stdin pending:
# codex exec resume -m gpt-5.6-luna -c model_reasoning_effort=max '<captured-session-id>' -
# Use the fresh process/agent handle returned by orchestration, never shell $!.
captured_handle='<fresh process or agent handle returned by orchestration>'
"$skill_root/scripts/registry.sh" record-resume-handle \
  --repo "$repo_root" \
  --task-id "$task_id" \
  --session-id '<captured-session-id>' \
  --handle "$captured_handle"
# Feed exact approved command, exit status, and captured output only now.
```


Keep stdin pending until `record-resume-handle` succeeds. Use captured session ID and original task/scope only; never use `--last`, a new worker, or a different model. If repository instructions reserve an elevated pnpm test for the parent, the parent runs that exact command and returns its result before this resume.

## Parent-owned cleanup contract

Before completion or blocked status, the parent must have evidence for every worker, must have interrupted or terminated real workers through supported orchestration and waited, and must have recorded terminal state. Then run:

```zsh
"$skill_root/scripts/registry.sh" retire --repo "$repo_root" --task-id ID --session-id ID --handle CURRENT_HANDLE --evidence 'shutdown evidence'
"$skill_root/scripts/registry.sh" prune --repo "$repo_root"
"$skill_root/scripts/registry.sh" assert-no-active --repo "$repo_root"
"$skill_root/scripts/registry.sh" assert-empty --repo "$repo_root"
```

Do not report cleanup complete while a worker entry remains. Do not delete Codex history, send arbitrary process-termination signals, or clear the identity ledger to make the assertions pass.

## Troubleshooting

- `ERROR [3] missing runtime prerequisite(s)`: run `command -v <name>` for each reported command, including `codex`, install it through the approved host/repository mechanism, and rerun init. If either project-local dependent skill is missing, also verify `npx` and network access for the documented conditional setup commands.
- `ERROR [3] code-reviewer skill prerequisite/setup failed`: fix `npx`, its install/network failure, or the missing project-local `.agents/skills/code-reviewer/SKILL.md`, then rerun init. Verify both `-y` flags and their order if using a fake `npx` in tests. A global copy does not satisfy this check.
- `ERROR [3] Caveman skill prerequisite/setup failed`: fix `npx`, its install/network failure, or the missing project-local `.agents/skills/caveman/SKILL.md`, then rerun init. Verify both `-y` flags and their order if using a fake `npx` in tests. A global copy does not satisfy this check.
- `ERROR [4] path is not inside a Git repository`: pass `--repo PATH` to the repository root or a directory inside it.
- `ERROR [4] worker registry is not initialized`: run init for that exact repository before reserve, query, or cleanup.
- `ERROR [5] registry fails schema validation` or `repository_root` mismatch: preserve the JSON for evidence, do not copy another repository’s registry, and repair the target registry through the parent’s approved recovery process.
- `ERROR [6] identity conflict`, duplicate/cross-task handle, or exact session/current-handle mismatch: stop. Query `identity_ledger[].handle_history`, record only a fresh handle for the original non-terminal session, and continue only the original task/session; reserve a fresh identity for genuinely new work.
- `ERROR [8] active workers remain` or pruning is refused: collect evidence, use supported orchestration to stop and wait for every real worker, record terminal state, permanently retire exact sessions, prune, and assert again.
- `ERROR [9] registry lock is busy`: wait for the owning command. If its PID is no longer running, remove only the confirmed-stale `.lock` directory and retry; never remove `registry.json`.
- `ERROR [10] atomic write/filesystem failure`: check permissions and free space for the repository’s `.agents/agent-registry/` directory. The previous valid registry is intended to remain in place when a rename fails.
