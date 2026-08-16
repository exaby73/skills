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

An array pipeline could express the same behavior, but the submitted loop is safe, clear, tested, and contract-compliant.

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

The short function name is a preference-level concern. The missing required audit event is not.

## Fixture: clean-change

### Repository `AGENTS.md`

```md
# Repository policy

Read `docs/job-contract.md`. Review retries for idempotency and observable failure evidence.
```

### Linked `docs/job-contract.md`

```md
# Job contract

The worker must ignore an already-processed delivery key and record failures with the delivery key and error category.
```

### Diff

```diff
+ export async function deliver(job: DeliveryJob) {
+   if (await deliveries.exists(job.key)) return { status: "already-processed" };
+   try {
+     await provider.send(job.payload);
+     await deliveries.recordSuccess(job.key);
+     return { status: "delivered" };
+   } catch (error) {
+     await failures.record({ key: job.key, category: classify(error) });
+     throw error;
+   }
+ }
```

Relevant tests cover first delivery, duplicate delivery, provider failure categorization, and success recording.
