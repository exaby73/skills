# Calibration fixture catalog

Use these neutral fixtures to test review calibration. Each fixture represents a repository snapshot. Give an independent reviewer only one fixture's input section and the `code-reviewer` skill. Compare the result with `expected-results.json` after the reviewer concludes.

## Fixture: material-defect

### Repository `AGENTS.md`

```md
# Repository policy

Read `docs/review-policy.md` before review. Tenant isolation and balance preservation are blocking contracts.
```

### Linked `docs/review-policy.md`

```md
# Review policy

Every account lookup and mutation must scope by both account ID and tenant ID. Account renames must not alter balances.
```

### Change contract

`PATCH /accounts/:id` renames an account owned by the authenticated tenant. A request must never observe or mutate another tenant's account.

### Diff

```diff
 export async function renameAccount(tenantId: string, accountId: string, name: string) {
-  const account = await db.accounts.findFirst({ where: { tenantId, id: accountId } });
-  if (!account) throw new NotFoundError();
-  return db.accounts.update({ where: { tenantId, id: accountId }, data: { name } });
+  const account = await db.accounts.findFirst({ where: { id: accountId } });
+  if (!account) throw new NotFoundError();
+  return db.accounts.update({ where: { id: accountId }, data: { name, balance: 0 } });
 }
```

## Fixture: preference-only

### Repository `AGENTS.md`

```md
# Repository policy

Readable TypeScript and behavior-focused tests are required. No abstraction style is preferred when behavior remains clear.
```

### Change contract

Return enabled channel names in their existing order.

### Diff

```diff
+ export function enabledChannelNames(channels: Channel[]): string[] {
+   const names: string[] = [];
+   for (const channel of channels) {
+     if (channel.enabled) names.push(channel.name);
+   }
+   return names;
+ }

+ test("returns enabled channel names in source order", () => {
+   expect(enabledChannelNames([
+     { name: "email", enabled: true },
+     { name: "sms", enabled: false },
+     { name: "push", enabled: true },
+   ])).toEqual(["email", "push"]);
+ });
```

## Fixture: mixed-guidance

### Repository `AGENTS.md`

```md
# Repository policy

Read `policies/access-review.md`. Function naming is team discretion when intent remains clear.
```

### Linked `policies/access-review.md`

```md
# Access review

Every successful role change must append an audit event containing actor, subject, prior role, and new role in the same transaction.
```

### Change contract

Administrators may change a member's role. Successful changes must remain auditable.

### Diff

```diff
+ export async function alter(memberId: string, role: Role, actorId: string) {
+   return db.transaction(async (tx) => {
+     const member = await tx.members.findById(memberId);
+     if (!member) throw new NotFoundError();
+     await tx.members.update(memberId, { role });
+     return { ...member, role };
+   });
+ }
```

## Fixture: clean-change

### Repository `AGENTS.md`

```md
# Repository policy

Read `docs/job-contract.md`. Review retries for idempotency and observable failure evidence.
```

### Linked `docs/job-contract.md`

```md
# Job contract

The worker must atomically claim a delivery key before sending, pass that key to an idempotent provider, ignore processed or in-flight keys, and record failures with the delivery key and error category. Releasing a failed claim is safe because the provider deduplicates retries by that key.
```

### Diff

```diff
+ export async function deliver(job: DeliveryJob) {
+   const claim = await deliveries.claim(job.key);
+   if (claim === "processed") return { status: "already-processed" };
+   if (claim === "in-flight") return { status: "pending" };
+   try {
+     await provider.send(job.payload, { idempotencyKey: job.key });
+     await deliveries.recordSuccess(job.key);
+     return { status: "delivered" };
+   } catch (error) {
+     try {
+       await failures.record({ key: job.key, category: classify(error) });
+     } finally {
+       await deliveries.release(job.key);
+     }
+     throw error;
+   }
+ }
```

Relevant tests cover atomic claiming, first delivery, duplicate and in-flight delivery, provider failure categorization, claim release when failure recording fails, provider idempotency when success recording fails, and success recording.
