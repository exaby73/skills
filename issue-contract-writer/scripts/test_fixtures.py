#!/usr/bin/env python3
"""Validate the finite issue-contract-writer calibration corpus."""

from __future__ import annotations

import ast
import hashlib
import json
import re
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parent.parent
SKILL_PATH = SKILL_ROOT / "SKILL.md"
CATALOG_PATH = SKILL_ROOT / "references" / "fixture-catalog.md"
EXPECTED_PATH = SKILL_ROOT / "references" / "expected-results.json"

EXPECTED_PACKAGE_PATHS = (
    "SKILL.md",
    "agents/openai.yaml",
    "references/expected-results.json",
    "references/fixture-catalog.md",
    "scripts/test_fixtures.py",
)
EXPECTED_CONCLUSIONS = {
    "unbounded-natural-language": "Reject as unbounded",
    "bounded-structural": "Ready to publish",
    "finite-universal": "Ready to publish",
    "ambiguous-evidence": "Needs clarification",
    "fixture-boundary": "Ready to publish",
}
EXPECTED_KINDS = {
    "unbounded-natural-language": "negative",
    "bounded-structural": "positive",
    "finite-universal": "positive",
    "ambiguous-evidence": "negative",
    "fixture-boundary": "positive",
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
REQUIRED_SKILL_MARKERS = (
    "# Issue Contract Writer\n",
    "## Establish the source record\n",
    "## Draft a finite delivery contract\n",
    "## Screen universal and open-ended language\n",
    "## Publication gate\n",
    "## Report\n",
    "## Calibration resources\n",
)
REQUIRED_CATALOG_MARKERS = (
    "### Fixture input\n",
    "Repository `AGENTS.md`\n",
    "Current implementation\n",
    "Related issue\n",
    "Proposed contract\n",
)
PRIVATE_ANSWER_MARKERS = tuple(ALLOWED_CONCLUSIONS) + (
    "expectedConclusion",
    "requiredSignals",
    "catalogSha256",
)
ALLOWED_IMPORTS = {"__future__", "ast", "hashlib", "json", "pathlib", "re"}
FORBIDDEN_CALLS = {
    "__import__",
    "call",
    "check_call",
    "check_output",
    "compile",
    "eval",
    "exec",
    "fork",
    "popen",
    "run",
    "spawn",
    "system",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def fixture_text_for(catalog_text: str, fixture_id: str) -> str:
    marker = f"## Fixture: {fixture_id}\n\n### Fixture input\n"
    require(marker in catalog_text, f"catalog is missing complete fixture input for {fixture_id}")
    return catalog_text.split(f"## Fixture: {fixture_id}\n", 1)[1].split(
        "\n## Fixture:", 1
    )[0]


def proposed_contract_for(fixture_text: str) -> str:
    prefix = "Proposed contract\n\n```md\n"
    require(prefix in fixture_text, "fixture is missing its proposed contract fence")
    contract = fixture_text.split(prefix, 1)[1].split("\n```\n", 1)[0]
    require(contract.strip(), "proposed contract fence must not be empty")
    return contract


def positive_contract_is_complete(contract: str) -> bool:
    return all(section in contract for section in REQUIRED_CONTRACT_SECTIONS) and (
        "Residual risk" in contract
    )


def package_paths_are_valid(expected_paths: object, actual_paths: list[str]) -> bool:
    return expected_paths == list(EXPECTED_PACKAGE_PATHS) and actual_paths == list(
        EXPECTED_PACKAGE_PATHS
    )


def public_surface_is_private(catalog_text: str) -> bool:
    return all(marker not in catalog_text for marker in PRIVATE_ANSWER_MARKERS)


def catalog_digest_is_valid(catalog_text: str, expected_digest: object) -> bool:
    return isinstance(expected_digest, str) and bool(
        re.fullmatch(r"[0-9a-f]{64}", expected_digest)
    ) and hashlib.sha256(catalog_text.encode("utf-8")).hexdigest() == expected_digest


def main() -> None:
    skill_text = SKILL_PATH.read_text(encoding="utf-8")
    catalog_text = CATALOG_PATH.read_text(encoding="utf-8")
    expected = json.loads(EXPECTED_PATH.read_text(encoding="utf-8"))

    require("TODO" not in skill_text, "SKILL.md still contains scaffold TODO text")
    for phrase in REQUIRED_SKILL_PHRASES:
        require(phrase in skill_text, f"SKILL.md is missing required phrase: {phrase}")
    for marker in REQUIRED_SKILL_MARKERS:
        require(marker in skill_text, f"SKILL.md is missing canonical marker: {marker!r}")
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
            require(imported <= ALLOWED_IMPORTS, "fixture validator imports an unapproved module")
        if isinstance(node, ast.ImportFrom):
            module = (node.module or "").split(".", 1)[0]
            require(module in ALLOWED_IMPORTS, "fixture validator imports an unapproved module")
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            require(
                node.func.id not in FORBIDDEN_CALLS,
                "fixture validator invokes a forbidden process or dynamic-execution call",
            )

    fixtures = expected.get("fixtures")
    require(
        set(expected) == {"version", "packagePaths", "catalogSha256", "fixtures"},
        "expected-results.json schema has unexpected or missing root keys",
    )
    require(expected.get("version") == 1, "expected-results.json must use version 1")
    require(isinstance(fixtures, list), "expected-results.json must contain a fixtures array")
    require(len(fixtures) == len(EXPECTED_CONCLUSIONS), "fixture result count does not match frozen corpus")

    actual_package_paths = sorted(
        path.relative_to(SKILL_ROOT).as_posix()
        for path in SKILL_ROOT.rglob("*")
        if path.is_file()
    )
    require(
        package_paths_are_valid(expected.get("packagePaths"), actual_package_paths),
        "issue-contract-writer package paths differ from the frozen five-file set",
    )
    require(
        public_surface_is_private(catalog_text),
        "fixture catalog leaks private expected answers or validator schema keys",
    )
    require(
        catalog_digest_is_valid(catalog_text, expected.get("catalogSha256")),
        "fixture catalog digest does not match the private expected-results schema",
    )

    expected_ids = list(EXPECTED_CONCLUSIONS)
    catalog_ids = re.findall(r"^## Fixture: ([a-z0-9-]+)$", catalog_text, flags=re.MULTILINE)
    require(catalog_ids == expected_ids, "fixture catalog IDs or order differ from frozen corpus")

    seen: set[str] = set()
    for fixture in fixtures:
        require(isinstance(fixture, dict), "each expected fixture result must be an object")
        require(
            set(fixture) == {"id", "kind", "expectedConclusion", "requiredSignals"},
            "each fixture result has an unexpected or missing schema key",
        )
        fixture_id = fixture["id"]
        require(fixture_id in EXPECTED_CONCLUSIONS, f"unexpected fixture id: {fixture_id}")
        require(fixture_id not in seen, f"duplicate fixture id: {fixture_id}")
        seen.add(fixture_id)
        require(fixture["kind"] == EXPECTED_KINDS[fixture_id], f"wrong fixture kind for {fixture_id}")
        require(
            fixture["expectedConclusion"] in ALLOWED_CONCLUSIONS,
            f"invalid conclusion for {fixture_id}",
        )
        require(
            fixture["expectedConclusion"] == EXPECTED_CONCLUSIONS[fixture_id],
            f"wrong expected conclusion for {fixture_id}",
        )
        fixture_text = fixture_text_for(catalog_text, fixture_id)
        proposed_contract = proposed_contract_for(fixture_text)
        signals = fixture["requiredSignals"]
        require(isinstance(signals, list) and signals, f"{fixture_id} needs required signals")
        require(
            all(isinstance(signal, str) and signal.strip() for signal in signals),
            f"{fixture_id} required signals must be non-empty strings",
        )
        for signal in signals:
            require(signal in proposed_contract, f"{fixture_id} is missing frozen contract signal: {signal}")
        if fixture_id in POSITIVE_FIXTURES:
            require(
                positive_contract_is_complete(proposed_contract),
                f"{fixture_id} positive fixture is missing a contract section or residual risk",
            )

    require(seen == set(EXPECTED_CONCLUSIONS), "fixture IDs do not match frozen corpus")
    require(
        sum(fixture["kind"] == "positive" for fixture in fixtures) == len(POSITIVE_FIXTURES),
        "frozen corpus positive/negative partition changed",
    )
    require(
        sum(fixture["kind"] == "negative" for fixture in fixtures)
        == len(EXPECTED_CONCLUSIONS) - len(POSITIVE_FIXTURES),
        "frozen corpus positive/negative partition changed",
    )

    boundary_text = fixture_text_for(catalog_text, "fixture-boundary")
    moved_section = boundary_text.replace(
        "\n## Stopping conditions\n",
        "\n```\n\n## Stopping conditions\n",
        1,
    )
    require(
        not positive_contract_is_complete(proposed_contract_for(moved_section)),
        "fixture validator mutation check missed a section moved outside the contract fence",
    )
    boundary_contract = proposed_contract_for(boundary_text)
    missing_section = boundary_contract.replace("## Owner decisions\n", "", 1)
    require(
        not positive_contract_is_complete(missing_section),
        "fixture validator mutation check missed a required section removed from the contract",
    )
    drifted_paths = [
        "other-skill/" + path if path == "SKILL.md" else path
        for path in EXPECTED_PACKAGE_PATHS
    ]
    require(
        not package_paths_are_valid(drifted_paths, actual_package_paths),
        "fixture validator mutation check missed package-path drift",
    )
    require(
        not public_surface_is_private(catalog_text + "\nReady to publish\n"),
        "fixture validator mutation check missed public/private answer leakage",
    )
    require(
        not catalog_digest_is_valid(catalog_text + "\n", expected["catalogSha256"]),
        "fixture validator mutation check missed fixture-catalog digest drift",
    )

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
