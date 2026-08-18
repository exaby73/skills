---
name: luna-local-review-loop
description: Route non-trivial local repository implementation, documentation, testing, validation, and review-fix work through one fresh resumable worker at a time. Use when work needs immutable scope ownership, least-privilege permission brokerage, structured results, durable retry state, process-safe cleanup, and parent-owned review and delivery.
---

# Luna Local Review Loop

Use native host collaboration when its complete lifecycle capability set is available. Use bundled scripts as the deterministic `codex exec` fallback only. Read README.md before first use.

## Roles

Parent owns decomposition, permissions, durable goals/plans, validation judgment, review, commits, delivery, CI, and GitHub state. Worker owns exactly one immutable task. Worker never delegates, stages, commits, pushes, reviews combined changes, manages GitHub/CI, daemonizes, double-forks, or starts persistent background services.

Both roles read target repository AGENTS.md hierarchy and project-local .agents/skills/caveman/SKILL.md. Use project-local Caveman for user-facing output. The parent orchestrates each code-reviewer pass through a fresh Sol-High reviewer and retains the final review decision.

## Select execution path

The parent/controller is model-agnostic. This skill never names, pins, or implies a concrete parent model or reasoning setting.

Use native host collaboration only when the host exposes the complete lifecycle contract: spawn, unique task identity, message/follow-up, wait, interruption/close, and list/read/collect. Select this from the host capability result, never from shell or environment guesses.

Implementation and validation workers always use a fresh Luna Max worker: model `gpt-5.6-luna`, reasoning `max`, and the smallest useful context. Every code-review pass and re-review always uses a fresh, read-only Sol-High reviewer: model `gpt-5.6-sol`, reasoning `high`. The parent evaluates the review and owns the final decision; the parent model is not a substitute reviewer.

Record the selected path and the exact worker/reviewer configuration in the parent-owned evidence. Native execution must prove the host lifecycle and must not create or read the fallback registry. If native startup has begun and then fails, stop with an explicit failure; do not silently switch paths. Use the CLI fallback only when the complete native capability set was unavailable before startup.

## Native implementation and validation path

When the complete native capability set is available, the parent launches one fresh Luna Max worker for each immutable implementation or validation task. Give every task a unique host identity and a self-contained prompt containing the owned scope, target revisions, governing guidance, validator, exclusions, no-stage/no-commit rule, and interruption boundary.

The native worker configuration is always model `gpt-5.6-luna` with reasoning `max`. The parent uses the native lifecycle directly: spawn, send a follow-up when needed, wait, inspect/list the task, interrupt or close when required, and collect the final structured result. Do not initialize the fallback registry, invoke `codex exec`, or use a second process/index for native work.

A native lifecycle failure after spawn is a failed native run, not a reason to switch paths. Preserve the failure evidence and stop for parent action. The CLI fallback is eligible only when the complete native capability set was unavailable before any native worker started.

## Fresh code-review path

Every `code-reviewer` pass and re-review uses a fresh read-only Sol-High agent: model `gpt-5.6-sol`, reasoning `high`. The reviewer receives the complete current ticket or pull-request contract, applicable AGENTS.md and reviewer guidance, target revisions, full current diff, and the required validation evidence. It returns an independent conclusion for the parent to evaluate.

A code-review agent never edits files, stages, commits, pushes, changes GitHub state, launches workers, or makes the final delivery decision. Do not substitute a Luna worker, the parent/controller, or another model. If Sol-High is unavailable or its identity/configuration cannot be verified, report `Evidence blocked` and do not claim review approval.

## Keep orchestration off the critical path

- Never use this skill to modify, test, validate, or review its own installed files. Luna skill maintenance is parent-direct work.
- Never make Luna maintenance a prerequisite for an unrelated delivery goal unless that maintenance is an explicit acceptance criterion or a proven safety requirement for the requested work.
- Stop a worker when it repeats the same environment or tooling failure, or when continued execution produces no useful task progress. Do not retry the same unchanged blocker; the parent performs the remaining work directly or reports the blocker.

## CLI fallback: initialize

Run this section only after the host capability gate proves native collaboration is unavailable before startup. Native work never initializes or uses this registry.

Run from any path inside target Git checkout:

~~~sh
skill_root='/absolute/path/to/luna-local-review-loop'
repo_root='/absolute/path/to/repository'
"$skill_root/scripts/init.sh" --repo "$repo_root"
~~~

Fallback registry path is always:

~~~text
<repository-root>/.agents/agent-registry/registry.json
~~~

Every registry lock, prompt snapshot, JSONL stream, stderr log, structured result, descendant tracker, lease, and other skill-owned durable artifact stays below <repository-root>/.agents/agent-registry/. Launch, continue, and tracker paths derive from dirname of exact project-local registry authority; repository-root `artifacts/` is never created or accepted. Never derive or read registry state from environment variables, temporary directories, home directories, runtime-state directories, Codex state directories, Git administration directories, or caller-provided paths.

Init is idempotent. It may create `.agents/agent-registry/` with mode 0700, state files with mode 0600, and exactly one `.agents/agent-registry/` line in a regular root `.gitignore`. The registry-local `.gitignore` is private mode 0600 and ends with `*`. These ignore rules are for Git visibility/confidentiality, never write protection: workspace-write requires Codex CLI `>= 0.147.0` with its compiled recursive OS sandbox boundary protecting project `.agents`; malformed/older versions fail before reservation, while read-only remains supported. The parent separately grants Codex runtime state. Existing `.gitignore` mode stays unchanged when it is owned by the caller and not group- or world-writable; new `.gitignore` mode is 0644; all other lines stay unchanged. Init rejects symlinked or non-directory boundary ancestors, path escape, unsafe ownership or permissions, symlinked/non-regular or multiply-linked state files, unsafe `.gitignore`, and unsafe nested ignore negations. `--existing-path` validates only and never rewrites ignore files or other project metadata.

registry.sh path --repo "$repo_root" deterministically resolves the same project-local path. No caller-selected alternate state path or second index is supported.

## Identity and migration

Derive repository identity from canonical Git evidence: physical Git administration device/inode identity, Git common-directory identity, ordinary-checkout `.git` ownership, or linked-worktree `.git` and Git-admin backlinks. Init also atomically creates a private random 256-bit lowercase-hex `.luna-checkout-identity` seal in the physical Git administration directory. Record its digest and device/inode only as auxiliary evidence combined with Git identity; never treat it as registry authority, a locator, or a path. Missing, malformed, replaced, unsafe, or multiply-linked seals, copied/reinitialized metadata, device/inode reuse without the seal evidence, copied linked-worktree aliases, and ordinary `.git` aliases fail closed. Do not use repository path hashes. A moved physical checkout keeps identity and updates stored `repository_root`.

Schema-v3 identity_ledger is append-only lifetime history. workers contains only reserved, bound, or active rows. Empty project-local schema-v1 state may migrate only when repository ownership is proven and every worker row is absent. Live, malformed, foreign, or non-empty legacy state remains unchanged and returns recovery instructions. Empty project-local schema-v2 state may migrate after root ownership is proven only after its prospective schema-v3 transformation is fully validated before seal creation; malformed or unsafe v2 input leaves registry bytes and seal absence unchanged. This version never discovers or copies state from older installations stored outside the project; retire live workers with the previous version before installing this one.

## Route work

Use parent-direct handling only for clearly trivial work. For non-trivial work, parent creates one task with immutable scope, expected result, sandbox, validator, exclusions, Caveman requirement, no-stage/no-commit rule, and explicit lifecycle-escape prohibition. One session serves one task. Parent performs validation and evaluates the fresh Sol-High review result; worker reports evidence.

## CLI fallback: launch

~~~sh
"$skill_root/scripts/run-worker.sh" launch \
  --repo "$repo_root" \
  --task-id issue-123-worker-1 \
  --scope 'owned paths: src/a.ts; task: implement validator; validator: project check; no commits' \
  --sandbox workspace-write \
  --prompt-file /absolute/path/to/task-prompt.txt
~~~

Task IDs contain only letters, numbers, dot, underscore, and hyphen; . and .. are forbidden. Launch snapshots the prompt below the project-local registry, atomically reserves the task and invocation token, performs a read-only handshake, binds the durable Codex session ID, activates it, then resumes the exact session from canonical repository root with the registered sandbox. Before a workspace-write reservation it fail-closed parses `codex-cli X.Y.Z` and requires `>= 0.147.0`; read-only does not use this gate. Resume and continue pass `--ignore-user-config`, `--strict-config`, and explicit sandbox configuration. It prints only structured final JSON on stdout; streaming artifacts and stderr remain below the task artifact directory.

Handshake always uses read-only mode and cannot consume the task prompt. First resume inherits the descriptor opened for the immutable .task-prompt; it does not reopen that pathname. Continuations read their supplied prompt normally. Never use --ephemeral, PTY, manual EOF, --last, replacement sessions, or process handles as worker identity.

The launcher uses --ignore-user-config to avoid unrelated connector startup. Codex runtime state is separate product-owned state; this skill does not relocate or manage it. If runtime permission fails, return needs_parent_action with exact permission request.

## Ownership and process safety

Registry transitions use an atomic lock whose owner PID and process-start identity are pinned. A stale claim can be reclaimed only after the previous invocation is confirmed exited and any recorded child has clean, empty descendant evidence. PID reuse, PGID reuse, ambiguous process access, missing tracker evidence, missing lease proof, symlinked locks, and non-regular locks fail closed.

Every Codex child runs in its own process group behind a start gate. The descendant tracker records every observed PID with process-start identity, verifies parent identity before expansion, inherits a private FIFO lease, independently enumerates token-bearing processes, and publishes clean only after process and lease evidence is empty. Cleanup signals only verified process instances. Zombies count as exited; unverifiable processes remain live for recovery. INT, TERM, and HUP preserve active registry state when cleanup cannot be proven.

Artifacts are created exclusively as single-link regular files with mode 0600; task and artifact directories are real directories with mode 0700. Existing symlinked, hard-linked, non-regular, or unsafe artifacts are never overwritten. Sparse attempt numbering advances from greatest existing numeric suffix.

## CLI fallback: continue, retry, and finish

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

Before parent goal completion, when the CLI fallback was selected:

~~~sh
"$skill_root/scripts/registry.sh" assert-no-active --repo "$repo_root"
"$skill_root/scripts/registry.sh" assert-empty --repo "$repo_root"
~~~

Never delete registry state or Codex history manually.

## Structured result

Worker results from either path must match references/worker-result.schema.json. completed requires at least one validator, all validators passed, non-empty evidence, and no unresolved work. blocked and needs_parent_action carry concise evidence; needs_parent_action requires non-empty parentAction. Terminal outcomes use parentAction: null. A Sol-High reviewer returns a separate read-only review conclusion; it never masquerades as a worker result.

## Validation

Run:

~~~sh
./luna-local-review-loop/scripts/test-init.sh
bash luna-local-review-loop/scripts/test-path-selection.sh
bash luna-local-review-loop/scripts/test-review-routing.sh
bash -n luna-local-review-loop/scripts/*.sh
shellcheck --version
shellcheck luna-local-review-loop/scripts/*.sh
python3 /path/to/skill-creator/scripts/quick_validate.py luna-local-review-loop
git diff --check
~~~

Review targeted searches for obsolete alternate-state names and paths. Run native lifecycle probes for implementation/validation and fresh Sol-High read-only review fixtures when the host supports them. Run one real forward test only when it does not launch another worker. The parent owns final real forward-test judgment, review evaluation, staging, commit, push, PR, and delivery.
