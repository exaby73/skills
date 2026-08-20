#!/usr/bin/env python3
"""Validate the generic scope-reviewer fixture contract."""

from __future__ import annotations

import ast
import json
import re
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parent.parent
SKILL_PATH = SKILL_ROOT / "SKILL.md"
OPENAI_PATH = SKILL_ROOT / "agents" / "openai.yaml"
CATALOG_PATH = SKILL_ROOT / "references" / "fixture-catalog.md"
EXPECTED_PATH = SKILL_ROOT / "references" / "expected-results.json"
SCRIPT_PATH = SKILL_ROOT / "scripts" / "test_fixtures.py"

EXPECTED_FILES = {
    Path("SKILL.md"),
    Path("agents/openai.yaml"),
    Path("references/fixture-catalog.md"),
    Path("references/expected-results.json"),
    Path("scripts/test_fixtures.py"),
}
EXPECTED_DIRECTORIES = {
    Path("agents"),
    Path("references"),
    Path("scripts"),
}
FIXTURE_DECISIONS = {
    "harbor-labels": "Approved",
    "cobalt-parser": "Evidence blocked",
    "linen-export": "Approved",
    "ember-report": "Request changes",
    "maple-schedule": "Evidence blocked",
    "quartz-policy": "Evidence blocked",
}
CONTRADICTORY_FIXTURES = {"quartz-policy"}
STATUSES = {"Implemented", "Partial", "Missing", "Unverifiable"}
FIXTURE_SEMANTIC_MARKERS = {
    "harbor-labels": (
        "Linked `docs/label-contract.md`\n",
        "Target head: `1111111111111111111111111111111111111111`\n",
        "diff --git a/labels/format.py b/labels/format.py\n",
        "+    normalized = raw.strip()\n",
        "+    if not normalized:\n",
        "- The focused label tests passed at target head `1111111111111111111111111111111111111111`.\n",
    ),
    "cobalt-parser": (
        "Linked `docs/parser-contract.md`\n",
        "Target head: `2222222222222222222222222222222222222222`\n",
        "diff --git a/parser/token.py b/parser/token.py\n",
        "+    normalized = raw.strip()\n",
        "- No focused parser test result was supplied.\n",
    ),
    "linen-export": (
        "Linked `docs/export-contract.md`\n",
        "Target head: `3333333333333333333333333333333333333333`\n",
        "diff --git a/export/record.py b/export/record.py\n",
        "+        if value is not None:\n",
        "diff --git a/export/test_record.py b/export/test_record.py\n",
        "- Focused serializer tests passed at target head `3333333333333333333333333333333333333333`.\n",
    ),
    "ember-report": (
        "Linked `docs/report-contract.md`\n",
        "Target head: `4444444444444444444444444444444444444444`\n",
        "diff --git a/reports/date.py b/reports/date.py\n",
        "diff --git a/reports/test_date.py b/reports/test_date.py\n",
        "diff --git a/profiles/labels.txt b/profiles/labels.txt\n",
        "- Report tests passed at target head `4444444444444444444444444444444444444444`.\n",
        "- No profile test was run.\n",
    ),
    "maple-schedule": (
        "Linked `docs/schedule-contract.md`\n",
        "Target head: `5555555555555555555555555555555555555555`\n",
        "diff --git a/schedule/next_run.py b/schedule/next_run.py\n",
        "diff --git a/schedule/test_next_run.py b/schedule/test_next_run.py\n",
        "diff --git a/accounts/summary.py b/accounts/summary.py\n",
        "- The daylight-saving test result was not supplied.\n",
    ),
    "quartz-policy": (
        "Linked `docs/compatibility.md`\n",
        "Linked `docs/migration-notes.md`\n",
        "Target head: `6666666666666666666666666666666666666666`\n",
        "diff --git a/render/mode.py b/render/mode.py\n",
        "- The general test command passed at target head `6666666666666666666666666666666666666666`.\n",
        "- No migration artifact or source-precedence decision was supplied.\n",
    ),
}
DEPENDENCY_SEMANTIC_MARKERS = {
    "harbor-labels": (
        "**Dependencies and relationships**\n",
        "- Dependency/relationship: the formatter depends on linked `docs/label-contract.md`.\n",
        "- Authority/source: repository `AGENTS.md` names `docs/label-contract.md` as governing source.\n",
        "- Exact revision or identity: `docs/label-contract.md@1111111111111111111111111111111111111111`.\n",
        "- Relevant evidence: the linked contract's trimming, empty-input, original-value, and focused-test rules.\n",
        "- Reload/reconciliation before judgment: reload the source at target head `1111111111111111111111111111111111111111` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.\n",
    ),
    "cobalt-parser": (
        "**Dependencies and relationships**\n",
        "- Dependency/relationship: the token parser depends on linked `docs/parser-contract.md`.\n",
        "- Authority/source: repository `AGENTS.md` names `docs/parser-contract.md` as governing source.\n",
        "- Exact revision or identity: `docs/parser-contract.md@2222222222222222222222222222222222222222`.\n",
        "- Relevant evidence: the linked contract's normalization, blank-input, original-token, and behavior-focused validation rules.\n",
        "- Reload/reconciliation before judgment: reload the source at target head `2222222222222222222222222222222222222222` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.\n",
    ),
    "linen-export": (
        "**Dependencies and relationships**\n",
        "- Dependency/relationship: the record serializer depends on linked `docs/export-contract.md`.\n",
        "- Authority/source: repository `AGENTS.md` names `docs/export-contract.md` as governing source.\n",
        "- Exact revision or identity: `docs/export-contract.md@3333333333333333333333333333333333333333`.\n",
        "- Relevant evidence: the linked contract's ordering, null-field, Unicode, and focused-test rules.\n",
        "- Reload/reconciliation before judgment: reload the source at target head `3333333333333333333333333333333333333333` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.\n",
    ),
    "ember-report": (
        "**Dependencies and relationships**\n",
        "- Dependency/relationship: the report formatter depends on linked `docs/report-contract.md`.\n",
        "- Authority/source: repository `AGENTS.md` names `docs/report-contract.md` as governing source.\n",
        "- Exact revision or identity: `docs/report-contract.md@4444444444444444444444444444444444444444`.\n",
        "- Relevant evidence: the linked contract's UTC formatting, field-order, focused-test, and profile-exclusion rules.\n",
        "- Reload/reconciliation before judgment: reload the source at target head `4444444444444444444444444444444444444444` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.\n",
    ),
    "maple-schedule": (
        "**Dependencies and relationships**\n",
        "- Dependency/relationship: the next-run calculation depends on linked `docs/schedule-contract.md` and relates to account-summary behavior.\n",
        "- Authority/source: repository `AGENTS.md` names `docs/schedule-contract.md` as governing source.\n",
        "- Exact revision or identity: `docs/schedule-contract.md@5555555555555555555555555555555555555555`.\n",
        "- Relevant evidence: the linked contract's UTC conversion, invalid-time, daylight-saving, and account-summary exclusion rules.\n",
        "- Reload/reconciliation before judgment: reload the source at target head `5555555555555555555555555555555555555555` and reconcile it with the change contract, full diff, validation evidence, and handoff claims before judgment.\n",
    ),
    "quartz-policy": (
        "**Dependencies and relationships**\n",
        "- Dependency/relationship: render mode depends on linked `docs/compatibility.md`, linked `docs/migration-notes.md`, and the migration amendment.\n",
        "- Authority/source: repository `AGENTS.md` names both linked documents; their precedence must be resolved before judgment.\n",
        "- Exact revision or identity: `docs/compatibility.md@6666666666666666666666666666666666666666` and `docs/migration-notes.md@6666666666666666666666666666666666666666`.\n",
        "- Relevant evidence: the linked documents conflict about existing records, so migration evidence and a source-precedence decision are required.\n",
        "- Reload/reconciliation before judgment: reload both sources at target head `6666666666666666666666666666666666666666` and reconcile their authority, identities, evidence, amendment, full diff, and handoff claims before judgment.\n",
    ),
}
OUT_OF_SCOPE_CHOICES_MARKER = (
    "- Out-of-scope user choices: `Expand this task`, `Create a follow-up issue`, "
    "`Explicitly defer/accept the risk`; reviewer must not choose.\n"
)
FIXTURE_DIFF_PATHS = {
    "harbor-labels": ("labels/format.py", "labels/test_format.py"),
    "cobalt-parser": ("parser/token.py",),
    "linen-export": ("export/record.py", "export/test_record.py"),
    "ember-report": ("reports/date.py", "reports/test_date.py", "profiles/labels.txt"),
    "maple-schedule": ("schedule/next_run.py", "schedule/test_next_run.py", "accounts/summary.py"),
    "quartz-policy": ("render/mode.py",),
}
EXPECTED_COVERAGE_ANCHORS = {
    "harbor-labels": {
        "R1": ("Implemented", ("trimming", "empty normalized"), ("labels/format.py", "trim", "empty")),
        "R2": ("Implemented", ("original value", "diagnostics"), ("labels/format.py", "original")),
        "R3": ("Implemented", ("focused", "whitespace", "empty"), ("labels/test_format.py", "empty")),
        "R4": (
            "Implemented",
            ("dependency", "authority/source", "exact revision or immutable identity", "relevant evidence", "reload/reconciliation"),
            ("docs/label-contract.md", "1111111111111111111111111111111111111111", "relevant evidence", "reload"),
        ),
    },
    "cobalt-parser": {
        "R1": ("Partial", ("normalization", "blank normalized"), ("parser/token.py", "trim", "empty")),
        "R2": ("Unverifiable", ("original token", "diagnostics"), ("parser/token.py", "focused parser")),
        "R3": ("Missing", ("successful-normalization", "blank-input"), ("full diff", "no parser test")),
        "R4": (
            "Unverifiable",
            ("dependency", "authority/source", "exact revision or immutable identity", "relevant evidence", "reload/reconciliation"),
            ("docs/parser-contract.md", "2222222222222222222222222222222222222222", "dependency", "reload"),
        ),
    },
    "linen-export": {
        "R1": ("Implemented", ("stable key order",), ("export/record.py", "order")),
        "R2": ("Implemented", ("null", "omission"), ("export/record.py", "skip", "none")),
        "R3": ("Implemented", ("unicode",), ("ensure_ascii", "café")),
        "R4": ("Implemented", ("focused tests",), ("export/test_record.py", "null", "ordering", "unicode")),
        "R5": (
            "Implemented",
            ("dependency", "authority/source", "exact revision or immutable identity", "relevant evidence", "reload/reconciliation"),
            ("docs/export-contract.md", "3333333333333333333333333333333333333333", "relevant evidence", "reload"),
        ),
    },
    "ember-report": {
        "R1": ("Implemented", ("utc", "report-date"), ("reports/date.py", "utc")),
        "R2": ("Implemented", ("field order",), ("full diff", "reports/date.py", "reports/test_date.py")),
        "R3": ("Implemented", ("focused formatter test",), ("reports/test_date.py", "utc")),
        "R4": (
            "Implemented",
            ("dependency", "authority/source", "exact revision or immutable identity", "relevant evidence", "reload/reconciliation"),
            ("docs/report-contract.md", "4444444444444444444444444444444444444444", "relevant evidence", "reload"),
        ),
    },
    "maple-schedule": {
        "R1": ("Partial", ("local timestamp", "utc"), ("schedule/next_run.py", "local zone", "utc")),
        "R2": ("Unverifiable", ("invalid-time error",), ("parse_local", "invalid-path test", "focused schedule")),
        "R3": ("Missing", ("daylight-saving boundary",), ("full diff", "daylight-saving")),
        "R4": (
            "Unverifiable",
            ("dependency", "authority/source", "exact revision or immutable identity", "relevant evidence", "reload/reconciliation"),
            ("docs/schedule-contract.md", "5555555555555555555555555555555555555555", "dependency", "reload"),
        ),
    },
    "quartz-policy": {
        "R1": ("Unverifiable", ("source precedence", "migration"), ("exact diff", "existing", "new", "conflict")),
        "R2": (
            "Unverifiable",
            ("dependency", "authority/source", "exact revision or immutable identity", "relevant evidence", "reload/reconciliation"),
            ("docs/compatibility.md", "docs/migration-notes.md", "dependency", "reload"),
        ),
    },
}
DEPENDENCY_COVERAGE_CANONICAL = {
    "harbor-labels": (
        "R4",
        "Implemented",
        "The review requires dependency and relationship discovery, the dependency authority/source, its exact revision or immutable identity, relevant evidence, and reload/reconciliation before judgment.",
        "The linked docs/label-contract.md dependency has exact identity 1111111111111111111111111111111111111111; relevant evidence is reconciled after reload before judgment.",
    ),
    "cobalt-parser": (
        "R4",
        "Unverifiable",
        "The review requires dependency and relationship discovery, the dependency authority/source, its exact revision or immutable identity, relevant evidence, and reload/reconciliation before judgment.",
        "The linked docs/parser-contract.md dependency has exact identity 2222222222222222222222222222222222222222, but no dependency reload/reconciliation evidence was supplied at target head.",
    ),
    "linen-export": (
        "R5",
        "Implemented",
        "The review requires dependency and relationship discovery, the dependency authority/source, its exact revision or immutable identity, relevant evidence, and reload/reconciliation before judgment.",
        "The linked docs/export-contract.md dependency has exact identity 3333333333333333333333333333333333333333; relevant evidence is reconciled after reload before judgment.",
    ),
    "ember-report": (
        "R4",
        "Implemented",
        "The review requires dependency and relationship discovery, the dependency authority/source, its exact revision or immutable identity, relevant evidence, and reload/reconciliation before judgment.",
        "The linked docs/report-contract.md dependency has exact identity 4444444444444444444444444444444444444444; relevant evidence is reconciled after reload before judgment.",
    ),
    "maple-schedule": (
        "R4",
        "Unverifiable",
        "The review requires dependency and relationship discovery, the dependency authority/source, its exact revision or immutable identity, relevant evidence, and reload/reconciliation before judgment.",
        "The linked docs/schedule-contract.md dependency has exact identity 5555555555555555555555555555555555555555, but no dependency reload/reconciliation evidence was supplied at target head.",
    ),
    "quartz-policy": (
        "R2",
        "Unverifiable",
        "The review requires dependency and relationship discovery, each dependency authority/source, exact revision or immutable identity, relevant evidence, and reload/reconciliation before judgment.",
        "The linked docs/compatibility.md and docs/migration-notes.md dependencies are recorded; each dependency has exact identity 6666666666666666666666666666666666666666, but their conflicting evidence and unresolved reload/reconciliation prevent judgment.",
    ),
}
FINDING_KEYS = {
    "severity",
    "kind",
    "scenario",
    "impact",
    "failedGuard",
    "evidence",
    "governingCriterion",
    "fixBoundary",
}
FAILED_GUARD_CONTROL = re.compile(r"\b(?:guard|control)s?\b", re.IGNORECASE)
FAILED_GUARD_REASON = re.compile(
    r"\b(?:because|since|due\s+to|without|when|while|fails?|failed|missing|"
    r"absent|unavailable|not\s+(?:supplied|run|present|guarded))\b",
    re.IGNORECASE,
)
FAILED_GUARD_EXPLANATION = re.compile(
    r"\b(?:because|since|due\s+to|without|when|while)\b",
    re.IGNORECASE,
)
OUT_OF_SCOPE_KEYS = {
    "behavior",
    "evidence",
    "authorization",
    "dispositionRequired",
    "choices",
}
COVERAGE_KEYS = {"id", "status", "contractEvidence", "diffEvidence"}
COMMON_RESULT_KEYS = {
    "id",
    "expectedDecision",
    "coverage",
    "blockingFindings",
    "outOfScopeInventory",
    "missingEvidence",
    "contradictoryEvidence",
    "dispositionRequiredBeforeBranchChange",
}
ALLOWED_IMPORT_MODULES = {"__future__", "ast", "json", "pathlib", "re"}
FORBIDDEN_DYNAMIC_EXECUTION = {"eval", "exec", "compile"}
FORBIDDEN_IMPORT_NAMES = {
    "__import__",
    "builtins",
    "importlib",
    "import_module",
    "find_spec",
    "module_from_spec",
    "exec_module",
    "load_module",
    "__builtins__",
    "__globals__",
    "__loader__",
    "__spec__",
    "__package__",
    "__cached__",
    "__getattribute__",
    "__getattr__",
    "__dict__",
    "__subclasses__",
    "sys",
    "globals",
    "locals",
    "vars",
    "getattr",
}
FORBIDDEN_SUBSCRIPT_NAMES = FORBIDDEN_DYNAMIC_EXECUTION | FORBIDDEN_IMPORT_NAMES
REQUIRED_FIXTURE_MARKERS = (
    "### Fixture input\n",
    "Repository `AGENTS.md`\n",
    "Review target\n",
    "Change contract\n",
    "Amendments\n",
    "Explicit exclusions\n",
    "Full diff\n",
    "Validation evidence\n",
    "Structured worker handoffs\n",
)
LINKED_SOURCE_MARKER = re.compile(r"^Linked `[^`\n]+`\n", re.MULTILINE)
NULL_OMISSION_HANDOFF_CLAIM = re.compile(
    r"(?:"
    r"\bnull(?:[\s-]+field(?:s)?)?[\s-]+omissions?\b"
    r"|\b(?:omit|omits|omitted|omitting|omission|omissions|skip|skips|"
    r"skipped|skipping|exclude|excludes|excluded|excluding|exclusion|"
    r"exclusions|remove|removes|removed|removing|removal|removals)\b"
    r"[^\n]*\bnull(?:[\s-]+field(?:s)?)?\b"
    r"|\bnull(?:[\s-]+field(?:s)?)?\b[^\n]*\b(?:omit|omits|omitted|omitting|"
    r"omission|omissions|skip|skips|skipped|skipping|exclude|excludes|"
    r"excluded|excluding|exclusion|exclusions|remove|removes|removed|"
    r"removing|removal|removals)\b"
    r")",
    re.IGNORECASE,
)
DISPOSITION_CHOICES = [
    "Expand this task",
    "Create a follow-up issue",
    "Explicitly defer/accept the risk",
]
REQUIRED_SKILL_PHRASES = {
    "exact target head",
    "full diff",
    "commit list",
    "issue/PR contract",
    "amendment",
    "explicit exclusion",
    "AGENTS.md",
    "linked product, engineering",
    "validation evidence",
    "Dependencies and relationships",
    "explicit dependency/relationship discovery",
    "dependency/relationship reconciliation row",
    "authority/source",
    "exact revision or immutable identity",
    "relevant evidence",
    "reload/reconciliation",
    "structured handoffs from every contributing worker",
    "navigation aids",
    "context compact, resume, or handoff",
    "coverage matrix",
    "Implemented",
    "Partial",
    "Missing",
    "Unverifiable",
    "Out-of-scope inventory",
    "Expand this task",
    "Create a follow-up issue",
    "Explicitly defer/accept the risk",
    "user/parent disposition",
    "read-only",
    "Concrete scenario",
    "Impact",
    "failedGuard",
    "Evidence",
    "Governing criterion",
    "Smallest reasonable fix boundary",
    "No blocking findings.",
    "Conclusion: Approved",
    "Conclusion: Request changes",
    "Conclusion: Evidence blocked",
}
FORBIDDEN_LEAKAGE = (
    "svel" + "te",
    "tail" + "wind",
    "shad" + "cn",
    "boot" + "strap",
    "chakra " + "ui",
    "ant " + "design",
    "vue" + "tify",
    "tfs" + "crims",
)
CATALOG_ANSWER_LEAKAGE = (
    "expecteddecision",
    "expected decision",
    "blockingfindings",
    "outofscopeinventory",
    "missingevidence",
    "requiredaction",
    "conclusion:",
    "conclusion",
    "finding",
    "answer",
    "decision:",
    "approved",
    "request changes",
    "evidence blocked",
    "expected answer",
    "correct answer",
    "answer hint",
    "expected outcome",
)
SCAFFOLD_MARKER = "TO" + "DO"
GENERICITY_TECHNOLOGY_PREFIX = (
    r"(?:"
    r"(?:requires?|needs?|mandates?|calls\s+for)\s+(?:the\s+)?use[\s-]+of|"
    r"requires?|needs?|mandates?|calls\s+for|depends\s+on|relies\s+on|"
    r"uses|using|must\s+use|based(?:\s+(?:on|upon)|-(?:on|upon))|"
    r"built\s+(?:around|with|on|upon)|built-upon|"
    r"architect(?:ed)?\s+(?:around|with|on)|designed\s+(?:around|with|on)|"
    r"standardizes?\s+on|center(?:s|ed)?\s+on|powered\s+by|written\s+in|"
    r"implemented\s+(?:in|with)|configured\s+for|"
    r"integrates?\s+with|compatible\s+with|runs?\s+on|"
    r"deploy(?:s|ed)?\s+(?:to|on)"
    r")"
)
GENERICITY_TECHNOLOGY_FILLERS = (
    r"(?:the|a|an|as|by|for|of|this|that|these|those|design|designed|very|well|carefully|deliberately|"
    r"intentionally|purposefully|[a-z][a-z'-]*ly|"
    r"preferred|chosen|selected|specified|recommended|designated|"
    r"default|current|primary|underlying|target|approved|curated|"
    r"canonical|intended|production-ready|particular|specific|named|"
    r"standard|stable|existing|new|current|primary|underlying|target|"
    r"framework|vendor|library|runtime|platform|database|service|provider|toolchain|"
    r"[a-z][a-z0-9'-]*)"
)
GENERICITY_TECHNOLOGY_FILLER_WORD = rf"(?:{GENERICITY_TECHNOLOGY_FILLERS})(?![._/-])"
GENERICITY_TECHNOLOGY_NAME = (
    r"(?P<name>(?:@?[A-Za-z][A-Za-z0-9_-]*)(?:[._/-][A-Za-z0-9_@-]+)*)"
)
GENERICITY_TECHNOLOGY_CLAIM = re.compile(
    rf"\b{GENERICITY_TECHNOLOGY_PREFIX}\b"
    rf"(?:\s*[,;:]\s*|\s+)"
    rf"(?:{GENERICITY_TECHNOLOGY_FILLER_WORD}(?:\s*[,;:]\s*|\s+)){{0,64}}"
    rf"[`\"']?"
    rf"{GENERICITY_TECHNOLOGY_NAME}[`\"']?"
    r"(?=[\s.,;:!?)]|$)",
    re.IGNORECASE,
)
GENERICITY_PASSIVE_TECHNOLOGY_CLAIM = re.compile(
    r"[`\"']?(?P<name>@?[A-Za-z][A-Za-z0-9_-]*(?:[._/-][A-Za-z0-9_@-]+)*)[`\"']?"
    r"\s+(?:is|are|was|were)\s+(?:required|needed|mandated)\s+by\b",
    re.IGNORECASE,
)
GENERICITY_LOWERCASE_TECHNOLOGY_NAME = re.compile(r"^[a-z][a-z0-9_-]*(?:js|css|html|sql)$")
GENERICITY_TECHNOLOGY_CONTEXT = re.compile(
    rf"\b(?:{GENERICITY_TECHNOLOGY_PREFIX}|use\s+of)\b"
    r"(?:[^\n.!?]|\.(?=[A-Za-z0-9])){0,80}\b"
    r"(?:framework|vendor|library|runtime|platform|database|service|provider|toolchain|technology)\b",
    re.IGNORECASE,
)
GENERICITY_DIRECT_USE_CLAIM = re.compile(
    r"\buse\s+(?:of\s+)?(?P<name>@?[A-Za-z][A-Za-z0-9_-]*(?:[._/-][A-Za-z0-9_@-]+)+)"
    r"(?=[\s.,;:!?)]|$)",
    re.IGNORECASE,
)
GENERICITY_NEUTRAL_NAMES = {"utc"}
REPOSITORY_GUIDANCE_FILE = re.compile(
    r"^(?:AGENTS|README|CONTRIBUTING|CHANGELOG|CODE_OF_CONDUCT|SECURITY|LICENSE)"
    r"\.(?:md|markdown|rst|adoc|txt)$",
    re.IGNORECASE,
)
REPOSITORY_GUIDANCE_PATH = re.compile(
    r"^(?:\.\.?/)?(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+"
    r"\.(?:md|markdown|rst|adoc|txt)$",
    re.IGNORECASE,
)
NEUTRAL_ANSWER_HINT_SEPARATOR = r"[=:\-\u2010\u2011\u2012\u2013\u2014\u2015\u2212\ufe63\uff0d\uff1a\uff1d]"
NEUTRAL_ANSWER_HINT_LABEL = re.compile(
    rf"^\s*(?:expected\s+)?(?:outcome|answer|decision|result|verdict|"
    rf"recommendation|approval|recommended[\s-]+disposition)\s*"
    rf"(?:{NEUTRAL_ANSWER_HINT_SEPARATOR}(?:\s*\S.*)?|\s*)$",
    re.IGNORECASE,
)
NEUTRAL_ANSWER_TERMINAL = (
    r"(?:accept(?:ed|able|ance)?|approv(?:e|ed|al)|pass(?:ed|es|ing)?|"
    r"reject(?:ed|ion)?|request\s+changes|evidence\s+blocked|"
    r"warrant(?:ed|able)?)"
)
NEUTRAL_ANSWER_HINT_STATEMENT = re.compile(
    r"\b(?:the\s+)?(?:outcome|answer|decision|result|verdict|recommendation|approval|"
    r"recommended[\s-]+disposition)\b"
    rf"(?:\s*{NEUTRAL_ANSWER_HINT_SEPARATOR}\s*|"
    r"\s+(?:[A-Za-z][A-Za-z'-]*,?\s+){0,6}"
    r"(?:is|was|are|were|has|have|had|became|become|becomes|"
    r"remain|remains|appear|appears|seem|seems|would\s+be)\s*,?\s+"
    r"(?:[A-Za-z][A-Za-z'-]*,?\s+){0,5})"
    rf"\b{NEUTRAL_ANSWER_TERMINAL}\b",
    re.IGNORECASE,
)
NEUTRAL_REVIEWER_DIRECTIVE = re.compile(
    r"^\s*(?:(?:the|a|an)\s+)?"
    r"(?:[A-Za-z][A-Za-z'-]*\s+){0,3}reviewer\s+"
    r"(?:should|must|shall|ought\s+to|would|recommends?|suggests?|advises?|endorses?)[\s-]+"
    r"(?:that\s+(?:we|you|the\s+reviewer|one)\s+)?"
    r"(?:approv(?:e|ed|es|ing)|accept(?:ed|s|ing)?|reject(?:ed|s|ing)?|"
    r"request(?:ed|s|ing)?\s+changes|evidence\s+blocked|"
    r"approval|acceptance|rejection|the\s+(?:approval|acceptance|rejection)\s+outcome)\s*[.!?]?\s*$",
    re.IGNORECASE | re.MULTILINE,
)
NEUTRAL_BARE_TERMINAL = re.compile(
    r"^\s*(?:approval|acceptance|rejection)\s+"
    r"(?:(?:is|was|would(?:\s+be)?|seems?|appears?)\s+)?"
    r"(?:warrant(?:ed|able)?|recommended|advised|appropriate|required|merited)"
    r"\s*[.!?]?\s*$",
    re.IGNORECASE | re.MULTILINE,
)
NEUTRAL_STANDALONE_TERMINAL = re.compile(
    rf"^\s*{NEUTRAL_ANSWER_TERMINAL}\s*[.!?]?\s*$",
    re.IGNORECASE | re.MULTILINE,
)
NEUTRAL_RECOMMENDATION_DIRECTIVE = re.compile(
    r"^\s*(?:(?:i|we|they|the\s+reviewer|a\s+reviewer|reviewer)\s+)?"
    r"recommend(?:s?|ed|ing)?"
    r"(?:[\s-]+that(?:\s+(?:we|you|the\s+reviewer|one))?)?"
    r"[\s-]+"
    r"(?:approv(?:e|ed|al|es|ing)?|accept(?:ed|ance|able|s|ing)?|"
    r"reject(?:ed|ion|s|ing)?|request\s+changes|evidence\s+blocked)"
    r"\s*[.!?]?\s*$",
    re.IGNORECASE | re.MULTILINE,
)
NEUTRAL_REVIEW_TERMINAL = re.compile(
    r"^\s*(?:(?:the\s+)?review|this\s+fixture|scope\s+review)\s+"
    r"(?:(?:is|was|would(?:\s+be)?|should|seems?|appears?)\s+)?"
    r"(?:pass(?:ed|es|ing)?|approv(?:e|ed|es|ing)|accept(?:ed|s|ing)?|"
    r"reject(?:ed|ion)?|request\s+changes|evidence\s+blocked|"
    r"warrant(?:ed|able)?)\s*[.!?]?\s*$",
    re.IGNORECASE | re.MULTILINE,
)
NEUTRAL_CORRECT_DISPOSITION = re.compile(
    r"^\s*the\s+correct\s+disposition\s+"
    r"(?:(?:is|was|would(?:\s+be)?)\s+)?(?:to\s+)?"
    r"(?:approv(?:e|ed|es|ing)|accept(?:ed|s|ing)?|reject(?:ed|ion)?|"
    r"request\s+changes|evidence\s+blocked|approval|acceptance|rejection)"
    r"\s*[.!?]?\s*$",
    re.IGNORECASE | re.MULTILINE,
)
HARBOR_FORMAT_SNIPPET = (
    "+def formatLabel(raw):\n"
    "+    normalized = raw.strip()\n"
    "+    if not normalized:\n"
    '+        raise ValidationError("label cannot be empty")\n'
    '+    return {"value": normalized, "original": raw}\n'
)
HARBOR_NORMALIZED_ASSIGNMENT = re.compile(
    r"^\+\s+normalized\s*=\s*(?P<expression>[^\n]+)$",
    re.MULTILINE,
)
HARBOR_FORMAT_DEFINITION = "+def formatLabel(raw):\n"
HARBOR_FORMAT_EFFECTIVE_DEFINITION = re.compile(
    r"^\+\s*(?:async\s+)?def\s+formatLabel\s*\(",
    re.MULTILINE,
)
HARBOR_FORMAT_REBIND = re.compile(
    r"^\+\s*formatLabel\s*(?:=|(?:\+|-|\*|//|/|%|&|\||\^|<<|>>)=|:=)",
    re.MULTILINE,
)
LINEN_SERIALIZER_SNIPPET = (
    "+    pairs = []\n"
    '+    for key in ("id", "title", "note"):\n'
    "+        value = record.get(key)\n"
    "+        if value is not None:\n"
    "+            pairs.append((key, value))\n"
    '+    return json.dumps(dict(pairs), ensure_ascii=False, separators=(",", ":"))\n'
)
LINEN_NULL_BRANCH = re.compile(
    r"^\+\s+if\s+(?:value\s+(?:is|==)\s+None|None\s+(?:is|==)\s+value)\s*:\s*$",
    re.MULTILINE,
)
LINEN_SERIALIZER_DEFINITION = "+def serializeRecord(record):\n"
LINEN_SERIALIZER_EFFECTIVE_DEFINITION = re.compile(
    r"^\+\s*(?:async\s+)?def\s+serializeRecord\s*\(",
    re.MULTILINE,
)
LINEN_SERIALIZER_REBIND = re.compile(
    r"^\+\s*serializeRecord\s*(?:=|(?:\+|-|\*|//|/|%|&|\||\^|<<|>>)=|:=)",
    re.MULTILINE,
)
NAMESPACE_KEY_MUTATORS = {
    "__setitem__",
    "__delitem__",
    "setdefault",
    "pop",
    "update",
    "__ior__",
}
NAMESPACE_WIDE_MUTATORS = {"clear", "popitem"}
PROTECTED_BINDING_NAMES = {"formatLabel", "serializeRecord"}
PROTECTED_DECORATOR_FALLBACK = re.compile(
    r"(?m)^[ \t]*@[^ \t\n].*\n"
    r"(?:[ \t]*@[^ \t\n].*\n)*"
    r"[ \t]*(?:async[ \t]+)?def[ \t]+(?P<name>formatLabel|serializeRecord)[ \t]*\("
)


def is_globals_call(node: ast.AST) -> bool:
    return (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "globals"
        and not node.args
        and not node.keywords
    )


def is_namespace_receiver(node: ast.AST, namespace_aliases: set[str]) -> bool:
    return is_globals_call(node) or (
        isinstance(node, ast.Name) and node.id in namespace_aliases
    )


def namespace_alias_names(tree: ast.AST) -> set[str]:
    aliases: set[str] = set()
    changed = True
    while changed:
        changed = False
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                value = node.value
                targets = node.targets
            elif isinstance(node, ast.AnnAssign):
                value = node.value
                targets = [node.target]
            elif isinstance(node, ast.NamedExpr):
                value = node.value
                targets = [node.target]
            else:
                continue
            if not (
                is_globals_call(value)
                or (isinstance(value, ast.Name) and value.id in aliases)
            ):
                continue
            for target in targets:
                if isinstance(target, ast.Name) and target.id not in aliases:
                    aliases.add(target.id)
                    changed = True
    return aliases


def protected_binding_names(source: str) -> set[str] | None:
    candidates = [source]
    stripped_source = source.lstrip()
    if stripped_source.rstrip().endswith(":"):
        candidates.append(stripped_source + "\n    pass")
    for candidate in candidates:
        try:
            tree = ast.parse(candidate)
        except SyntaxError:
            continue
        bound_names: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
                bound_names.add(node.id)
            elif isinstance(node, ast.arg):
                bound_names.add(node.arg)
            elif isinstance(node, ast.alias):
                bound_names.add(node.asname or node.name.rsplit(".", 1)[-1])
            elif isinstance(node, ast.ClassDef):
                bound_names.add(node.name)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if node.name in PROTECTED_BINDING_NAMES and node.decorator_list:
                    bound_names.add(node.name)
            elif isinstance(node, ast.ExceptHandler) and isinstance(node.name, str):
                bound_names.add(node.name)
            elif isinstance(node, ast.MatchAs) and node.name is not None:
                bound_names.add(node.name)
            elif isinstance(node, ast.MatchStar) and node.name is not None:
                bound_names.add(node.name)
            elif isinstance(node, ast.MatchMapping) and node.rest is not None:
                bound_names.add(node.rest)
        return bound_names
    decorated_names = {
        match.group("name") for match in PROTECTED_DECORATOR_FALLBACK.finditer(source)
    }
    return decorated_names or None


def protected_namespace_binding_names(source: str) -> set[str] | None:
    candidates = [source]
    stripped_source = source.lstrip()
    if stripped_source.rstrip().endswith(":"):
        candidates.append(stripped_source + "\n    pass")
    for candidate in candidates:
        try:
            tree = ast.parse(candidate)
        except SyntaxError:
            continue
        namespace_aliases = namespace_alias_names(tree)
        bound_names: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.AugAssign):
                if isinstance(node.op, ast.BitOr) and is_namespace_receiver(
                    node.target, namespace_aliases
                ):
                    bound_names.update(literal_namespace_keys(node.value))
                continue
            if isinstance(node, ast.Attribute):
                if isinstance(node.ctx, (ast.Store, ast.Del)):
                    bound_names.add(node.attr)
                continue
            if isinstance(node, ast.Subscript):
                if not isinstance(node.ctx, (ast.Store, ast.Del)) or not is_namespace_receiver(
                    node.value, namespace_aliases
                ):
                    continue
                subscript_key = node.slice
                if hasattr(ast, "Index") and isinstance(subscript_key, ast.Index):
                    subscript_key = subscript_key.value
                constant_key = constant_string_expression(subscript_key)
                if constant_key is not None:
                    bound_names.add(constant_key)
                else:
                    bound_names.update(PROTECTED_BINDING_NAMES)
                continue
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                continue
            method = node.func.attr
            receiver = node.func.value
            namespace_method = is_namespace_receiver(receiver, namespace_aliases)
            descriptor_method = (
                isinstance(receiver, ast.Name)
                and receiver.id == "dict"
                and method in NAMESPACE_KEY_MUTATORS | NAMESPACE_WIDE_MUTATORS
                and bool(node.args)
                and is_namespace_receiver(node.args[0], namespace_aliases)
            )
            if not namespace_method and not descriptor_method:
                continue
            if method in NAMESPACE_WIDE_MUTATORS:
                bound_names.update({"formatLabel", "serializeRecord"})
                continue
            if method not in NAMESPACE_KEY_MUTATORS:
                continue
            if method == "update":
                arguments = node.args[1:] if descriptor_method else node.args
                for argument in arguments:
                    bound_names.update(literal_namespace_keys(argument))
                for keyword in node.keywords:
                    if keyword.arg is not None:
                        bound_names.add(keyword.arg)
                    else:
                        bound_names.update(literal_namespace_keys(keyword.value))
                continue
            key_arguments = node.args[1:2] if descriptor_method else node.args[:1]
            for argument in key_arguments:
                bound_names.update(literal_namespace_keys(argument))
            for keyword in node.keywords:
                if keyword.arg in {"key", "name"}:
                    bound_names.update(literal_namespace_keys(keyword.value))
                elif keyword.arg is None:
                    bound_names.update(literal_namespace_keys(keyword.value))
        return bound_names
    return None


def constant_string_expression(node: ast.AST) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = constant_string_expression(node.left)
        right = constant_string_expression(node.right)
        if left is not None and right is not None:
            return left + right
        return None
    if not isinstance(node, ast.JoinedStr):
        return None

    parts: list[str] = []
    for value in node.values:
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            parts.append(value.value)
            continue
        if not isinstance(value, ast.FormattedValue):
            return None
        formatted = constant_string_expression(value.value)
        if formatted is None:
            return None
        if value.conversion in {-1, ord("s")}:
            rendered = formatted
        elif value.conversion == ord("r"):
            rendered = repr(formatted)
        elif value.conversion == ord("a"):
            rendered = ascii(formatted)
        else:
            return None
        if value.format_spec is not None:
            format_spec = constant_string_expression(value.format_spec)
            if format_spec is None:
                return None
            rendered = format(rendered, format_spec)
        parts.append(rendered)
    return "".join(parts)


def literal_namespace_keys(node: ast.AST) -> set[str]:
    constant_value = constant_string_expression(node)
    if constant_value is not None:
        return {constant_value}
    if isinstance(node, ast.Dict):
        keys: set[str] = set()
        for key, value in zip(node.keys, node.values):
            if key is None:
                keys.update(literal_namespace_keys(value))
            else:
                constant_key = constant_string_expression(key)
                if constant_key is not None:
                    keys.add(constant_key)
                else:
                    keys.update(PROTECTED_BINDING_NAMES)
        return keys
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        keys = set()
        for element in node.elts:
            if isinstance(element, ast.Starred):
                keys.update(literal_namespace_keys(element.value))
            elif isinstance(element, (ast.List, ast.Tuple)) and element.elts:
                keys.update(literal_namespace_keys(element.elts[0]))
            elif isinstance(element, ast.Constant) and isinstance(element.value, str):
                keys.add(element.value)
        return keys
    return set(PROTECTED_BINDING_NAMES)


def contains_protected_binding(section: str, protected_name: str) -> bool:
    added_lines = [
        line[1:]
        for line in section.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    ]
    sources = ["\n".join(added_lines)] + added_lines
    fallback_sources: list[str] = []
    for source in sources:
        bound_names = protected_binding_names(source)
        if bound_names is not None and protected_name in bound_names:
            return True
        namespace_bound_names = protected_namespace_binding_names(source)
        if namespace_bound_names is not None and protected_name in namespace_bound_names:
            return True
        if bound_names is not None or namespace_bound_names is not None:
            continue
        fallback_sources.append(source)

    name = rf"\b{re.escape(protected_name)}\b"
    assignment = re.compile(
        name
        + r"\s*(?:(?::\s*[^=\n]+)?\s*(?:,|\]|\))?\s*"
        + r"(?::=|(?:\*\*|//|<<|>>|[+\-*/%@&|^])?=))"
    )
    context = re.compile(rf"\b(?:for|as|global|nonlocal)\s+{name}")
    return any(assignment.search(source) or context.search(source) for source in fallback_sources)


MAPLE_TARGET_HEAD = "5555555555555555555555555555555555555555"
MAPLE_CANONICAL_MISSING_EVIDENCE = (
    f"The daylight-saving boundary test result was not supplied for target head {MAPLE_TARGET_HEAD}.",
    "Required behavior-focused schedule validation evidence is unavailable.",
)
MAPLE_CANONICAL_REQUIRED_ACTION = (
    f"Supply daylight-saving boundary validation evidence for target head {MAPLE_TARGET_HEAD}, "
    "resolve the recorded account-summary disposition, then repeat the review from a fresh source reload."
)
MAPLE_MISSING_EVIDENCE_ANCHORS = (
    "daylight-saving boundary test result was not supplied",
    f"target head {MAPLE_TARGET_HEAD}",
    "required behavior-focused schedule validation evidence is unavailable",
)
MAPLE_REQUIRED_ACTION_ANCHORS = (
    "daylight-saving boundary validation evidence",
    f"target head {MAPLE_TARGET_HEAD}",
    "account-summary disposition",
    "repeat the review from a fresh source reload",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise SystemExit(f"cannot read {path}: {error}") from error


def load_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(read_text(path))
    except json.JSONDecodeError as error:
        raise SystemExit(f"invalid JSON in {path.name}: {error}") from error
    require(isinstance(value, dict), f"{path.name} must contain a JSON object")
    return value


def require_string(value: object, message: str) -> None:
    require(isinstance(value, str) and bool(value.strip()), message)


def frontmatter_value(frontmatter: str, key: str) -> str | None:
    match = re.search(rf"^{re.escape(key)}:[ \t]*(.*?)\r?$", frontmatter, re.MULTILINE)
    if match is None:
        return None
    value = match.group(1).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    return value


def validate_skill_frontmatter(skill_text: str) -> None:
    match = re.match(r"\A---\r?\n(?P<body>.*?)\r?\n---(?:\r?\n|\Z)", skill_text, re.DOTALL)
    require(match is not None, "SKILL.md frontmatter is missing")
    frontmatter = match.group("body")
    name = frontmatter_value(frontmatter, "name")
    require(name == "scope-reviewer", "SKILL.md name must be scope-reviewer")
    description = frontmatter_value(frontmatter, "description")
    require(
        description is not None and bool(description.strip()),
        "SKILL.md description must be non-empty",
    )


def validate_script_imports(script_text: str) -> None:
    try:
        tree = ast.parse(script_text, filename=str(SCRIPT_PATH))
    except SyntaxError as error:
        raise SystemExit(f"validator source is not valid Python: {error}") from error

    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and node.id in FORBIDDEN_DYNAMIC_EXECUTION:
            raise SystemExit(f"validator uses disallowed dynamic execution: {node.id}")
        if isinstance(node, ast.Name) and node.id in FORBIDDEN_IMPORT_NAMES:
            raise SystemExit(f"validator uses disallowed import-hook access: {node.id}")
        if isinstance(node, ast.Attribute) and node.attr in FORBIDDEN_DYNAMIC_EXECUTION:
            is_safe_standard_library_call = (
                node.attr == "compile"
                and isinstance(node.value, ast.Name)
                and node.value.id == "re"
            )
            if not is_safe_standard_library_call:
                raise SystemExit(f"validator uses disallowed dynamic execution: {node.attr}")
        if isinstance(node, ast.Attribute) and node.attr in FORBIDDEN_IMPORT_NAMES:
            raise SystemExit(f"validator uses disallowed import-hook access: {node.attr}")
        if isinstance(node, ast.Subscript):
            subscript_key = node.slice
            if hasattr(ast, "Index") and isinstance(subscript_key, ast.Index):
                subscript_key = subscript_key.value
            if isinstance(subscript_key, ast.Constant) and isinstance(subscript_key.value, str):
                require(
                    subscript_key.value not in FORBIDDEN_SUBSCRIPT_NAMES,
                    "validator uses disallowed constant-key import-hook or dynamic-execution access",
                )
        if isinstance(node, ast.Call) and (
            (isinstance(node.func, ast.Name) and node.func.id == "__import__")
            or (isinstance(node.func, ast.Attribute) and node.func.attr == "__import__")
        ):
            raise SystemExit("validator uses disallowed dynamic import: __import__")
        if isinstance(node, ast.Import):
            for alias in node.names:
                require(
                    alias.asname not in FORBIDDEN_IMPORT_NAMES,
                    "validator aliases an import-hook name",
                )
            modules = [alias.name.split(".", 1)[0] for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            require(node.level == 0, "validator cannot use relative imports")
            for alias in node.names:
                require(
                    alias.name not in FORBIDDEN_IMPORT_NAMES
                    and alias.asname not in FORBIDDEN_IMPORT_NAMES,
                    "validator imports or aliases an import-hook name",
                )
            modules = [node.module.split(".", 1)[0] if node.module else ""]
        else:
            continue
        for module in modules:
            require(module in ALLOWED_IMPORT_MODULES, f"validator imports disallowed module: {module}")


def validate_files() -> None:
    actual_paths = {
        path.relative_to(SKILL_ROOT)
        for path in SKILL_ROOT.rglob("*")
    }
    expected_paths = EXPECTED_FILES | EXPECTED_DIRECTORIES
    require(
        actual_paths == expected_paths,
        f"unexpected skill tree: {sorted(actual_paths - expected_paths)}",
    )
    require(
        not any(path.is_symlink() for path in SKILL_ROOT.rglob("*")),
        "skill tree cannot contain symlinks",
    )


def validate_metadata(openai_text: str) -> None:
    match = re.fullmatch(
        r'interface:\n'
        r'  display_name: "([^"\n]+)"\n'
        r'  short_description: "([^"\n]+)"\n'
        r'  default_prompt: "([^"\n]+)"\n',
        openai_text,
    )
    require(
        match is not None,
        "openai.yaml must contain only interface and its three ordered quoted fields",
    )
    display_name, short_description_value, default_prompt_value = match.groups()
    require(display_name.strip(), "openai.yaml has empty display_name")
    require(short_description_value.strip(), "openai.yaml has empty short_description")
    require(default_prompt_value.strip(), "openai.yaml has empty default_prompt")
    length = len(short_description_value)
    require(25 <= length <= 64, "openai.yaml short_description must be 25-64 characters")
    require("$scope-reviewer" in default_prompt_value, "default_prompt must invoke $scope-reviewer")


def validate_whitespace(package_texts: tuple[tuple[str, str], ...]) -> None:
    for name, text in package_texts:
        require(text.endswith("\n"), f"{name} must end with a newline")
        require("\r" not in text, f"{name} must use LF line endings")
        for line_number, line in enumerate(text.split("\n")[:-1], start=1):
            require(
                line == line.rstrip(" \t"),
                f"{name} has trailing whitespace on line {line_number}",
            )


def is_repository_guidance_reference(value: str) -> bool:
    return bool(
        REPOSITORY_GUIDANCE_FILE.fullmatch(value)
        or REPOSITORY_GUIDANCE_PATH.fullmatch(value)
    )


def validate_genericity(package_texts: tuple[tuple[str, str], ...]) -> None:
    for name, text in package_texts:
        if name == "scripts/test_fixtures.py":
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            claims = [
                claim
                for claim in (
                    GENERICITY_TECHNOLOGY_CLAIM.search(line),
                    GENERICITY_PASSIVE_TECHNOLOGY_CLAIM.search(line),
                    GENERICITY_DIRECT_USE_CLAIM.search(line),
                )
                if claim
            ]
            for claim in claims:
                technology = claim.group("name")
                looks_like_named_technology = (
                    technology.lower() not in GENERICITY_NEUTRAL_NAMES
                    and not is_repository_guidance_reference(technology)
                    and (
                        technology.startswith("@")
                        or technology[0].isupper()
                        or "." in technology
                        or GENERICITY_LOWERCASE_TECHNOLOGY_NAME.fullmatch(technology) is not None
                    )
                )
                require(
                    not looks_like_named_technology,
                    f"{name} contains technology-specific requirement language on line {line_number}",
                )
            require(
                GENERICITY_TECHNOLOGY_CONTEXT.search(line) is None,
                f"{name} contains technology-specific requirement context on line {line_number}",
            )


def validate_neutral_answer_hints(fixture_id: str, section: str) -> None:
    input_marker = "### Fixture input\n"
    repository_marker = "\nRepository `AGENTS.md`\n"
    require(section.count(input_marker) == 1, f"{fixture_id} must expose one fixture input section")
    require(
        repository_marker in section.split(input_marker, 1)[1],
        f"{fixture_id} fixture input boundary is missing",
    )
    for line_number, line in enumerate(section.splitlines(), start=1):
        require(
            NEUTRAL_ANSWER_HINT_LABEL.search(line) is None,
            f"{fixture_id} fixture input contains an answer hint label on line {line_number}",
        )
    require(
        NEUTRAL_ANSWER_HINT_STATEMENT.search(section) is None,
        f"{fixture_id} fixture input contains an answer hint statement",
    )
    require(
        NEUTRAL_REVIEWER_DIRECTIVE.search(section) is None,
        f"{fixture_id} fixture input contains a reviewer terminal directive",
    )
    require(
        NEUTRAL_REVIEW_TERMINAL.search(section) is None,
        f"{fixture_id} fixture input contains a review terminal result",
    )
    require(
        NEUTRAL_CORRECT_DISPOSITION.search(section) is None,
        f"{fixture_id} fixture input contains a correct-disposition terminal result",
    )
    require(
        NEUTRAL_BARE_TERMINAL.search(section) is None,
        f"{fixture_id} fixture input contains a bare terminal recommendation",
    )
    require(
        NEUTRAL_STANDALONE_TERMINAL.search(section) is None,
        f"{fixture_id} fixture input contains a standalone terminal answer",
    )
    require(
        NEUTRAL_RECOMMENDATION_DIRECTIVE.search(section) is None,
        f"{fixture_id} fixture input contains a terminal recommendation directive",
    )


def validate_harbor_semantics(section: str) -> None:
    require(
        section.count(HARBOR_FORMAT_DEFINITION) == 1,
        "harbor-labels must contain the exact formatLabel definition once",
    )
    require(
        len(HARBOR_FORMAT_EFFECTIVE_DEFINITION.findall(section)) == 1,
        "harbor-labels must contain exactly one effective formatLabel definition",
    )
    require(
        not contains_protected_binding(section, "formatLabel"),
        "harbor-labels must not rebind formatLabel",
    )
    for line in HARBOR_FORMAT_SNIPPET.splitlines(keepends=True):
        require(
            section.count(line) == 1,
            "harbor-labels must contain each intended formatter line exactly once",
        )
    require(
        section.count(HARBOR_FORMAT_SNIPPET) == 1,
        "harbor-labels must contain the intended formatter lines in order",
    )
    assignments = [
        match.group("expression").strip()
        for match in HARBOR_NORMALIZED_ASSIGNMENT.finditer(section)
    ]
    require(
        assignments == ["raw.strip()"],
        "harbor-labels must not override the normalized formatter assignment",
    )


def validate_linen_semantics(section: str) -> None:
    require(
        section.count(LINEN_SERIALIZER_DEFINITION) == 1,
        "linen-export must contain the exact serializeRecord definition once",
    )
    require(
        len(LINEN_SERIALIZER_EFFECTIVE_DEFINITION.findall(section)) == 1,
        "linen-export must contain exactly one effective serializeRecord definition",
    )
    require(
        not contains_protected_binding(section, "serializeRecord"),
        "linen-export must not rebind serializeRecord",
    )
    for line in LINEN_SERIALIZER_SNIPPET.splitlines(keepends=True):
        require(
            section.count(line) == 1,
            "linen-export must contain each intended serializer line exactly once",
        )
    require(
        section.count(LINEN_SERIALIZER_SNIPPET) == 1,
        "linen-export must contain the intended serializer lines in order",
    )
    require(
        not LINEN_NULL_BRANCH.search(section),
        "linen-export must not add a null-emission branch",
    )


def validate_skill_text(
    skill_text: str,
    catalog_text: str,
    expected_text: str,
    openai_text: str,
    script_text: str,
) -> None:
    validate_skill_frontmatter(skill_text)
    validate_script_imports(script_text)
    package_texts = (
        ("SKILL.md", skill_text),
        ("fixture catalog", catalog_text),
        ("expected results", expected_text),
        ("openai.yaml", openai_text),
        ("scripts/test_fixtures.py", script_text),
    )
    for name, text in package_texts:
        require(SCAFFOLD_MARKER not in text.upper(), f"{name} still contains scaffold marker")
    for phrase in REQUIRED_SKILL_PHRASES:
        require(phrase in skill_text, f"SKILL.md is missing required phrase: {phrase}")
    content_text = "\n".join(text.lower() for _, text in package_texts)
    for term in FORBIDDEN_LEAKAGE:
        require(term not in content_text, f"skill content contains project or vendor leakage: {term}")
    catalog_lower = catalog_text.lower()
    for term in CATALOG_ANSWER_LEAKAGE:
        require(term not in catalog_lower, f"fixture catalog leaks answer data or hints: {term}")
    validate_whitespace(package_texts)
    validate_genericity(package_texts)


def fixture_section(catalog_text: str, fixture_id: str) -> str:
    marker = f"## Fixture: {fixture_id}\n"
    require(catalog_text.count(marker) == 1, f"catalog must contain exactly one section for {fixture_id}")
    section = catalog_text.split(marker, 1)[1]
    next_section = section.find("\n## Fixture:")
    if next_section != -1:
        section = section[:next_section]
    require(section.count("### Fixture input\n") == 1, f"{fixture_id} must expose one fixture input section")
    require(section.lstrip().startswith("### Fixture input\n"), f"{fixture_id} has non-input content before its input")
    require(section.count("### ") == 1, f"{fixture_id} contains an extra non-neutral subsection")
    previous_position = -1
    for marker in REQUIRED_FIXTURE_MARKERS:
        require(
            section.count(marker) == 1,
            f"{fixture_id} must contain exactly one {marker.rstrip()} marker",
        )
        position = section.find(marker)
        require(position > previous_position, f"{fixture_id} fixture markers are out of order")
        previous_position = position
    linked_sources = list(LINKED_SOURCE_MARKER.finditer(section))
    require(linked_sources, f"{fixture_id} must contain a linked source marker")
    require(
        section.find("Repository `AGENTS.md`\n") < linked_sources[0].start() < section.find("Review target\n"),
        f"{fixture_id} linked source markers are out of order",
    )
    return section


def validate_fixture_integrity(fixture_id: str, section: str) -> None:
    dependency_start = section.index("**Dependencies and relationships**\n")
    dependency_end = section.index("\nFull diff\n", dependency_start)
    expected_dependency = (
        DEPENDENCY_SEMANTIC_MARKERS[fixture_id][0]
        + "\n"
        + "".join(DEPENDENCY_SEMANTIC_MARKERS[fixture_id][1:])
        + OUT_OF_SCOPE_CHOICES_MARKER
    )
    require(
        section[dependency_start:dependency_end] == expected_dependency,
        f"{fixture_id} dependency block contains additions or contradictions",
    )

    diff_paths = tuple(
        match.group(1)
        for match in re.finditer(
            r"^diff --git a/([^\s\n]+) b/([^\s\n]+)$",
            section,
            re.MULTILINE,
        )
        if match.group(1) == match.group(2)
    )
    require(
        diff_paths == FIXTURE_DIFF_PATHS[fixture_id],
        f"{fixture_id} full diff has unexpected paths or path counts",
    )


def validate_fixture_semantics(catalog_text: str) -> None:
    require(
        set(FIXTURE_SEMANTIC_MARKERS) == set(FIXTURE_DECISIONS),
        "fixture semantic markers do not cover exactly the six fixture identities",
    )
    require(
        set(DEPENDENCY_SEMANTIC_MARKERS) == set(FIXTURE_DECISIONS),
        "dependency semantic markers do not cover exactly the six fixture identities",
    )
    for fixture_id, markers in FIXTURE_SEMANTIC_MARKERS.items():
        section = fixture_section(catalog_text, fixture_id)
        for marker in markers:
            require(
                section.count(marker) == 1,
                f"{fixture_id} is missing or duplicates its semantic marker: {marker.rstrip()}",
            )
        for marker in DEPENDENCY_SEMANTIC_MARKERS[fixture_id]:
            require(
                section.count(marker) == 1,
                f"{fixture_id} is missing or duplicates its dependency marker: {marker.rstrip()}",
            )
        require(
            section.count(OUT_OF_SCOPE_CHOICES_MARKER) == 1,
            f"{fixture_id} must present the exact out-of-scope user choices",
        )
        validate_neutral_answer_hints(fixture_id, section)
        if fixture_id == "harbor-labels":
            validate_harbor_semantics(section)
        elif fixture_id == "linen-export":
            validate_linen_semantics(section)
        validate_fixture_integrity(fixture_id, section)


def validate_catalog(catalog_text: str) -> None:
    require(catalog_text.startswith("# Calibration fixture catalog\n"), "catalog heading is missing")
    catalog_lower = catalog_text.lower()
    for term in CATALOG_ANSWER_LEAKAGE:
        require(term not in catalog_lower, f"fixture catalog leaks answer data or hints: {term}")
    validate_genericity((("fixture catalog", catalog_text),))
    sections: dict[str, str] = {}
    for fixture_id in FIXTURE_DECISIONS:
        sections[fixture_id] = fixture_section(catalog_text, fixture_id)
    headings = re.findall(r"^## Fixture: ([a-z0-9-]+)$", catalog_text, re.MULTILINE)
    require(set(headings) == set(FIXTURE_DECISIONS), "catalog fixture IDs do not match the contract")
    require(len(headings) == len(FIXTURE_DECISIONS), "catalog contains duplicate or missing fixture headings")
    linen_handoff = sections["linen-export"].split("Structured worker handoffs\n", 1)[1]
    require(
        NULL_OMISSION_HANDOFF_CLAIM.search(linen_handoff) is None,
        "linen-export handoff must not claim null-field omission",
    )
    validate_fixture_semantics(catalog_text)


def validate_coverage(fixture_id: str, coverage: object) -> list[dict[str, str]]:
    require(isinstance(coverage, list) and coverage, f"{fixture_id} coverage must be a non-empty array")
    seen: set[str] = set()
    normalized: list[dict[str, str]] = []
    for row in coverage:
        require(isinstance(row, dict), f"{fixture_id} coverage row must be an object")
        require(set(row) == COVERAGE_KEYS, f"{fixture_id} coverage row has unexpected fields")
        for key in COVERAGE_KEYS:
            require_string(row[key], f"{fixture_id} coverage {key} must be a non-empty string")
        row_id = row["id"]
        require(row_id not in seen, f"{fixture_id} has duplicate coverage ID {row_id}")
        require(row["status"] in STATUSES, f"{fixture_id} has invalid coverage status {row['status']}")
        seen.add(row_id)
        normalized.append({key: row[key] for key in COVERAGE_KEYS})
    return normalized


def validate_expected_coverage_semantics(
    fixture_id: str,
    coverage: list[dict[str, str]],
) -> None:
    require(
        set(EXPECTED_COVERAGE_ANCHORS) == set(FIXTURE_DECISIONS),
        "private coverage anchors do not cover exactly the six fixture identities",
    )
    require(
        set(DEPENDENCY_COVERAGE_CANONICAL) == set(FIXTURE_DECISIONS),
        "private dependency coverage anchors do not cover exactly the six fixture identities",
    )
    anchors = EXPECTED_COVERAGE_ANCHORS[fixture_id]
    rows = {row["id"]: row for row in coverage}
    require(
        set(rows) == set(anchors),
        f"{fixture_id} coverage IDs do not match its private fixture contract",
    )
    for row_id, (status, contract_terms, diff_terms) in anchors.items():
        row = rows[row_id]
        require(row["status"] == status, f"{fixture_id} {row_id} has the wrong expected status")
        contract_evidence = row["contractEvidence"].lower()
        diff_evidence = row["diffEvidence"].lower()
        for term in contract_terms:
            require(
                term.lower() in contract_evidence,
                f"{fixture_id} {row_id} is missing private contract evidence: {term}",
            )
        for term in diff_terms:
            require(
                term.lower() in diff_evidence,
                f"{fixture_id} {row_id} is missing private diff evidence: {term}",
            )
    dependency_id, dependency_status, dependency_contract, dependency_diff = (
        DEPENDENCY_COVERAGE_CANONICAL[fixture_id]
    )
    dependency_row = rows[dependency_id]
    require(
        (
            dependency_row["status"],
            dependency_row["contractEvidence"],
            dependency_row["diffEvidence"],
        )
        == (dependency_status, dependency_contract, dependency_diff),
        f"{fixture_id} {dependency_id} dependency evidence contains additions or contradictions",
    )


def validate_findings(fixture_id: str, findings: object) -> list[dict[str, object]]:
    require(isinstance(findings, list), f"{fixture_id} blockingFindings must be an array")
    normalized: list[dict[str, object]] = []
    for finding in findings:
        require(isinstance(finding, dict), f"{fixture_id} blocking finding must be an object")
        require(set(finding) == FINDING_KEYS, f"{fixture_id} blocking finding has unexpected fields")
        require(finding["severity"] in {"Blocker", "Major"}, f"{fixture_id} finding severity is invalid")
        require(finding["kind"] in {"scope-gap", "out-of-scope"}, f"{fixture_id} finding kind is invalid")
        for key in FINDING_KEYS - {"severity", "kind"}:
            require_string(finding[key], f"{fixture_id} finding {key} must be a non-empty string")
        failed_guard = finding["failedGuard"]
        require(
            FAILED_GUARD_CONTROL.search(failed_guard) is not None,
            f"{fixture_id} finding failedGuard must name the failed guard or control",
        )
        require(
            FAILED_GUARD_REASON.search(failed_guard) is not None
            and FAILED_GUARD_EXPLANATION.search(failed_guard) is not None,
            f"{fixture_id} finding failedGuard must explain why the guard or control failed",
        )
        explanation = FAILED_GUARD_EXPLANATION.search(failed_guard)
        require(
            explanation is not None
            and len(failed_guard[explanation.end():].strip(" .;:").split()) >= 2
            and len(failed_guard.split()) >= 6,
            f"{fixture_id} finding failedGuard must contain a concrete reason",
        )
        if finding["kind"] == "out-of-scope":
            fix_boundary = finding["fixBoundary"]
            require(
                all(choice in fix_boundary for choice in DISPOSITION_CHOICES)
                and "do not choose" in fix_boundary.lower(),
                f"{fixture_id} out-of-scope finding must present exact user choices without choosing",
            )
        normalized.append(finding)
    return normalized


def validate_out_of_scope(fixture_id: str, inventory: object) -> list[dict[str, object]]:
    require(isinstance(inventory, list), f"{fixture_id} outOfScopeInventory must be an array")
    normalized: list[dict[str, object]] = []
    for item in inventory:
        require(isinstance(item, dict), f"{fixture_id} out-of-scope entry must be an object")
        require(set(item) == OUT_OF_SCOPE_KEYS, f"{fixture_id} out-of-scope entry has unexpected fields")
        for key in ("behavior", "evidence", "authorization"):
            require_string(item[key], f"{fixture_id} out-of-scope {key} must be a non-empty string")
        require(item["dispositionRequired"] is True, f"{fixture_id} out-of-scope disposition must be required")
        require(item["choices"] == DISPOSITION_CHOICES, f"{fixture_id} out-of-scope choices are incomplete")
        normalized.append(item)
    return normalized


def validate_maple_evidence_semantics(missing: object, action: object) -> None:
    require(
        isinstance(missing, list) and len(missing) == 2,
        "maple-schedule must retain both private missing-evidence entries",
    )
    require(
        all(isinstance(item, str) and item.strip() for item in missing),
        "maple-schedule missing-evidence entries must be non-empty strings",
    )
    require(
        missing == list(MAPLE_CANONICAL_MISSING_EVIDENCE),
        "maple-schedule must retain the exact private missing-evidence calibration data",
    )
    first_missing = missing[0].lower()
    second_missing = missing[1].lower()
    require(
        MAPLE_MISSING_EVIDENCE_ANCHORS[0] in first_missing
        and MAPLE_MISSING_EVIDENCE_ANCHORS[1].lower() in first_missing,
        "maple-schedule must identify the missing daylight-saving result at the exact head",
    )
    require(
        MAPLE_MISSING_EVIDENCE_ANCHORS[2] in second_missing,
        "maple-schedule must retain the missing behavior-focused validation evidence",
    )
    require(isinstance(action, str) and action.strip(), "maple-schedule requiredAction must be non-empty")
    require(
        action == MAPLE_CANONICAL_REQUIRED_ACTION,
        "maple-schedule must retain the exact private required-action calibration data",
    )
    action_lower = action.lower()
    for anchor in MAPLE_REQUIRED_ACTION_ANCHORS:
        require(
            anchor.lower() in action_lower,
            f"maple-schedule requiredAction is missing private recovery anchor: {anchor}",
        )


def validate_results(expected: dict[str, object], catalog_text: str) -> None:
    require(set(expected) == {"fixtures"}, "expected-results.json must contain only the fixtures field")
    fixtures = expected["fixtures"]
    require(isinstance(fixtures, list), "expected-results.json fixtures must be an array")
    require(len(fixtures) == len(FIXTURE_DECISIONS), "expected result count does not match fixture contract")

    seen: set[str] = set()
    for fixture in fixtures:
        require(isinstance(fixture, dict), "each expected fixture result must be an object")
        fixture_id = fixture.get("id")
        require(isinstance(fixture_id, str) and fixture_id in FIXTURE_DECISIONS, f"unexpected fixture id: {fixture_id}")
        require(fixture_id not in seen, f"duplicate fixture id: {fixture_id}")
        seen.add(fixture_id)
        decision = fixture.get("expectedDecision")
        require(decision == FIXTURE_DECISIONS[fixture_id], f"wrong expected decision for {fixture_id}")
        fixture_keys = COMMON_RESULT_KEYS | ({"requiredAction"} if decision == "Evidence blocked" else set())
        require(set(fixture) == fixture_keys, f"{fixture_id} fixture has unexpected or missing fields")
        require(f"## Fixture: {fixture_id}\n" in catalog_text, f"catalog is missing {fixture_id}")

        coverage = validate_coverage(fixture_id, fixture.get("coverage"))
        validate_expected_coverage_semantics(fixture_id, coverage)
        require(
            any(
                "dependency" in row["contractEvidence"].lower()
                and "authority/source" in row["contractEvidence"].lower()
                and "exact revision or immutable identity" in row["contractEvidence"].lower()
                and "relevant evidence" in row["contractEvidence"].lower()
                and "reload/reconciliation" in row["contractEvidence"].lower()
                and "dependency" in row["diffEvidence"].lower()
                and "reload" in row["diffEvidence"].lower()
                for row in coverage
            ),
            f"{fixture_id} must exercise dependency authority, identity, evidence, and reload/reconciliation coverage",
        )
        findings = validate_findings(fixture_id, fixture.get("blockingFindings"))
        inventory = validate_out_of_scope(fixture_id, fixture.get("outOfScopeInventory"))
        missing = fixture.get("missingEvidence")
        contradictory = fixture.get("contradictoryEvidence")
        require(isinstance(missing, list), f"{fixture_id} missingEvidence must be an array")
        require(all(isinstance(item, str) and item.strip() for item in missing), f"{fixture_id} missingEvidence entries must be non-empty strings")
        require(isinstance(contradictory, list), f"{fixture_id} contradictoryEvidence must be an array")
        require(all(isinstance(item, str) and item.strip() for item in contradictory), f"{fixture_id} contradictoryEvidence entries must be non-empty strings")
        if fixture_id == "maple-schedule":
            validate_maple_evidence_semantics(missing, fixture.get("requiredAction"))
        require(
            bool(contradictory) == (fixture_id in CONTRADICTORY_FIXTURES),
            f"{fixture_id} contradictory evidence does not match its fixture input",
        )
        require(fixture.get("dispositionRequiredBeforeBranchChange") in {True, False}, f"{fixture_id} disposition gate must be boolean")

        statuses = {row["status"] for row in coverage}
        if decision == "Approved":
            require(statuses == {"Implemented"}, f"{fixture_id} approval requires all Implemented coverage")
            require(not findings and not inventory and not missing and not contradictory, f"{fixture_id} approval cannot have blockers or evidence gaps")
            require(fixture["dispositionRequiredBeforeBranchChange"] is False, f"{fixture_id} approval cannot require disposition")
        elif decision == "Request changes":
            require(findings or inventory, f"{fixture_id} changes request needs a blocker or out-of-scope entry")
            require("Unverifiable" not in statuses, f"{fixture_id} changes request cannot hide Unverifiable evidence")
            require(not missing and not contradictory, f"{fixture_id} changes request cannot contain evidence-blocking gaps")
            if inventory:
                require(fixture["dispositionRequiredBeforeBranchChange"] is True, f"{fixture_id} out-of-scope work needs a disposition gate")
                require(any(finding["kind"] == "out-of-scope" for finding in findings), f"{fixture_id} inventory needs an out-of-scope blocker")
        else:
            require(decision == "Evidence blocked", f"unexpected decision for {fixture_id}")
            require("Unverifiable" in statuses, f"{fixture_id} evidence block needs Unverifiable coverage")
            require("Implemented" not in statuses, f"{fixture_id} evidence block cannot mark a row Implemented without applicable validation evidence")
            require(missing or contradictory, f"{fixture_id} evidence block needs missing or contradictory evidence")
            action = fixture.get("requiredAction")
            require_string(action, f"{fixture_id} evidence block needs a requiredAction")
            if inventory:
                require(fixture["dispositionRequiredBeforeBranchChange"] is True, f"{fixture_id} out-of-scope work needs a disposition gate")
                require(any(finding["kind"] == "out-of-scope" for finding in findings), f"{fixture_id} inventory needs an out-of-scope blocker")
            else:
                require(fixture["dispositionRequiredBeforeBranchChange"] is False, f"{fixture_id} without out-of-scope work cannot require disposition")

    require(seen == set(FIXTURE_DECISIONS), "expected fixture IDs do not match the catalog")
    require(
        any(row["status"] == "Partial" for fixture in fixtures for row in fixture["coverage"]),
        "fixtures must cover Partial requirements",
    )
    require(
        any(row["status"] == "Unverifiable" for fixture in fixtures for row in fixture["coverage"]),
        "fixtures must cover Unverifiable requirements",
    )
    require(
        any(fixture["outOfScopeInventory"] for fixture in fixtures),
        "fixtures must cover out-of-scope behavior",
    )
    mixed = next(fixture for fixture in fixtures if fixture["id"] == "maple-schedule")
    require(mixed["expectedDecision"] == "Evidence blocked", "mixed fixture must exercise evidence precedence")
    require("Unverifiable" in {row["status"] for row in mixed["coverage"]}, "mixed fixture must cover Unverifiable validation status")
    require(mixed["missingEvidence"], "mixed fixture must record missing validation evidence")
    require(mixed["outOfScopeInventory"] and mixed["dispositionRequiredBeforeBranchChange"] is True, "mixed fixture must require disposition before branch changes")
    require(any(finding["kind"] == "scope-gap" for finding in mixed["blockingFindings"]), "mixed fixture must retain its actionable scope gap")
    ember = next(fixture for fixture in fixtures if fixture["id"] == "ember-report")
    require(
        any(
            row["id"] == "R2"
            and row["status"] == "Implemented"
            and "field order" in row["contractEvidence"].lower()
            and "full diff" in row["diffEvidence"].lower()
            for row in ember["coverage"]
        ),
        "ember-report must cover field-order preservation with contract and full-diff evidence",
    )


def expect_rejection(label: str, probe: object) -> None:
    try:
        probe()
    except SystemExit:
        return
    raise SystemExit(f"mutation probe was accepted: {label}")


def expect_acceptance(label: str, probe: object) -> None:
    try:
        probe()
    except SystemExit as error:
        raise SystemExit(f"benign control was rejected: {label}") from error


def run_mutation_probes(
    skill_text: str,
    catalog_text: str,
    expected_text: str,
    openai_text: str,
    script_text: str,
    expected: dict[str, object],
) -> None:
    harbor_without_trimming = catalog_text.replace(
        "+    normalized = raw.strip()\n",
        "",
        1,
    )
    expect_rejection(
        "Harbor trimming implementation removal",
        lambda: validate_catalog(harbor_without_trimming),
    )

    harbor_with_override = catalog_text.replace(
        "+    normalized = raw.strip()\n",
        "+    normalized = raw.strip()\n+    normalized = raw\n",
        1,
    )
    expect_rejection(
        "Harbor overriding normalized assignment",
        lambda: validate_catalog(harbor_with_override),
    )

    harbor_with_rebind = catalog_text.replace(
        HARBOR_FORMAT_SNIPPET,
        HARBOR_FORMAT_SNIPPET
        + '+formatLabel = lambda raw: {"value": raw, "original": raw}\n',
        1,
    )
    expect_rejection(
        "Harbor effective formatter rebinding",
        lambda: validate_catalog(harbor_with_rebind),
    )
    harbor_with_decorator = catalog_text.replace(
        HARBOR_FORMAT_DEFINITION,
        "+@lambda function: (lambda raw: raw)\n" + HARBOR_FORMAT_DEFINITION,
        1,
    )
    expect_rejection(
        "Harbor decorated formatter replacement",
        lambda: validate_catalog(harbor_with_decorator),
    )
    for label, binding in (
        ("Harbor annotated formatter rebinding", "+formatLabel: object = lambda raw: raw\n"),
        ("Harbor tuple-target formatter rebinding", "+formatLabel, = [lambda raw: raw]\n"),
        ("Harbor augmented formatter rebinding", "+formatLabel += lambda raw: raw\n"),
        ("Harbor named-expression formatter rebinding", "+value = (formatLabel := lambda raw: raw)\n"),
        ("Harbor namespace formatter rebinding", '+globals()["formatLabel"] = replacement\n'),
        ("Harbor namespace __setitem__ rebinding", '+globals().__setitem__("formatLabel", replacement)\n'),
        ("Harbor namespace dict-update rebinding", '+globals().update({"formatLabel": replacement})\n'),
        ("Harbor namespace pair-update rebinding", '+globals().update([("formatLabel", replacement)])\n'),
        ("Harbor namespace setdefault rebinding", '+globals().setdefault("formatLabel", replacement)\n'),
        ("Harbor namespace union-update rebinding", '+globals().__ior__({"formatLabel": replacement})\n'),
        ("Harbor namespace expanded dict-update rebinding", '+globals().update(**{"formatLabel": replacement})\n'),
        ("Harbor namespace f-string subscript rebinding", '+globals()[f"formatLabel"] = replacement\n'),
        ("Harbor namespace formatted f-string subscript rebinding", '+globals()[f"format{\'Label\'}"] = replacement\n'),
        ("Harbor namespace concatenated __setitem__ rebinding", '+globals().__setitem__("format" + "Label", replacement)\n'),
        ("Harbor computed variable subscript rebinding", '+key = "formatLabel"\n+globals()[key] = replacement\n'),
        ("Harbor computed variable update rebinding", '+key = "formatLabel"\n+globals().update({key: replacement})\n'),
        ("Harbor computed variable __setitem__ rebinding", '+key = "formatLabel"\n+globals().__setitem__(key, replacement)\n'),
        ("Harbor computed join subscript rebinding", '+key = "".join(("format", "Label"))\n+globals()[key] = replacement\n'),
    ):
        catalog_with_binding = catalog_text.replace(
            HARBOR_FORMAT_SNIPPET,
            HARBOR_FORMAT_SNIPPET + binding,
            1,
        )
        expect_rejection(
            label,
            lambda catalog_with_binding=catalog_with_binding: validate_catalog(catalog_with_binding),
        )

    expect_acceptance(
        "Harbor ordinary non-namespace subscript control",
        lambda: validate_catalog(
            catalog_text.replace(
                HARBOR_FORMAT_SNIPPET,
                HARBOR_FORMAT_SNIPPET
                + '+mapping = {}\n+mapping["formatLabel"] = replacement\n',
                1,
            )
        ),
    )

    for label, anchor, binding in (
        (
            "Harbor namespace-alias update rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+namespace = globals()\n+namespace.update({"formatLabel": replacement})\n',
        ),
        (
            "Harbor namespace-alias __setitem__ rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+namespace = globals()\n+namespace.__setitem__("formatLabel", replacement)\n',
        ),
        (
            "Harbor dict-update namespace rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+dict.update(globals(), {"formatLabel": replacement})\n',
        ),
        (
            "Harbor namespace-alias deterministic subscript rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+key = "formatLabel"\n+namespace = globals()\n+namespace[key] = replacement\n',
        ),
        (
            "Harbor namespace-alias literal subscript rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+namespace = globals()\n+namespace["formatLabel"] = replacement\n',
        ),
        (
            "Harbor namespace-alias joined-key subscript rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+namespace = globals()\n+namespace["".join(("format", "Label"))] = replacement\n',
        ),
        (
            "Harbor namespace-alias union rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+namespace = globals()\n+namespace |= {"formatLabel": replacement}\n',
        ),
        (
            "Harbor propagated namespace-alias update rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+namespace = globals()\n+second = namespace\n+second.update({"formatLabel": replacement})\n',
        ),
        (
            "Harbor propagated namespace-alias __setitem__ rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+namespace = globals()\n+second = namespace\n+second.__setitem__("formatLabel", replacement)\n',
        ),
        (
            "Harbor dict __setitem__ namespace rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+dict.__setitem__(globals(), "formatLabel", replacement)\n',
        ),
        (
            "Harbor dict pop namespace rebinding",
            HARBOR_FORMAT_SNIPPET,
            '+dict.pop(globals(), "formatLabel")\n',
        ),
    ):
        catalog_with_binding = catalog_text.replace(anchor, anchor + binding, 1)
        expect_rejection(
            label,
            lambda catalog_with_binding=catalog_with_binding: validate_catalog(catalog_with_binding),
        )

    for label, anchor, binding in (
        (
            "Linen namespace-alias update rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+namespace = globals()\n+namespace.update({"serializeRecord": replacement})\n',
        ),
        (
            "Linen namespace-alias __setitem__ rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+namespace = globals()\n+namespace.__setitem__("serializeRecord", replacement)\n',
        ),
        (
            "Linen dict-update namespace rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+dict.update(globals(), {"serializeRecord": replacement})\n',
        ),
        (
            "Linen namespace-alias deterministic subscript rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+key = "serializeRecord"\n+namespace = globals()\n+namespace[key] = replacement\n',
        ),
        (
            "Linen namespace-alias literal subscript rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+namespace = globals()\n+namespace["serializeRecord"] = replacement\n',
        ),
        (
            "Linen namespace-alias joined-key subscript rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+namespace = globals()\n+namespace["".join(("serialize", "Record"))] = replacement\n',
        ),
        (
            "Linen namespace-alias union rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+namespace = globals()\n+namespace |= {"serializeRecord": replacement}\n',
        ),
        (
            "Linen propagated namespace-alias update rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+namespace = globals()\n+second = namespace\n+second.update({"serializeRecord": replacement})\n',
        ),
        (
            "Linen propagated namespace-alias __setitem__ rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+namespace = globals()\n+second = namespace\n+second.__setitem__("serializeRecord", replacement)\n',
        ),
        (
            "Linen dict __setitem__ namespace rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+dict.__setitem__(globals(), "serializeRecord", replacement)\n',
        ),
        (
            "Linen dict pop namespace rebinding",
            LINEN_SERIALIZER_SNIPPET,
            '+dict.pop(globals(), "serializeRecord")\n',
        ),
    ):
        catalog_with_binding = catalog_text.replace(anchor, anchor + binding, 1)
        expect_rejection(
            label,
            lambda catalog_with_binding=catalog_with_binding: validate_catalog(catalog_with_binding),
        )

    expect_acceptance(
        "Linen ordinary non-namespace subscript control",
        lambda: validate_catalog(
            catalog_text.replace(
                LINEN_SERIALIZER_SNIPPET,
                LINEN_SERIALIZER_SNIPPET
                + '+mapping = {}\n+mapping["serializeRecord"] = replacement\n',
                1,
            )
        ),
    )

    for label, literal in (
        ("Harbor literal-only namespace call string", '+literal = "globals().__setitem__(\'formatLabel\', replacement)"\n'),
        ("Harbor literal-only assignment string", '+literal = "formatLabel = replacement"\n'),
    ):
        catalog_with_literal = catalog_text.replace(
            HARBOR_FORMAT_SNIPPET,
            HARBOR_FORMAT_SNIPPET + literal,
            1,
        )
        expect_acceptance(
            label,
            lambda catalog_with_literal=catalog_with_literal: validate_catalog(catalog_with_literal),
        )

    linen_with_null_emission = catalog_text.replace(
        "+            pairs.append((key, value))\n",
        "+            pairs.append((key, value))\n+        if value is None:\n+            pairs.append((key, value))\n",
        1,
    )
    expect_rejection(
        "Linen null-emission branch",
        lambda: validate_catalog(linen_with_null_emission),
    )

    linen_with_rebind = catalog_text.replace(
        LINEN_SERIALIZER_SNIPPET,
        LINEN_SERIALIZER_SNIPPET
        + '+serializeRecord = lambda record: json.dumps(record, ensure_ascii=False, separators=(",", ":"))\n',
        1,
    )
    expect_rejection(
        "Linen effective serializer rebinding",
        lambda: validate_catalog(linen_with_rebind),
    )
    linen_with_decorator = catalog_text.replace(
        LINEN_SERIALIZER_DEFINITION,
        "+@lambda function: (lambda record: \"altered\")\n" + LINEN_SERIALIZER_DEFINITION,
        1,
    )
    expect_rejection(
        "Linen decorated serializer replacement",
        lambda: validate_catalog(linen_with_decorator),
    )
    for label, binding in (
        ("Linen annotated serializer rebinding", "+serializeRecord: object = lambda record: record\n"),
        ("Linen tuple-target serializer rebinding", "+serializeRecord, = [lambda record: record]\n"),
        ("Linen augmented serializer rebinding", "+serializeRecord += lambda record: record\n"),
        ("Linen named-expression serializer rebinding", "+value = (serializeRecord := lambda record: record)\n"),
        ("Linen namespace serializer rebinding", '+globals()["serializeRecord"] = replacement\n'),
        ("Linen namespace __setitem__ rebinding", '+globals().__setitem__("serializeRecord", replacement)\n'),
        ("Linen namespace dict-update rebinding", '+globals().update({"serializeRecord": replacement})\n'),
        ("Linen namespace pair-update rebinding", '+globals().update([("serializeRecord", replacement)])\n'),
        ("Linen namespace setdefault rebinding", '+globals().setdefault("serializeRecord", replacement)\n'),
        ("Linen namespace union-update rebinding", '+globals().__ior__({"serializeRecord": replacement})\n'),
        ("Linen namespace expanded dict-update rebinding", '+globals().update(**{"serializeRecord": replacement})\n'),
        ("Linen namespace f-string subscript rebinding", '+globals()[f"serializeRecord"] = replacement\n'),
        ("Linen namespace formatted f-string subscript rebinding", '+globals()[f"serialize{\'Record\'}"] = replacement\n'),
        ("Linen namespace concatenated __setitem__ rebinding", '+globals().__setitem__("serialize" + "Record", replacement)\n'),
        ("Linen computed variable subscript rebinding", '+key = "serializeRecord"\n+globals()[key] = replacement\n'),
        ("Linen computed variable update rebinding", '+key = "serializeRecord"\n+globals().update({key: replacement})\n'),
        ("Linen computed variable __setitem__ rebinding", '+key = "serializeRecord"\n+globals().__setitem__(key, replacement)\n'),
        ("Linen computed join subscript rebinding", '+key = "".join(("serialize", "Record"))\n+globals()[key] = replacement\n'),
    ):
        catalog_with_binding = catalog_text.replace(
            LINEN_SERIALIZER_SNIPPET,
            LINEN_SERIALIZER_SNIPPET + binding,
            1,
        )
        expect_rejection(
            label,
            lambda catalog_with_binding=catalog_with_binding: validate_catalog(catalog_with_binding),
        )

    for label, literal in (
        ("Linen literal-only namespace call string", '+literal = "globals().__setitem__(\'serializeRecord\', replacement)"\n'),
        ("Linen literal-only assignment string", '+literal = "serializeRecord = replacement"\n'),
    ):
        catalog_with_literal = catalog_text.replace(
            LINEN_SERIALIZER_SNIPPET,
            LINEN_SERIALIZER_SNIPPET + literal,
            1,
        )
        expect_acceptance(
            label,
            lambda catalog_with_literal=catalog_with_literal: validate_catalog(catalog_with_literal),
        )

    expected_without_linen_omission = json.loads(expected_text)
    linen = next(
        fixture
        for fixture in expected_without_linen_omission["fixtures"]
        if fixture["id"] == "linen-export"
    )
    linen["coverage"] = [row for row in linen["coverage"] if row["id"] != "R2"]
    expect_rejection(
        "Linen direct null-omission coverage removal",
        lambda: validate_results(expected_without_linen_omission, catalog_text),
    )

    expected_without_dependency_coverage = json.loads(expected_text)
    harbor = next(
        fixture
        for fixture in expected_without_dependency_coverage["fixtures"]
        if fixture["id"] == "harbor-labels"
    )
    harbor["coverage"] = [row for row in harbor["coverage"] if row["id"] != "R4"]
    expect_rejection(
        "Harbor dependency reconciliation coverage removal",
        lambda: validate_results(expected_without_dependency_coverage, catalog_text),
    )

    expected_with_non_public_status = json.loads(expected_text)
    harbor = next(
        fixture
        for fixture in expected_with_non_public_status["fixtures"]
        if fixture["id"] == "harbor-labels"
    )
    next(row for row in harbor["coverage"] if row["id"] == "R4")["status"] = "Partial status"
    expect_rejection(
        "Harbor non-public status mutation",
        lambda: validate_results(expected_with_non_public_status, catalog_text),
    )

    expected_without_failed_guard = json.loads(expected_text)
    cobalt = next(
        fixture
        for fixture in expected_without_failed_guard["fixtures"]
        if fixture["id"] == "cobalt-parser"
    )
    del cobalt["blockingFindings"][0]["failedGuard"]
    expect_rejection(
        "Cobalt failed-guard schema removal",
        lambda: validate_results(expected_without_failed_guard, catalog_text),
    )

    expected_with_placeholder_failed_guard = json.loads(expected_text)
    cobalt = next(
        fixture
        for fixture in expected_with_placeholder_failed_guard["fixtures"]
        if fixture["id"] == "cobalt-parser"
    )
    cobalt["blockingFindings"][0]["failedGuard"] = "The control failed."
    expect_rejection(
        "Cobalt placeholder failed-guard analysis",
        lambda: validate_results(expected_with_placeholder_failed_guard, catalog_text),
    )

    expected_with_wrong_choices = json.loads(expected_text)
    ember = next(
        fixture
        for fixture in expected_with_wrong_choices["fixtures"]
        if fixture["id"] == "ember-report"
    )
    ember["outOfScopeInventory"][0]["choices"][0] = "Expand this task now"
    expect_rejection(
        "Ember out-of-scope choice mutation",
        lambda: validate_results(expected_with_wrong_choices, catalog_text),
    )

    expected_without_finding_choices = json.loads(expected_text)
    ember = next(
        fixture
        for fixture in expected_without_finding_choices["fixtures"]
        if fixture["id"] == "ember-report"
    )
    ember["blockingFindings"][0]["fixBoundary"] = "Pause for explicit user choice; do not choose."
    expect_rejection(
        "Ember finding choice disclosure removal",
        lambda: validate_results(expected_without_finding_choices, catalog_text),
    )

    catalog_without_dependency_section = catalog_text.replace(
        "**Dependencies and relationships**\n",
        "",
        1,
    )
    expect_rejection(
        "Harbor dependency fixture section removal",
        lambda: validate_catalog(catalog_without_dependency_section),
    )

    harbor_with_extra_storage_diff = catalog_text.replace(
        "```\n\nValidation evidence\n",
        "diff --git a/storage/schema.py b/storage/schema.py\n"
        "--- a/storage/schema.py\n"
        "+++ b/storage/schema.py\n"
        "@@\n"
        "+changed = True\n"
        "```\n\nValidation evidence\n",
        1,
    )
    expect_rejection(
        "Harbor added storage diff",
        lambda: validate_catalog(harbor_with_extra_storage_diff),
    )

    harbor_with_public_dependency_contradiction = catalog_text.replace(
        "- Reload/reconciliation before judgment: reload the source at target head "
        "`1111111111111111111111111111111111111111` and reconcile it with the change contract, "
        "full diff, validation evidence, and handoff claims before judgment.\n",
        "- Reload/reconciliation before judgment: reload the source at target head "
        "`1111111111111111111111111111111111111111` and reconcile it with the change contract, "
        "full diff, validation evidence, and handoff claims before judgment.\n"
        "Reload/reconciliation before judgment: do not reload the dependency; use the handoff claim as proof.\n",
        1,
    )
    expect_rejection(
        "Harbor contradictory public dependency prose",
        lambda: validate_catalog(harbor_with_public_dependency_contradiction),
    )

    expected_with_private_dependency_contradiction = json.loads(expected_text)
    harbor = next(
        fixture
        for fixture in expected_with_private_dependency_contradiction["fixtures"]
        if fixture["id"] == "harbor-labels"
    )
    harbor_dependency_row = next(row for row in harbor["coverage"] if row["id"] == "R4")
    harbor_dependency_row["diffEvidence"] += " The dependency was not reloaded."
    expect_rejection(
        "Harbor contradictory private dependency evidence",
        lambda: validate_results(expected_with_private_dependency_contradiction, catalog_text),
    )

    for label, answer_hint in (
        ("neutral bare approve verb insertion", "Approve.\n"),
        ("neutral bare accept verb insertion", "Accept.\n"),
        ("neutral bare recommend approval insertion", "Recommend approval.\n"),
        ("neutral first-person plural recommendation insertion", "We recommend approval.\n"),
        ("neutral first-person singular recommendation insertion", "I recommend acceptance.\n"),
        (
            "neutral hyphenated reviewer recommendation insertion",
            "The reviewer recommends-that we approve.\n",
        ),
        (
            "neutral hyphenated recommended-disposition statement insertion",
            "The recommended-disposition would be approval.\n",
        ),
        (
            "neutral hyphenated recommended-disposition label insertion",
            "Recommended-disposition: approval.\n",
        ),
        ("neutral fixture expected-outcome insertion", "Expected outcome: accept.\n"),
        ("neutral fixture bare-outcome insertion", "Outcome: accept.\n"),
        ("neutral fixture em-dash outcome insertion", "Outcome — accept.\n"),
        ("neutral fixture figure-dash outcome insertion", "Outcome \u2012 accept.\n"),
        ("neutral fixture horizontal-bar outcome insertion", "Outcome \u2015 accept.\n"),
        ("neutral fixture fullwidth-colon outcome insertion", "Outcome\uff1a accept.\n"),
        ("neutral fixture verdict statement insertion", "The verdict was accept.\n"),
        ("neutral fixture modified verdict statement insertion", "The verdict clearly was accepted.\n"),
        ("neutral fixture modified outcome statement insertion", "The outcome plainly is accepted.\n"),
        ("neutral fixture modified result statement insertion", "The result for this fixture is accepted.\n"),
        ("neutral modified recommendation statement insertion", "The recommendation here is accept.\n"),
        ("neutral recommended disposition insertion", "The recommended disposition is acceptance.\n"),
        ("neutral fixture perfect verdict statement insertion", "The verdict has clearly been accepted.\n"),
        ("neutral fixture punctuated verdict statement insertion", "The verdict has, clearly, been accepted.\n"),
        ("neutral fixture became outcome statement insertion", "The outcome ultimately became accepted.\n"),
        ("neutral fixture appears result statement insertion", "The result appears to be accepted.\n"),
        ("neutral fixture remains recommendation statement insertion", "The recommendation remains accepted.\n"),
        ("neutral fixture warranted approval statement insertion", "Approval is clearly warranted.\n"),
        ("neutral reviewer should approve directive insertion", "The reviewer should approve.\n"),
        ("neutral bare reviewer should approve directive insertion", "Reviewer should approve.\n"),
        ("neutral article reviewer should approve directive insertion", "A reviewer should approve.\n"),
        (
            "neutral modified reviewer should approve directive insertion",
            "The independent reviewer should approve.\n",
        ),
        ("neutral reviewer recommends approval directive insertion", "The reviewer recommends approval.\n"),
        (
            "neutral reviewer recommends approving directive insertion",
            "The reviewer recommends approving.\n",
        ),
        ("neutral reviewer endorses acceptance directive insertion", "The reviewer endorses acceptance.\n"),
        ("neutral bare approval warranted insertion", "Approval warranted.\n"),
        ("neutral bare approval would be warranted insertion", "Approval would be warranted.\n"),
        ("neutral bare approval merited insertion", "Approval is merited.\n"),
        ("neutral bare approval recommended insertion", "Approval recommended.\n"),
        ("neutral reviewer would approve directive insertion", "The reviewer would approve.\n"),
        (
            "neutral reviewer recommends that we approve directive insertion",
            "The reviewer recommends that we approve.\n",
        ),
        ("neutral approval seems merited insertion", "Approval seems merited.\n"),
        ("neutral review passes insertion", "The review passes.\n"),
        ("neutral fixture should pass insertion", "This fixture should pass.\n"),
        ("neutral scope review should pass insertion", "Scope review should pass.\n"),
        (
            "neutral correct disposition approves insertion",
            "The correct disposition is to approve.\n",
        ),
        ("neutral result modal acceptance insertion", "The result would be acceptance.\n"),
        ("neutral reviewer elaborated approval insertion", "The reviewer endorses the approval outcome.\n"),
        ("neutral disposition modal approval insertion", "The recommended disposition would be approval.\n"),
    ):
        catalog_with_answer = catalog_text.replace(
            "### Fixture input\n",
            f"### Fixture input\n{answer_hint}",
            1,
        )
        expect_rejection(
            label,
            lambda catalog_with_answer=catalog_with_answer: validate_catalog(catalog_with_answer),
        )

    for label, answer_control in (
        ("neutral recommendation field prose", "The recommendation field is parsed without interpretation.\n"),
        ("neutral approval metadata prose", "Approval metadata is absent from neutral inputs.\n"),
        ("neutral reviewer reads approval document", "The reviewer reads the approval document before inspecting the diff.\n"),
        ("neutral reviewer parses approval metadata", "The reviewer parses approval metadata without recommending a terminal result.\n"),
    ):
        catalog_with_control = catalog_text.replace(
            "### Fixture input\n",
            f"### Fixture input\n{answer_control}",
            1,
        )
        expect_acceptance(
            label,
            lambda catalog_with_control=catalog_with_control: validate_catalog(catalog_with_control),
        )

    expect_rejection(
        "malformed OpenAI metadata",
        lambda: validate_metadata(openai_text + "broken: [\n"),
    )

    dynamic_script = script_text + '\nvalue = eval("__import__(\'requests\')")\n'
    expect_rejection(
        "dynamic execution and import resolution",
        lambda: validate_script_imports(dynamic_script),
    )
    for label, addition in (
        ("exec dynamic execution", "\nexec(\"pass\")\n"),
        ("compile dynamic execution", "\ncompile(\"pass\", \"<probe>\", \"exec\")\n"),
        (
            "indirect import-hook access",
            '\nresolver = getattr(__builtins__, "__import__")\n',
        ),
        (
            "function globals indirect import-hook path",
            '\nscope = (lambda: None).__globals__\n'
            'hook = scope["__builtins__"]["__import__"]\n'
            'value = hook("requests")\n',
        ),
        (
            "function globals indirect dynamic-execution path",
            '\nscope = (lambda: None).__globals__\n'
            'value = scope["__builtins__"]["eval"]\n',
        ),
    ):
        probe_script = script_text + addition
        expect_rejection(
            label,
            lambda probe_script=probe_script: validate_script_imports(probe_script),
        )

    for label, technology_claim in (
        ("unlisted framework requirement leakage", "This workflow requires Next.js.\n"),
        ("unlisted framework passive requirement leakage", "Next.js is required by this workflow.\n"),
        ("unlisted framework based-on leakage", "This workflow is based on Next.js.\n"),
        ("unlisted framework hyphenated based-on leakage", "This workflow is based-on Next.js.\n"),
        ("unlisted framework built-upon leakage", "This workflow is built upon Next.js.\n"),
        ("unlisted framework hyphenated built-upon leakage", "This workflow is built-upon Next.js.\n"),
        ("unlisted framework mandate leakage", "This workflow mandates Next.js.\n"),
        ("unlisted framework the-use mandate leakage", "This workflow mandates the use of Next.js.\n"),
        ("unlisted framework use-of requirement leakage", "This workflow requires use of Next.js.\n"),
        ("unlisted framework preferred requirement leakage", "This workflow requires the preferred Next.js framework.\n"),
        ("unlisted framework preferred mandate leakage", "This workflow mandates the preferred Next.js framework.\n"),
        ("unlisted framework preferred use mandate leakage", "This workflow must use the preferred Next.js framework.\n"),
        ("unlisted framework carefully selected requirement leakage", "This workflow requires the carefully selected Next.js.\n"),
        ("unlisted framework punctuation filler mandate leakage", "This workflow mandates, by design, Next.js.\n"),
        ("unlisted framework bounded filler use leakage", "This workflow uses the deliberately chosen, current Next.js.\n"),
        ("unlisted dotted technology filler leakage", "This workflow is based on the carefully selected Foo.Bar.\n"),
        ("unlisted framework adverb filler leakage", "This workflow requires the thoughtfully selected Next.js.\n"),
        ("unlisted framework designed filler leakage", "This workflow mandates, as designed, Next.js.\n"),
        ("unlisted framework use-of hyphen leakage", "This workflow mandates the use-of Next.js.\n"),
        ("unlisted scoped package requirement leakage", "This workflow requires @angular/core.\n"),
        ("unlisted framework based-upon leakage", "This workflow is based upon Next.js.\n"),
        ("unlisted framework hyphenated based-upon leakage", "This workflow is based-upon Next.js.\n"),
        ("unlisted React passive requirement leakage", "React is required by this workflow.\n"),
        ("unlisted lowercase framework passive requirement leakage", "nextjs is required by this workflow.\n"),
        ("unlisted lowercase framework requirement leakage", "This workflow requires nextjs.\n"),
        (
            "unlisted framework long filler leakage",
            "This workflow requires the deliberately chosen, current, primary, underlying, target, approved, curated, canonical, intended, production-ready, stable, specific Next.js.\n",
        ),
        (
            "unlisted framework long neutral filler leakage",
            "This workflow requires the deliberately chosen, current, primary, underlying, target, curated, canonical, intended, production-ready, stable, specific Next.js.\n",
        ),
    ):
        catalog_with_framework = catalog_text.replace(
            "### Fixture input\n",
            f"### Fixture input\n{technology_claim}",
            1,
        )
        expect_rejection(
            label,
            lambda catalog_with_framework=catalog_with_framework: validate_catalog(catalog_with_framework),
        )

    for label, repository_reference in (
        ("repository AGENTS guidance path", "The reviewer must use AGENTS.md.\n"),
        ("repository README guidance path", "The reviewer must use README.md.\n"),
        ("repository docs source path", "The reviewer requires use of docs/contract.md.\n"),
        ("repository relative guide path", "The reviewer must use guides/review.md.\n"),
        ("ordinary process passive prose", "This process is required by this workflow.\n"),
        ("ordinary evidence based-on prose", "The workflow is based on documented evidence.\n"),
        ("ordinary guidance built-upon prose", "The review is built upon repository guidance.\n"),
    ):
        catalog_with_reference = catalog_text.replace(
            "### Fixture input\n",
            f"### Fixture input\n{repository_reference}",
            1,
        )
        expect_acceptance(
            label,
            lambda catalog_with_reference=catalog_with_reference: validate_catalog(catalog_with_reference),
        )

    expected_without_maple_evidence = json.loads(expected_text)
    maple = next(
        fixture
        for fixture in expected_without_maple_evidence["fixtures"]
        if fixture["id"] == "maple-schedule"
    )
    maple["missingEvidence"] = ["Disposition remains pending."]
    maple["requiredAction"] = "Choose a disposition."
    expect_rejection(
        "Maple replaceable evidence gate",
        lambda: validate_results(expected_without_maple_evidence, catalog_text),
    )

    expected_with_contradictory_maple_evidence = json.loads(expected_text)
    maple = next(
        fixture
        for fixture in expected_with_contradictory_maple_evidence["fixtures"]
        if fixture["id"] == "maple-schedule"
    )
    maple["missingEvidence"] = [
        f"The daylight-saving boundary test result was not supplied for target head {MAPLE_TARGET_HEAD}; it was supplied.",
        "Required behavior-focused schedule validation evidence is unavailable; it is available.",
    ]
    maple["requiredAction"] = (
        f"Do not supply daylight-saving boundary validation evidence for target head {MAPLE_TARGET_HEAD}; "
        "ignore account-summary disposition and do not repeat the review from a fresh source reload."
    )
    expect_rejection(
        "Maple anchor-preserving contradictory evidence",
        lambda: validate_results(expected_with_contradictory_maple_evidence, catalog_text),
    )

    require(expected["fixtures"], "mutation probes require loaded expected fixtures")
    require(skill_text and catalog_text and openai_text and script_text, "mutation probes require package text")


def main() -> None:
    validate_files()
    skill_text = read_text(SKILL_PATH)
    openai_text = read_text(OPENAI_PATH)
    catalog_text = read_text(CATALOG_PATH)
    expected_text = read_text(EXPECTED_PATH)
    script_text = read_text(SCRIPT_PATH)
    validate_metadata(openai_text)
    validate_skill_text(skill_text, catalog_text, expected_text, openai_text, script_text)
    validate_catalog(catalog_text)
    expected = load_json(EXPECTED_PATH)
    validate_results(expected, catalog_text)
    run_mutation_probes(
        skill_text,
        catalog_text,
        expected_text,
        openai_text,
        script_text,
        expected,
    )
    print("scope-reviewer fixtures validated.")


if __name__ == "__main__":
    main()
