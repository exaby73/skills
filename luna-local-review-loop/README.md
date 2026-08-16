# Luna Local Review Loop

Reusable protocol for bounded local repository work with one fresh resumable worker per task. Parent owns permissions, validation judgment, review, cleanup judgment, and delivery. Worker owns one immutable scope and returns structured evidence.

## Initialize

~~~sh
./luna-local-review-loop/scripts/init.sh --repo /absolute/path/to/repository
~~~

Authoritative path is deterministic:

~~~text
<repository-root>/.agents/agent-registry/registry.json
~~~

Registry locks, prompt snapshots, JSONL/stderr logs, results, descendant trackers, leases, and all other skill-owned durable artifacts stay below <repository-root>/.agents/agent-registry/. `registry.sh path --repo ...` always resolves this path; launch, continue, and tracker paths derive from dirname of that exact authority. Repository-root `artifacts/` is never created or accepted. No environment-selected state root, temporary-directory registry, home-directory state record, or alternate path scan exists.

Init may create the project-local boundary and add exactly one `.agents/agent-registry/` line to root `.gitignore`. That Git rule and the private mode-0600 registry-local `.gitignore` (whose final rule is `*`) provide repository visibility/confidentiality only; Git ignore is not a write-protection boundary. Workspace-write workers require Codex CLI `>= 0.147.0`, whose compiled OS sandbox recursively protects project `.agents` metadata. Older or unparseable versions fail before reservation; read-only workers remain supported. The parent must grant the OS sandbox boundary and product-owned Codex runtime state separately.

It rejects symlinked/non-directory ancestors, path escape, unsafe owner or permissions, symlinked/non-regular/multiply-linked registry files, unsafe `.gitignore`, and root ignore negations that expose representative registry, lock, candidate, or nested artifact paths. Registry directory is 0700; registry and other regular state files are 0600; new `.gitignore` is 0644; an existing caller-owned, non-group/world-writable `.gitignore` keeps its mode and unrelated lines remain unchanged. `--existing-path` is validation-only: it never repairs ignore files or project metadata.

## Identity and migrations

Identity uses canonical Git evidence, including physical Git administration and common-directory device/inode identities plus ordinary or linked-worktree backlink checks. A private random 256-bit lowercase-hex `.luna-checkout-identity` seal is atomically created in the physical Git administration directory and recorded only as auxiliary checkout evidence; it is never registry authority, a locator, a path, or a replacement for Git identity. The seal's content digest and device/inode identity are combined with Git identity, so missing, malformed, replaced, unsafe, or multiply-linked seals fail closed. Repository path is not identity. Moving the same physical ordinary or linked checkout keeps registry ownership and updates `repository_root`; copied/replacement repositories, copied linked-worktree aliases, reinitialized Git metadata, and ordinary `.git` aliases cannot reuse state.

Project-local schema-v3 registry contains:

- identity_ledger: append-only task history with immutable scope, sandbox, retry linkage, session, timestamps, and terminal evidence.
- workers: reserved, bound, or active rows only, including invocation PID/token/process identity and active child PGID/process identity.

Empty schema-v1 state migrates only with proven current-root ownership and zero worker rows. Live, malformed, foreign, or non-empty v1 state remains unchanged and prints previous-version recovery instructions. Empty local v2 state migrates after root ownership is proven: its prospective schema-v3 transformation is fully validated before any checkout seal is created, then only the validated sealed transformation is published. Malformed or unsafe v2 state leaves registry bytes and seal absence unchanged. A pre-seal schema-v3 registry migrates only in normal init after exact root, repository identity, physical checkout identity, and zero active workers are proven; retired `identity_ledger` history is preserved. Existing-path recovery never performs that migration and a missing seal fails unchanged. Older installations may have state outside project; retire live workers with previous version before installing this skill. This version never finds, reads, copies, or repairs that state automatically.

## Launch and continue

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

## Safety contract

- Atomic registry lock stores owner PID and process-start identity.
- Invocation claims, sessions, process groups, descendants, leases, and retries stay pinned to immutable task scope.
- Stale claims require confirmed owner exit and clean empty descendant evidence.
- Missing tracker/lease evidence, PID or PGID reuse, ambiguous probes, and unsafe files fail closed.
- Codex children use separate process groups and start gates; cleanup drains only verified process instances.
- Artifacts are single-link regular 0600 files below task directories; directories are real 0700 directories.
- Prompt snapshot is immutable for first resume; sparse attempts never overwrite existing files.
- Workers never daemonize, double-fork, start persistent services, stage, commit, push, review combined changes, or manage GitHub/CI.

Before closing parent goal:

~~~sh
./luna-local-review-loop/scripts/registry.sh assert-no-active --repo /absolute/path/to/repository
./luna-local-review-loop/scripts/registry.sh assert-empty --repo /absolute/path/to/repository
~~~

If cleanup cannot be proven, preserve active state and report blocker. Do not delete registry state or Codex history.

## Structured result

See references/worker-result.schema.json. completed needs one or more passed validators, non-empty evidence, and no unresolved work. needs_parent_action keeps task active and requires non-empty parentAction; terminal outcomes use null.

## Validation

~~~sh
./luna-local-review-loop/scripts/test-init.sh
bash -n luna-local-review-loop/scripts/*.sh
shellcheck luna-local-review-loop/scripts/*.sh
python3 /path/to/skill-creator/scripts/quick_validate.py luna-local-review-loop
git diff --check
~~~

Parent performs final real forward test and code review. Do not launch subworkers during this skill update.
