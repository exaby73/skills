---
name: luna-local-review-loop
description: Route non-trivial local repository implementation, documentation, testing, validation, and review-fix work through one fresh resumable worker at a time. Use when work needs immutable scope ownership, least-privilege permission brokerage, structured results, durable retry state, process-safe cleanup, and parent-owned review and delivery.
---

# Luna Local Review Loop

Use bundled scripts as registry source of truth. Read README.md before first use.

## Roles

Parent owns decomposition, permissions, durable goals/plans, validation judgment, review, commits, delivery, CI, and GitHub state. Worker owns exactly one immutable task. Worker never delegates, stages, commits, pushes, reviews combined changes, manages GitHub/CI, daemonizes, double-forks, or starts persistent background services.

Both roles read target repository AGENTS.md hierarchy and project-local .agents/skills/caveman/SKILL.md. Use project-local Caveman for user-facing output. Parent alone invokes project-local code-reviewer.

## Initialize

Run from any path inside target Git checkout:

~~~sh
skill_root='/absolute/path/to/luna-local-review-loop'
repo_root='/absolute/path/to/repository'
"$skill_root/scripts/init.sh" --repo "$repo_root"
~~~

Authoritative registry path is always:

~~~text
<repository-root>/.agents/agent-registry/registry.json
~~~

Every registry lock, prompt snapshot, JSONL stream, stderr log, structured result, descendant tracker, lease, and other skill-owned durable artifact stays below <repository-root>/.agents/agent-registry/. Never derive or read registry state from environment variables, temporary directories, home directories, runtime-state directories, Codex state directories, Git administration directories, or caller-provided paths.

Init is idempotent. It may create .agents/agent-registry/ with mode 0700, state files with mode 0600, and exactly one .agents/agent-registry/ line in a regular root .gitignore. Existing .gitignore mode stays unchanged when it is owned by the caller and not group- or world-writable; new .gitignore mode is 0644; all other lines stay unchanged. Init rejects symlinked or non-directory boundary ancestors, path escape, unsafe ownership or permissions, symlinked/non-regular or multiply-linked state files, and unsafe .gitignore.

registry.sh path --repo "$repo_root" deterministically resolves the same project-local path. No caller-selected alternate state path or second index is supported.

## Identity and migration

Derive repository identity from canonical Git evidence: physical Git administration device/inode identity, Git common-directory identity, ordinary-checkout .git ownership, or linked-worktree .git and Git-admin backlinks. Do not use random markers or repository path hashes. A moved physical checkout keeps identity and updates stored repository_root; copied or replacement Git metadata has different identity and cannot attach to live or copied state. Copied linked-worktree aliases and ordinary .git aliases fail closed.

Schema-v3 identity_ledger is append-only lifetime history. workers contains only reserved, bound, or active rows. Empty project-local schema-v1 state may migrate only when repository ownership is proven and every worker row is absent. Live, malformed, foreign, or non-empty legacy state remains unchanged and returns recovery instructions. Empty project-local schema-v2 state may migrate after root ownership is proven. This version never discovers or copies state from older installations stored outside the project; retire live workers with the previous version before installing this one.

## Route work

Use parent-direct handling only for clearly trivial work. For non-trivial work, parent creates one task with immutable scope, expected result, sandbox, validator, exclusions, Caveman requirement, no-stage/no-commit rule, and explicit lifecycle-escape prohibition. One session serves one task. Parent performs validation and review; worker reports evidence.

## Launch

~~~sh
"$skill_root/scripts/run-worker.sh" launch \
  --repo "$repo_root" \
  --task-id issue-123-worker-1 \
  --scope 'owned paths: src/a.ts; task: implement validator; validator: project check; no commits' \
  --sandbox workspace-write \
  --prompt-file /absolute/path/to/task-prompt.txt
~~~

Task IDs contain only letters, numbers, dot, underscore, and hyphen; . and .. are forbidden. Launch snapshots the prompt below the project-local registry, atomically reserves the task and invocation token, performs a read-only handshake, binds the durable Codex session ID, activates it, then resumes the exact session from canonical repository root with the registered sandbox. It prints only structured final JSON on stdout; streaming artifacts and stderr remain below the task artifact directory.

Handshake always uses read-only mode and cannot consume the task prompt. First resume inherits the descriptor opened for the immutable .task-prompt; it does not reopen that pathname. Continuations read their supplied prompt normally. Never use --ephemeral, PTY, manual EOF, --last, replacement sessions, or process handles as worker identity.

The launcher uses --ignore-user-config to avoid unrelated connector startup. Codex runtime state is separate product-owned state; this skill does not relocate or manage it. If runtime permission fails, return needs_parent_action with exact permission request.

## Ownership and process safety

Registry transitions use an atomic lock whose owner PID and process-start identity are pinned. A stale claim can be reclaimed only after the previous invocation is confirmed exited and any recorded child has clean, empty descendant evidence. PID reuse, PGID reuse, ambiguous process access, missing tracker evidence, missing lease proof, symlinked locks, and non-regular locks fail closed.

Every Codex child runs in its own process group behind a start gate. The descendant tracker records every observed PID with process-start identity, verifies parent identity before expansion, inherits a private FIFO lease, independently enumerates token-bearing processes, and publishes clean only after process and lease evidence is empty. Cleanup signals only verified process instances. Zombies count as exited; unverifiable processes remain live for recovery. INT, TERM, and HUP preserve active registry state when cleanup cannot be proven.

Artifacts are created exclusively as single-link regular files with mode 0600; task and artifact directories are real directories with mode 0700. Existing symlinked, hard-linked, non-regular, or unsafe artifacts are never overwritten. Sparse attempt numbering advances from greatest existing numeric suffix.

## Continue, retry, and finish

needs_parent_action keeps task active. Parent performs only exact approved action, records command/status/output in a new prompt file, then continues same task/session:

~~~sh
"$skill_root/scripts/run-worker.sh" continue \
  --repo "$repo_root" \
  --task-id issue-123-worker-1 \
  --prompt-file /absolute/path/to/parent-result.txt
~~~

Failed, blocked, or interrupted attempts can be retried with a fresh task ID and exact --retry-of. Retry inherits stored sandbox; explicit mismatch is rejected. Each attempt has at most one retry child, and retry chain remains linear.

~~~sh
"$skill_root/scripts/run-worker.sh" finish \
  --repo "$repo_root" \
  --task-id issue-123-worker-1 \
  --status interrupted \
  --evidence 'parent stopped task after process failure'
~~~

Explicit finish accepts failed, blocked, or interrupted. completed requires token-owning active runner plus validated structured result. Tokenless recovery is allowed only after owner exit is proven. A task with no recorded child can be finished without artifacts; recorded-child cleanup requires preserved clean tracker and lease evidence.

Before parent goal completion:

~~~sh
"$skill_root/scripts/registry.sh" assert-no-active --repo "$repo_root"
"$skill_root/scripts/registry.sh" assert-empty --repo "$repo_root"
~~~

Never delete registry state or Codex history manually.

## Structured result

Result must match references/worker-result.schema.json. completed requires at least one validator, all validators passed, non-empty evidence, and no unresolved work. blocked and needs_parent_action carry concise evidence; needs_parent_action requires non-empty parentAction. Terminal outcomes use parentAction: null.

## Validation

Run:

~~~sh
./luna-local-review-loop/scripts/test-init.sh
bash -n luna-local-review-loop/scripts/*.sh
shellcheck --version
shellcheck luna-local-review-loop/scripts/*.sh
python3 /path/to/skill-creator/scripts/quick_validate.py luna-local-review-loop
git diff --check
~~~

Review targeted searches for obsolete alternate-state names and paths. Run one real forward test only when it does not launch another worker. Parent owns final real forward test, code review, staging, commit, push, PR, and delivery.
