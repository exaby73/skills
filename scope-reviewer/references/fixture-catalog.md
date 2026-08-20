# Calibration fixture catalog

Use these neutral, deterministic input sections to exercise scope review. Give a reviewer one complete `### Fixture input` section and the `scope-reviewer` skill. Keep result data in the private reference file and do not provide another fixture during a run.

## Fixture: harbor-labels

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/label-contract.md`. Label normalization must be deterministic and storage changes are out of scope.
```

Linked `docs/label-contract.md`

```md
# Label contract

The formatter trims surrounding whitespace, rejects an empty normalized label with the existing validation error, preserves the original value for diagnostics, and has focused tests for whitespace and empty input.
```

Review target

- Target head: `1111111111111111111111111111111111111111`
- Comparison base: `0000000000000000000000000000000000000000`
- Commit list: `1111111 Add label formatter`

Change contract

Add `formatLabel` for the label-entry flow.

Amendments

- None supplied.

Explicit exclusions

- Do not change persistence, public endpoints, or the existing validation error.

**Dependencies and relationships**

- Dependency/relationship: the formatter depends on linked `docs/label-contract.md`.
- Authority/source: repository `AGENTS.md` names `docs/label-contract.md` as governing source.
- Exact revision or identity: `docs/label-contract.md@1111111111111111111111111111111111111111`.
- Relevant evidence: the linked contract's trimming, empty-input, original-value, and focused-test rules.
- Reload/reconciliation before judgment: reload the source at target head `1111111111111111111111111111111111111111` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.
- Out-of-scope user choices: `Expand this task`, `Create a follow-up issue`, `Explicitly defer/accept the risk`; reviewer must not choose.

Full diff

```diff
diff --git a/labels/format.py b/labels/format.py
new file mode 100644
--- /dev/null
+++ b/labels/format.py
@@
+def formatLabel(raw):
+    normalized = raw.strip()
+    if not normalized:
+        raise ValidationError("label cannot be empty")
+    return {"value": normalized, "original": raw}
diff --git a/labels/test_format.py b/labels/test_format.py
new file mode 100644
--- /dev/null
+++ b/labels/test_format.py
@@
+def test_format_label_trims_and_preserves_original():
+    assert formatLabel("  North  ") == {"value": "North", "original": "  North  "}
+
+def test_format_label_rejects_empty_normalized_value():
+    with raises(ValidationError):
+        formatLabel("   ")
```

Validation evidence

- The focused label tests passed at target head `1111111111111111111111111111111111111111`.
- The repository validation command passed.

Structured worker handoffs

- Worker `harbor-worker` reported the formatter and focused tests complete, with no changes to persistence or endpoints.

## Fixture: cobalt-parser

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/parser-contract.md`. Parsing changes must retain the established error category and include behavior-focused validation.
```

Linked `docs/parser-contract.md`

```md
# Parser contract

Normalize outer whitespace, reject blank normalized input with `ParseError("blank")`, return the original token for diagnostics, and add tests for both successful normalization and blank input.
```

Review target

- Target head: `2222222222222222222222222222222222222222`
- Comparison base: `0000000000000000000000000000000000000000`
- Commit list: `2222222 Normalize parser token`

Change contract

Update the token parser while preserving its public error behavior.

Amendments

- None supplied.

Explicit exclusions

- Do not change token persistence or error categories.

**Dependencies and relationships**

- Dependency/relationship: the token parser depends on linked `docs/parser-contract.md`.
- Authority/source: repository `AGENTS.md` names `docs/parser-contract.md` as governing source.
- Exact revision or identity: `docs/parser-contract.md@2222222222222222222222222222222222222222`.
- Relevant evidence: the linked contract's normalization, blank-input, original-token, and behavior-focused validation rules.
- Reload/reconciliation before judgment: reload the source at target head `2222222222222222222222222222222222222222` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.
- Out-of-scope user choices: `Expand this task`, `Create a follow-up issue`, `Explicitly defer/accept the risk`; reviewer must not choose.

Full diff

```diff
diff --git a/parser/token.py b/parser/token.py
--- a/parser/token.py
+++ b/parser/token.py
@@
 def parse_token(raw):
+    normalized = raw.strip()
+    return {"value": normalized, "original": raw}
```

Validation evidence

- A syntax check passed.
- No focused parser test result was supplied.

Structured worker handoffs

- Worker `cobalt-worker` handed off the parser target without focused parser test evidence.

## Fixture: linen-export

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/export-contract.md`. Export output is an external compatibility surface; preserve its ordering and Unicode content.
```

Linked `docs/export-contract.md`

```md
# Export contract

Add `serializeRecord` with stable key order, omit fields whose value is null, preserve Unicode characters, and cover each rule with focused tests.
```

Review target

- Target head: `3333333333333333333333333333333333333333`
- Comparison base: `0000000000000000000000000000000000000000`
- Commit list: `3333333 Add record serializer`

Change contract

Add a record serializer for the export flow.

Amendments

- None supplied.

Explicit exclusions

- Do not change import behavior or the record schema.

**Dependencies and relationships**

- Dependency/relationship: the record serializer depends on linked `docs/export-contract.md`.
- Authority/source: repository `AGENTS.md` names `docs/export-contract.md` as governing source.
- Exact revision or identity: `docs/export-contract.md@3333333333333333333333333333333333333333`.
- Relevant evidence: the linked contract's ordering, null-field, Unicode, and focused-test rules.
- Reload/reconciliation before judgment: reload the source at target head `3333333333333333333333333333333333333333` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.
- Out-of-scope user choices: `Expand this task`, `Create a follow-up issue`, `Explicitly defer/accept the risk`; reviewer must not choose.

Full diff

```diff
diff --git a/export/record.py b/export/record.py
new file mode 100644
--- /dev/null
+++ b/export/record.py
@@
+def serializeRecord(record):
+    pairs = []
+    for key in ("id", "title", "note"):
+        value = record.get(key)
+        if value is not None:
+            pairs.append((key, value))
+    return json.dumps(dict(pairs), ensure_ascii=False, separators=(",", ":"))
diff --git a/export/test_record.py b/export/test_record.py
new file mode 100644
--- /dev/null
+++ b/export/test_record.py
@@
+def test_serializer_omits_null_and_keeps_order():
+    assert serializeRecord({"note": None, "title": "Café", "id": 4}) == '{"id":4,"title":"Café"}'
```

Validation evidence

- Focused serializer tests passed at target head `3333333333333333333333333333333333333333`.
- The compatibility check passed.

Structured worker handoffs

- Worker `linen-worker` reported stable ordering and Unicode coverage, and identified no changes outside export.

## Fixture: ember-report

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/report-contract.md`. Reporting changes must not alter profile data or profile presentation.
```

Linked `docs/report-contract.md`

```md
# Report contract

Add `formatReportDate` for the report view, retain the current report field order, and add a focused test. Profile files are explicitly excluded.
```

Review target

- Target head: `4444444444444444444444444444444444444444`
- Comparison base: `0000000000000000000000000000000000000000`
- Commit list: `4444444 Format report dates`

Change contract

Add date formatting to reports.

Amendments

- None supplied.

Explicit exclusions

- Do not change `profiles/` or any account-facing presentation.

**Dependencies and relationships**

- Dependency/relationship: the report formatter depends on linked `docs/report-contract.md`.
- Authority/source: repository `AGENTS.md` names `docs/report-contract.md` as governing source.
- Exact revision or identity: `docs/report-contract.md@4444444444444444444444444444444444444444`.
- Relevant evidence: the linked contract's UTC formatting, field-order, focused-test, and profile-exclusion rules.
- Reload/reconciliation before judgment: reload the source at target head `4444444444444444444444444444444444444444` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.
- Out-of-scope user choices: `Expand this task`, `Create a follow-up issue`, `Explicitly defer/accept the risk`; reviewer must not choose.

Full diff

```diff
diff --git a/reports/date.py b/reports/date.py
new file mode 100644
--- /dev/null
+++ b/reports/date.py
@@
+def formatReportDate(value):
+    return value.astimezone(UTC).strftime("%Y-%m-%d")
diff --git a/reports/test_date.py b/reports/test_date.py
new file mode 100644
--- /dev/null
+++ b/reports/test_date.py
@@
+def test_report_date_uses_utc_day():
+    assert formatReportDate(sample_value) == "2026-08-20"
diff --git a/profiles/labels.txt b/profiles/labels.txt
--- a/profiles/labels.txt
+++ b/profiles/labels.txt
@@
-display_name
+display_name
+preferred_name
```

Validation evidence

- Report tests passed at target head `4444444444444444444444444444444444444444`.
- No profile test was run.

Structured worker handoffs

- Worker `ember-worker` reported the report formatter and focused test complete.

## Fixture: maple-schedule

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/schedule-contract.md`. Scheduling behavior must preserve invalid-input errors and must not change account summaries.
```

Linked `docs/schedule-contract.md`

```md
# Schedule contract

Add `nextRun` that converts a local timestamp to UTC, preserves the existing invalid-time error, and includes tests for a daylight-saving boundary. Account-summary behavior is explicitly excluded.
```

Review target

- Target head: `5555555555555555555555555555555555555555`
- Comparison base: `0000000000000000000000000000000000000000`
- Commit list: `5555555 Add next-run calculation`

Change contract

Add the next-run calculation for scheduled jobs.

Amendments

- None supplied.

Explicit exclusions

- Do not change `accounts/` or alter account-summary fields.

**Dependencies and relationships**

- Dependency/relationship: the next-run calculation depends on linked `docs/schedule-contract.md` and relates to account-summary behavior.
- Authority/source: repository `AGENTS.md` names `docs/schedule-contract.md` as governing source.
- Exact revision or identity: `docs/schedule-contract.md@5555555555555555555555555555555555555555`.
- Relevant evidence: the linked contract's UTC conversion, invalid-time, daylight-saving, and account-summary exclusion rules.
- Reload/reconciliation before judgment: reload the source at target head `5555555555555555555555555555555555555555` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.
- Out-of-scope user choices: `Expand this task`, `Create a follow-up issue`, `Explicitly defer/accept the risk`; reviewer must not choose.

Full diff

```diff
diff --git a/schedule/next_run.py b/schedule/next_run.py
new file mode 100644
--- /dev/null
+++ b/schedule/next_run.py
@@
+def nextRun(local_value, zone):
+    parsed = parse_local(local_value, zone)
+    return parsed.replace(tzinfo=zone)
diff --git a/schedule/test_next_run.py b/schedule/test_next_run.py
new file mode 100644
--- /dev/null
+++ b/schedule/test_next_run.py
@@
+def test_next_run_rejects_invalid_time():
+    with raises(InvalidSchedule):
+        nextRun("not-a-time", zone)
diff --git a/accounts/summary.py b/accounts/summary.py
--- a/accounts/summary.py
+++ b/accounts/summary.py
@@
-    return {"total": total, "currency": currency}
+    return {"total": total}
```

Validation evidence

- The schedule syntax check passed at target head `5555555555555555555555555555555555555555`.
- The daylight-saving test result was not supplied.

Structured worker handoffs

- Worker `maple-worker` handed off the schedule target without daylight-saving test evidence.

## Fixture: quartz-policy

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/compatibility.md` and `docs/migration-notes.md`. Resolve source precedence before deciding whether existing records may change.
```

Linked `docs/compatibility.md`

```md
# Compatibility rule

Existing records retain their stored render mode. Only records created after the target may use the new mode.
```

Linked `docs/migration-notes.md`

```md
# Migration note

The target changes existing records to the compact render mode as part of the same release. This note has the same revision label as the compatibility rule, and no authority order is supplied.
```

Review target

- Target head: `6666666666666666666666666666666666666666`
- Comparison base: `0000000000000000000000000000000000000000`
- Commit list: `6666666 Change render mode`

Change contract

Change new records to compact render mode and preserve compatibility for existing records.

Amendments

- An amendment says migration may update existing records when migration evidence is present.

Explicit exclusions

- Do not change unrelated record fields.

**Dependencies and relationships**

- Dependency/relationship: render mode depends on linked `docs/compatibility.md`, linked `docs/migration-notes.md`, and the migration amendment.
- Authority/source: repository `AGENTS.md` names both linked documents; their precedence must be resolved before judgment.
- Exact revision or identity: `docs/compatibility.md@6666666666666666666666666666666666666666` and `docs/migration-notes.md@6666666666666666666666666666666666666666`.
- Relevant evidence: the linked documents conflict about existing records, so migration evidence and a source-precedence decision are required.
- Reload/reconciliation before judgment: reload both sources at target head `6666666666666666666666666666666666666666` and reconcile their authority, identities, evidence, amendment, full diff, and handoff claims before judgment.
- Out-of-scope user choices: `Expand this task`, `Create a follow-up issue`, `Explicitly defer/accept the risk`; reviewer must not choose.

Full diff

```diff
diff --git a/render/mode.py b/render/mode.py
--- a/render/mode.py
+++ b/render/mode.py
@@
 def mode_for(record):
-    return record.mode
+    return "compact" if record.is_existing else "compact"
```

Validation evidence

- The general test command passed at target head `6666666666666666666666666666666666666666`.
- No migration artifact or source-precedence decision was supplied.

Structured worker handoffs

- Worker `quartz-worker` reported the render-mode change complete and cited both linked documents without resolving their conflict.
