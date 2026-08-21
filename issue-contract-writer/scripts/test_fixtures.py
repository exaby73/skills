#!/usr/bin/env python3
"""Validate the finite issue-contract-writer calibration corpus."""

from __future__ import annotations

import json
import re
import ast
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parent.parent
SKILL_PATH = SKILL_ROOT / "SKILL.md"
CATALOG_PATH = SKILL_ROOT / "references" / "fixture-catalog.md"
EXPECTED_PATH = SKILL_ROOT / "references" / "expected-results.json"

EXPECTED_CONCLUSIONS = {
    "unbounded-natural-language": "Reject as unbounded",
    "bounded-structural": "Ready to publish",
    "finite-universal": "Ready to publish",
    "ambiguous-evidence": "Needs clarification",
    "fixture-boundary": "Ready to publish",
}
REQUIRED_CONTRACT_SECTIONS = (
    "## Outcome\n",
    "## In scope\n",
    "## Explicit exclusions\n",
    "## Acceptance criteria\n",
    "## Validation evidence\n",
    "## Dependencies and relationships\n",
    "## Stopping conditions\n",
    "## Owner decisions\n",
)
POSITIVE_FIXTURES = {
    "bounded-structural",
    "finite-universal",
    "fixture-boundary",
}
ALLOWED_CONCLUSIONS = {
    "Ready to publish",
    "Needs clarification",
    "Reject as unbounded",
    "Evidence blocked",
}
REQUIRED_SKILL_PHRASES = {
    "source record",
    "finite observable result",
    "named validator or human decision",
    "risk indicators, not forbidden words",
    "defined finite domain or a testable property",
    "arbitrary natural-language paraphrases",
    "indefinitely expanding reviewer-generated corpus",
    "explicit security or production boundary",
    "does not independently mutate GitHub state",
    "Conclusion: Ready to publish",
    "Conclusion: Needs clarification",
    "Conclusion: Reject as unbounded",
    "Conclusion: Evidence blocked",
    "finite, frozen calibration inputs",
}
REQUIRED_CATALOG_MARKERS = (
    "### Fixture input\n",
    "Repository `AGENTS.md`\n",
    "Current implementation\n",
    "Related issue\n",
    "Proposed contract\n",
)
FORBIDDEN_MODULES = {"subprocess", "importlib", "urllib", "socket"}
FORBIDDEN_CALLS = {"eval", "exec", "compile", "__import__"}


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
    for marker in REQUIRED_CATALOG_MARKERS:
        require(marker in catalog_text, f"fixture catalog is missing marker: {marker!r}")
    require(
        "This corpus is frozen for the review cycle." in catalog_text,
        "fixture catalog must declare its frozen review-cycle boundary",
    )

    script_tree = ast.parse(Path(__file__).read_text(encoding="utf-8"))
    for node in ast.walk(script_tree):
        if isinstance(node, ast.Import):
            imported = {alias.name.split(".", 1)[0] for alias in node.names}
            require(not imported & FORBIDDEN_MODULES, "fixture validator imports a forbidden dynamic module")
        if isinstance(node, ast.ImportFrom):
            module = (node.module or "").split(".", 1)[0]
            require(module not in FORBIDDEN_MODULES, "fixture validator imports a forbidden dynamic module")
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            require(node.func.id not in FORBIDDEN_CALLS, "fixture validator invokes forbidden dynamic execution")

    fixtures = expected.get("fixtures")
    require(expected.get("version") == 1, "expected-results.json must use version 1")
    require(isinstance(fixtures, list), "expected-results.json must contain a fixtures array")
    require(len(fixtures) == len(EXPECTED_CONCLUSIONS), "fixture result count does not match frozen corpus")

    expected_ids = list(EXPECTED_CONCLUSIONS)
    catalog_ids = re.findall(r"^## Fixture: ([a-z0-9-]+)$", catalog_text, flags=re.MULTILINE)
    require(catalog_ids == expected_ids, "fixture catalog IDs or order differ from frozen corpus")

    seen: set[str] = set()
    for fixture in fixtures:
        require(isinstance(fixture, dict), "each expected fixture result must be an object")
        require(
            set(fixture) == {"id", "expectedConclusion", "requiredSignals"},
            "each fixture result must contain only id, expectedConclusion, and requiredSignals",
        )
        fixture_id = fixture["id"]
        require(fixture_id in EXPECTED_CONCLUSIONS, f"unexpected fixture id: {fixture_id}")
        require(fixture_id not in seen, f"duplicate fixture id: {fixture_id}")
        seen.add(fixture_id)
        require(
            fixture["expectedConclusion"] in ALLOWED_CONCLUSIONS,
            f"invalid conclusion for {fixture_id}",
        )
        require(
            fixture["expectedConclusion"] == EXPECTED_CONCLUSIONS[fixture_id],
            f"wrong expected conclusion for {fixture_id}",
        )
        require(
            f"## Fixture: {fixture_id}\n\n### Fixture input\n" in catalog_text,
            f"catalog is missing complete fixture input for {fixture_id}",
        )
        fixture_text = catalog_text.split(f"## Fixture: {fixture_id}\n", 1)[1].split(
            "\n## Fixture:", 1
        )[0]
        signals = fixture["requiredSignals"]
        require(isinstance(signals, list) and signals, f"{fixture_id} needs required signals")
        require(
            all(isinstance(signal, str) and signal.strip() for signal in signals),
            f"{fixture_id} required signals must be non-empty strings",
        )
        for signal in signals:
            require(signal in fixture_text, f"{fixture_id} is missing frozen signal: {signal}")
        if fixture_id in POSITIVE_FIXTURES:
            for section in REQUIRED_CONTRACT_SECTIONS:
                require(
                    section in fixture_text,
                    f"{fixture_id} positive fixture is missing contract section: {section.strip()}",
                )
            require(
                "Residual risk" in fixture_text,
                f"{fixture_id} positive fixture must state residual risk",
            )

    require(seen == set(EXPECTED_CONCLUSIONS), "fixture IDs do not match frozen corpus")
    require(
        "Reject as unbounded" in skill_text and "Needs clarification" in skill_text,
        "skill must distinguish unbounded rejection from clarification",
    )
    require(
        "must not grow from reviewer-generated paraphrases" in skill_text,
        "skill must keep the calibration corpus fixed during a review cycle",
    )
    print("Issue-contract-writer fixtures validated.")


if __name__ == "__main__":
    main()
