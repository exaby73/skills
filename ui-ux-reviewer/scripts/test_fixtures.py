#!/usr/bin/env python3
"""Validate the strict UI/UX reviewer calibration fixture contract."""

from __future__ import annotations

import json
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parent.parent
SKILL_PATH = SKILL_ROOT / "SKILL.md"
OPENAI_PATH = SKILL_ROOT / "agents" / "openai.yaml"
CATALOG_PATH = SKILL_ROOT / "references" / "fixture-catalog.md"
EXPECTED_PATH = SKILL_ROOT / "references" / "expected-results.json"

EXPECTED_DECISIONS = {
    "material-ui-defects": "Request changes",
    "preference-only-ui": "Approved",
    "clean-ui": "Approved",
    "evidence-blocked-ui": "Evidence blocked",
}
REQUIRED_FINDING_KEYS = {
    "severity",
    "scenario",
    "impact",
    "evidence",
    "governingCriterion",
    "fixBoundary",
}
REQUIRED_SKILL_PHRASES = {
    "AGENTS.md",
    "Concrete scenario",
    "Smallest reasonable fix boundary",
    "Suggestion (non-blocking)",
    "Conclusion: Approved",
    "Conclusion: Request changes",
    "Conclusion: Evidence blocked",
    "context compact, resume, or handoff",
    "filesystem root",
    "rendered",
    "Evidence blocked",
}
FORBIDDEN_LEAKAGE = (
    "tfs" + "crims",
    "s" + "velte",
    "tail" + "wind",
    "shad" + "cn",
    "boot" + "strap",
    "chakra " + "ui",
    "ant " + "design",
    "vue" + "tify",
    "fluent " + "ui",
    "radix " + "ui",
    "carbon " + "design",
    "lightning " + "design system",
)
EXPECTED_FILES = {
    Path("SKILL.md"),
    Path("agents/openai.yaml"),
    Path("references/fixture-catalog.md"),
    Path("references/expected-results.json"),
    Path("scripts/test_fixtures.py"),
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def load_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"invalid JSON in {path.name}: {error}") from error
    require(isinstance(value, dict), f"{path.name} must contain a JSON object")
    return value


def main() -> None:
    actual_files = {
        path.relative_to(SKILL_ROOT)
        for path in SKILL_ROOT.rglob("*")
        if path.is_file()
    }
    require(actual_files == EXPECTED_FILES, f"unexpected skill files: {sorted(actual_files - EXPECTED_FILES)}")

    skill_text = SKILL_PATH.read_text(encoding="utf-8")
    catalog_text = CATALOG_PATH.read_text(encoding="utf-8")
    expected = load_json(EXPECTED_PATH)

    require("TODO" not in skill_text, "SKILL.md still contains scaffold TODO text")
    for phrase in REQUIRED_SKILL_PHRASES:
        require(phrase in skill_text, f"SKILL.md is missing required phrase: {phrase}")

    content_text = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (SKILL_PATH, OPENAI_PATH, CATALOG_PATH, EXPECTED_PATH)
    ).lower()
    for term in FORBIDDEN_LEAKAGE:
        require(term not in content_text, f"skill content contains project or vendor leakage: {term}")

    require("expectedDecision" not in catalog_text, "fixture input leaks expected decisions")
    require("blockingFindings" not in catalog_text, "fixture input leaks blocking findings")
    require("nonBlockingSuggestions" not in catalog_text, "fixture input leaks suggestion results")
    for conclusion in (
        "Conclusion: Approved",
        "Conclusion: Request changes",
        "Conclusion: Evidence blocked",
    ):
        require(conclusion not in catalog_text, f"fixture input leaks answer conclusion: {conclusion}")

    fixtures = expected.get("fixtures")
    require(isinstance(fixtures, list), "expected-results.json must contain a fixtures array")
    require(len(fixtures) == len(EXPECTED_DECISIONS), "fixture result count does not match contract")

    seen: set[str] = set()
    for fixture in fixtures:
        require(isinstance(fixture, dict), "each expected fixture result must be an object")
        fixture_id = fixture.get("id")
        require(isinstance(fixture_id, str), "fixture id must be a string")
        require(fixture_id in EXPECTED_DECISIONS, f"unexpected fixture id: {fixture_id}")
        require(fixture_id not in seen, f"duplicate fixture id: {fixture_id}")
        seen.add(fixture_id)
        require(
            fixture.get("expectedDecision") == EXPECTED_DECISIONS[fixture_id],
            f"wrong expected decision for {fixture_id}",
        )
        require(catalog_text.count(f"## Fixture: {fixture_id}\n") == 1, f"catalog is missing {fixture_id}")
        require(
            f"## Fixture: {fixture_id}\n\n### Fixture input\n" in catalog_text,
            f"{fixture_id} must expose one neutral fixture input section",
        )

        findings = fixture.get("blockingFindings")
        suggestions = fixture.get("nonBlockingSuggestions")
        require(isinstance(findings, list), f"{fixture_id} blockingFindings must be an array")
        require(isinstance(suggestions, list), f"{fixture_id} nonBlockingSuggestions must be an array")
        if fixture["expectedDecision"] == "Request changes":
            require(findings, f"{fixture_id} must have a blocking finding")
        else:
            require(not findings, f"{fixture_id} cannot conclude without zero blocking findings")
        if fixture["expectedDecision"] in {"Approved", "Evidence blocked"}:
            require(not suggestions, f"{fixture_id} must have no suggestions in this calibration")

        for finding in findings:
            require(isinstance(finding, dict), f"{fixture_id} finding must be an object")
            require(
                set(finding) == REQUIRED_FINDING_KEYS,
                f"{fixture_id} finding keys must be severity, scenario, impact, evidence, governingCriterion, and fixBoundary",
            )
            require(
                finding["severity"] in {"Blocker", "Major"},
                f"{fixture_id} finding severity must be Blocker or Major",
            )
            require(
                all(isinstance(value, str) and value.strip() for value in finding.values()),
                f"{fixture_id} finding fields must be non-empty strings",
            )

        for suggestion in suggestions:
            require(
                isinstance(suggestion, str)
                and suggestion.startswith("Suggestion (non-blocking):")
                and suggestion.strip(),
                f"{fixture_id} suggestions must be explicitly non-blocking",
            )

        if fixture["expectedDecision"] == "Evidence blocked":
            missing = fixture.get("missingEvidence")
            action = fixture.get("requiredAction")
            require(
                isinstance(missing, list) and missing and all(isinstance(item, str) and item.strip() for item in missing),
                "evidence-blocked-ui must list missing evidence",
            )
            require(isinstance(action, str) and action.strip(), "evidence-blocked-ui must list a required action")

    require(seen == set(EXPECTED_DECISIONS), "fixture IDs do not match the expected catalog")
    require(
        any(fixture.get("id") == "evidence-blocked-ui" for fixture in fixtures),
        "evidence-blocked-ui fixture is required",
    )
    require(
        len(next(item for item in fixtures if item["id"] == "material-ui-defects")["blockingFindings"]) == 4,
        "material-ui-defects must preserve the four actionable defect findings",
    )
    print("UI/UX reviewer fixtures validated.")


if __name__ == "__main__":
    main()
