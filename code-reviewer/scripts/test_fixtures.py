#!/usr/bin/env python3
"""Validate the pragmatic reviewer calibration fixture contract."""

from __future__ import annotations

import json
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parent.parent
SKILL_PATH = SKILL_ROOT / "SKILL.md"
CATALOG_PATH = SKILL_ROOT / "references" / "fixture-catalog.md"
EXPECTED_PATH = SKILL_ROOT / "references" / "expected-results.json"

EXPECTED_IDS = {
    "material-defect": "Request changes",
    "preference-only": "Approved",
    "mixed-guidance": "Request changes",
    "clean-change": "Approved",
}
REQUIRED_FINDING_KEYS = {"scenario", "impact", "evidence", "fixBoundary"}
REQUIRED_SKILL_PHRASES = {
    "AGENTS.md",
    "Concrete scenario",
    "Smallest reasonable fix boundary",
    "Suggestion (non-blocking)",
    "Conclusion: Approved",
    "Conclusion: Request changes",
    "context compact, resume, or handoff",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    skill_text = SKILL_PATH.read_text(encoding="utf-8")
    catalog_text = CATALOG_PATH.read_text(encoding="utf-8")
    expected = json.loads(EXPECTED_PATH.read_text(encoding="utf-8"))

    require("TODO" not in skill_text, "SKILL.md still contains scaffold TODO text")
    for phrase in REQUIRED_SKILL_PHRASES:
        require(phrase in skill_text, f"SKILL.md is missing required phrase: {phrase}")

    fixtures = expected.get("fixtures")
    require(isinstance(fixtures, list), "expected-results.json must contain a fixtures array")
    require(len(fixtures) == len(EXPECTED_IDS), "fixture result count does not match contract")

    seen: set[str] = set()
    for fixture in fixtures:
        require(isinstance(fixture, dict), "each expected fixture result must be an object")
        fixture_id = fixture.get("id")
        require(fixture_id in EXPECTED_IDS, f"unexpected fixture id: {fixture_id}")
        require(fixture_id not in seen, f"duplicate fixture id: {fixture_id}")
        seen.add(fixture_id)
        require(
            fixture.get("expectedDecision") == EXPECTED_IDS[fixture_id],
            f"wrong expected decision for {fixture_id}",
        )
        require(f"## Fixture: {fixture_id}" in catalog_text, f"catalog is missing {fixture_id}")

        findings = fixture.get("blockingFindings")
        suggestions = fixture.get("nonBlockingSuggestions")
        require(isinstance(findings, list), f"{fixture_id} blockingFindings must be an array")
        require(isinstance(suggestions, list), f"{fixture_id} nonBlockingSuggestions must be an array")
        if fixture["expectedDecision"] == "Request changes":
            require(findings, f"{fixture_id} must have a blocking finding")
        else:
            require(not findings, f"{fixture_id} cannot be approved with a blocker")

        for finding in findings:
            require(isinstance(finding, dict), f"{fixture_id} finding must be an object")
            require(
                REQUIRED_FINDING_KEYS == set(finding),
                f"{fixture_id} finding must contain scenario, impact, evidence, and fixBoundary",
            )
            require(
                all(isinstance(value, str) and value.strip() for value in finding.values()),
                f"{fixture_id} finding fields must be non-empty strings",
            )

    require(seen == set(EXPECTED_IDS), "fixture IDs do not match the expected catalog")
    require(
        len(next(item for item in fixtures if item["id"] == "mixed-guidance")["blockingFindings"]) == 1,
        "mixed fixture must block only the material defect",
    )
    print("Pragmatic code-reviewer fixtures validated.")


if __name__ == "__main__":
    main()
