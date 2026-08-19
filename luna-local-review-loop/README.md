# Luna Local Review Loop

Reusable protocol for bounded local repository work with one fresh worker per task. Native host collaboration is the default when its complete lifecycle capability set is available; the hardened CLI/registry flow is the deterministic fallback. The parent/controller remains model-agnostic, owns permissions and delivery, and evaluates review evidence. Implementation and validation use fresh Luna Max workers; every code-review pass uses a fresh read-only Sol-High reviewer. Each spawned worker is the sole worker for its immutable task: it must perform that scope directly and never spawn, delegate to, or hand work to another subagent.

## Path selection

The parent selects the path from an explicit host capability result. The native gate requires unique task identity, spawn, message/follow-up, wait, interruption/close, list/read/collect, and the atomic cross-path claim primitive. Shell or environment guesses are not capability detection.

Native implementation and validation workers use model gpt-5.6-luna with reasoning max and the smallest useful context. The native pre-start capability result must also prove exact model/reasoning selection and enforceable read-only or sandbox controls for both worker and reviewer roles. Native work uses no project-local registry, codex exec, or alternate process/index. If native startup begins and fails, preserve the failure and stop; never switch to fallback after partial startup.

Every code-reviewer pass and re-review uses a fresh read-only Sol-High agent with model gpt-5.6-sol and reasoning high. Provide the full contract, applicable guidance, target revisions, current diff, and validation evidence. The reviewer cannot edit, stage, commit, push, change GitHub state, launch workers, or decide delivery. If Sol-High is unavailable or unverifiable, report Evidence blocked and do not substitute Luna, the parent, or another model.

The parent model and reasoning remain task-selected and are not specified by this skill. See the path-selection and review-routing contract fixtures for executable checks.

Before native selection, the parent validates the canonical repository and registry authority, then checks the project-local fallback registry, when present, for an active or awaiting-continue task with the same immutable scope. A missing registry is the explicit `not-initialized` clear state; malformed, unreadable, or ambiguous fallback state fails closed. An active task remains the owner until retired; native cannot start over it. Set `skill_root` to the installed `luna-local-review-loop` skill root and keep `repo_root` pointed at the target checkout:

~~~sh
skill_root='/absolute/path/to/luna-local-review-loop'
repo_root='/absolute/path/to/repository'
~~~

Immediately after that preflight and before native spawn, the parent invokes `bash "$skill_root/scripts/cross-path-claim.sh" acquire --repo "$repo_root" --scope "$scope" --token "$native_task_id"`, using the stable unique native task identity as token. This atomic host-owned claim is keyed by the physical checkout identity and scope. The claim is distinct from the fallback registry: native neither reads nor writes registry state. For non-terminal continuation, native explicitly invokes `bash "$skill_root/scripts/cross-path-claim.sh" acquire --reenter --repo "$repo_root" --scope "$scope" --token "$native_task_id"`. After cleanup and terminal retirement, native invokes `bash "$skill_root/scripts/cross-path-claim.sh" release --repo "$repo_root" --scope "$scope" --token "$native_task_id"`; release never guesses ownership. The fallback launcher invokes `run-worker.sh launch`, which uses `--reenter-or-acquire` with stable token `task-$TASK_ID` before its registry reservation: a parent-held same-owner claim is explicitly re-entered, while a missing claim is acquired atomically. Both paths hold their claim through lifecycle and cleanup. An unavailable or competing claim is a parent-action stop; neither path starts. This claim closes the check-then-start race in which a fallback controller could reserve the same scope after native preflight but before native startup.

Fallback launch runs `registry.sh preflight` inside cross-path claim setup: the claim key is derived without a checkout seal, its per-claim lock is acquired, existing project-local boundary, private registry-local ignore, effective root ignore, and schema-v1/v2 or pre-seal schema-v3 migration/recovery eligibility are validated, then the seal is validated or created and the claim is published. A failed preflight releases coordination without publishing a claim or creating a seal; registry and ignore bytes remain unchanged. A parent-held same-owner claim is explicitly re-entered by launch; a competing owner still conflicts. Native acquisition never reads or writes fallback registry state, and claim-before-reservation serialization remains required.

CLI fallback hosts use the same reviewer contract through `scripts/run-review.sh`, which invokes only gpt-5.6-sol/high with read-only sandboxing. If that route is unavailable, implementation may continue as fallback work but delivery remains Evidence blocked.

## CLI fallback: initialize

Run this section only after the native capability gate reports that native startup is unavailable, fallback ownership has been pinned or proven clear, the cross-path claim is acquired for the canonical checkout and immutable scope, and the CLI Sol-High reviewer route is available or explicitly Evidence blocked. Keep that claim through initialization. The launch command explicitly re-enters the same-owner claim with stable token `task-$TASK_ID`.

~~~sh
./luna-local-review-loop/scripts/init.sh --repo /absolute/path/to/repository
~~~

Fallback registry path is deterministic:

~~~text
<repository-root>/.agents/agent-registry/registry.json
~~~

Registry-owned fallback artifacts—registry locks, prompt snapshots, JSONL/stderr logs, results, descendant trackers, leases, task directories, and all other fallback state—stay below <repository-root>/.agents/agent-registry/. `registry.sh path --repo ...` always resolves this exact project-local authority; launch, continue, and tracker paths derive from its dirname. Repository-root `artifacts/` is never created or accepted. No environment-selected state root, temporary-directory registry, home-directory state record, Git-administration registry, or alternate path scan exists.

Two host-owned coordination artifacts are explicit exceptions to this registry-owned path boundary: `.luna-checkout-identity` lives in the physical Git administration directory, and `<git-common-dir>/.luna-cross-path-claims/<sha256-key>` lives in Git common metadata. They provide checkout-identity sealing and atomic native/fallback serialization; they are not fallback registry state, registry authority, worker/task artifacts, or alternate locators. No other skill-owned durable artifact uses Git administration/common metadata. Native still never initializes, reads, or writes the project-local fallback registry; fallback still acquires the claim before reserving that exact registry authority. Claim or seal validation remains fail-closed; unavailable or conflicting claims require parent action. Claim acquire and release serialize through a short-lived private lock for the same claim key; release validates owner and token under that lock and removes the validated claim before releasing it, so a delayed same-owner release cannot unlink a newly acquired claim. An unsafe or persistently busy lock fails closed.

Init may create the project-local boundary and add exactly one `.agents/agent-registry/` line to root `.gitignore`. That Git rule and the private mode-0600 registry-local `.gitignore` (whose final rule is `*`) provide repository visibility/confidentiality only; Git ignore is not a write-protection boundary. Workspace-write workers require Codex CLI `>= 0.147.0`, whose compiled OS sandbox recursively protects project `.agents` metadata. Older or unparseable versions fail before reservation; read-only workers remain supported. The parent must grant the OS sandbox boundary and product-owned Codex runtime state separately.

It rejects symlinked/non-directory ancestors, path escape, unsafe owner or permissions, symlinked/non-regular/multiply-linked registry files, unsafe `.gitignore`, and root ignore negations that expose representative registry, lock, candidate, or nested artifact paths. Registry directory is 0700; registry and other regular state files are 0600; new `.gitignore` is 0644; an existing caller-owned, non-group/world-writable `.gitignore` keeps its mode and unrelated lines remain unchanged. `--existing-path` is validation-only: it never repairs ignore files or project metadata.

## Identity and migrations

Identity uses canonical Git evidence, including physical Git administration and common-directory device/inode identities plus ordinary or linked-worktree backlink checks. A private random 256-bit lowercase-hex `.luna-checkout-identity` seal is atomically created in the physical Git administration directory and recorded only as auxiliary checkout evidence; it is never registry authority, a locator, a path, or a replacement for Git identity. The seal's content digest and device/inode identity are combined with Git identity, so missing, malformed, replaced, unsafe, or multiply-linked seals fail closed. Repository path is not identity. Moving the same physical ordinary or linked checkout keeps registry ownership and updates `repository_root`; copied/replacement repositories, copied linked-worktree aliases, reinitialized Git metadata, and ordinary `.git` aliases cannot reuse state.

Project-local schema-v3 registry contains:

- identity_ledger: append-only task history with immutable scope, sandbox, retry linkage, session, timestamps, and terminal evidence.
- workers: reserved, bound, or active rows only, including invocation PID/token/process identity and active child PGID/process identity.

Empty schema-v1 state migrates only with proven current-root ownership and zero worker rows. Live, malformed, foreign, or non-empty v1 state remains unchanged and prints previous-version recovery instructions. Empty local v2 state migrates after root ownership is proven: its prospective schema-v3 transformation is fully validated before any checkout seal is created, then only the validated sealed transformation is published. Malformed or unsafe v2 state leaves registry bytes and seal absence unchanged. A pre-seal schema-v3 registry migrates only in normal init after exact root, repository identity, physical checkout identity, and zero active workers are proven; launch preflight validates that eligibility without creating the seal. Retired `identity_ledger` history is preserved. Existing-path recovery never performs that migration and a missing seal fails unchanged. Older installations may have state outside project; retire live workers with previous version before installing this skill. This version never finds, reads, copies, or repairs that state automatically.

## CLI fallback: launch and continue

The fallback controller uses `--reenter-or-acquire` with stable token `task-$TASK_ID` before `registry.sh reserve`: a missing claim is acquired atomically, while a parent-held same-owner claim is explicitly re-entered. The claim is held through the CLI worker and cleanup lifecycle and released only after the registry task is terminal. A non-terminal `needs_parent_action` checkpoint retains the claim, and the same task identity re-enters it for continuation. A legacy active project-local task created before cross-path claims may use the same primitive only after its exact active registry row is validated. Existing claims still require exact checkout identity, scope, and token ownership; a claim held by native, unavailable, malformed, or competing fallback work cannot be bypassed by reserving or continuing the fallback registry.

Every initial and continuation CLI worker prompt is materialized with the same sole-worker boundary: the worker performs its immutable scope directly and never spawns, delegates to, or hands work to another subagent. Caller-provided prompt text cannot remove that boundary.

~~~sh
./luna-local-review-loop/scripts/run-worker.sh launch \
  --repo /absolute/path/to/repository \
  --task-id issue-123-worker-1 \
  --scope 'owned paths: src/a.ts; task: implement validator; no commits' \
  --sandbox workspace-write \
  --prompt-file /absolute/path/to/task.txt
~~~

Launch snapshots prompt into project-local artifacts, reserves task plus invocation, runs read-only handshake, binds and activates durable Codex session, resumes exact session from canonical repository root, and emits only final structured result on stdout. Handshake never consumes task prompt. First resume inherits pre-opened prompt descriptor; continuation reads supplied parent-result prompt. Resume and continuation explicitly pass `--ignore-user-config`, `--strict-config`, and the registered sandbox mode; these flags do not replace the OS sandbox boundary.

Use continue only for same active task after parent action:

~~~sh
./luna-local-review-loop/scripts/run-worker.sh continue \
  --repo /absolute/path/to/repository \
  --task-id issue-123-worker-1 \
  --prompt-file /absolute/path/to/parent-result.txt
~~~

Use finish for failed, blocked, or interrupted. completed requires validated structured result from token-owning runner. Retry exact scope with fresh task ID plus --retry-of; retry inherits sandbox and accepts one child per attempt.

CLI-fallback review route:

~~~sh
./luna-local-review-loop/scripts/run-review.sh \
  --repo /absolute/path/to/repository \
  --prompt-file /absolute/path/to/full-review-prompt.txt
~~~

The prompt is read-only and must include the complete current contract, applicable guidance, target revisions, full diff, and validation evidence. A fresh invocation is required for every review and re-review; Sol-High identity and configuration must be verified from the result.

## Safety contract

- Atomic registry lock stores owner PID and process-start identity.
- A host-owned cross-path claim atomically serializes native spawn and fallback reservation for each canonical checkout and immutable scope; it is held through the selected lifecycle and released only after cleanup.
- Invocation claims, sessions, process groups, descendants, leases, and retries stay pinned to immutable task scope.
- Stale claims require confirmed owner exit and clean empty descendant evidence.
- Missing tracker/lease evidence, PID or PGID reuse, ambiguous probes, and unsafe files fail closed.
- Codex children use separate process groups and start gates; cleanup drains only verified process instances.
- Registry-owned task artifacts are single-link regular 0600 files below task directories; directories are real 0700 directories. Host-owned claim and seal files follow their separate Git metadata paths and the same private-file requirements.
- Prompt snapshot is immutable for first resume; sparse attempts never overwrite existing files.
- Workers never daemonize, double-fork, start persistent services, stage, commit, push, review combined changes, or manage GitHub/CI.
- A spawned worker is the sole worker for its immutable task and never spawns, delegates to, or hands work to another subagent.

Before closing a parent goal for a CLI-fallback run:

~~~sh
./luna-local-review-loop/scripts/registry.sh assert-no-active --repo /absolute/path/to/repository
./luna-local-review-loop/scripts/registry.sh assert-empty --repo /absolute/path/to/repository
~~~

Do not run these registry cleanup commands for a native run. If CLI-fallback cleanup cannot be proven, preserve active state and report the blocker. Never delete registry state or Codex history.

## Structured result

See references/worker-result.schema.json. Every native prompt carries this contract, and the parent validates native results before acceptance. completed needs one or more passed validators, non-empty evidence, and no unresolved work. needs_parent_action keeps task active and requires non-empty parentAction; terminal outcomes use null.

## Validation

~~~sh
./luna-local-review-loop/scripts/test-init.sh
bash luna-local-review-loop/scripts/test-cross-path-claim.sh
bash luna-local-review-loop/scripts/test-path-selection.sh
bash luna-local-review-loop/scripts/test-review-routing.sh
bash -n luna-local-review-loop/scripts/*.sh
shellcheck luna-local-review-loop/scripts/*.sh
python3 /path/to/skill-creator/scripts/quick_validate.py luna-local-review-loop
git diff --check
~~~

Parent performs the final real forward test and evaluates each fresh Sol-High review. Do not launch subworkers during this skill update. The native/fallback contract is documented at the top of this README.
