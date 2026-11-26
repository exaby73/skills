#!/usr/bin/env python3
"""Validate the orchestrate package: files, links, required rules, and genericity."""

from __future__ import annotations

import re
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parent.parent

EXPECTED_PACKAGE_PATHS = {
    "SKILL.md",
    "agents/openai.yaml",
    "references/briefs.md",
    "references/machine.md",
    "references/merging.md",
    "references/real-services.md",
    "references/secrets.md",
    "references/visual-review.md",
    "scripts/test_package.py",
}
FORBIDDEN = ("ai_share", "Hexsis", "glasspage.ai", "/staff/notices", "SvelteKit", "Cloudflare", "Drizzle", "Polar")
# Glass Page may appear only in its optional-integration section.
GLASS_PAGE_FILES = {"references/visual-review.md", "SKILL.md"}
# Each rule the orchestrator must carry, by the file that holds it.
REQUIRED = {
    "SKILL.md": (
        "The owner decides; the orchestrator delegates.",
        "## Standing approvals",
        "ID-only digest changes",
        "Review remediation within spec",
        "Quick fixes with no visible change",
        "Simple, obvious questions",
        "Let the orchestrator approve routine changes",
        "real trade-offs, new scope, money, privacy and data, notices, first looks at new visible behaviour",
        "recommended option first",
        "Batch questions",
        "Never ask a simple one",
        ".scratch/orchestrator/pending-approvals.md",
        ".scratch/orchestrator-checkpoint-",
        "Plain words, recommendation first",
        "health endpoint",
        "`PR <url>, head <SHA>`",
    ),
    "references/briefs.md": (
        "Goal:",
        "Settled:",
        "Read first:",
        "Process:",
        "Guardrails:",
        "Memory:",
        "Report:",
        "COMMENT-only",
        "High, Medium, or Low, each with its file and line, a failure scenario, and a fix",
        "only the fix commits",
        "sign-in, access control, money, or deleting data",
    ),
    "references/merging.md": (
        "baseRefName",
        "merge-base --is-ancestor",
        "--diff-filter=D",
        "merge-tree --write-tree",
        "migrations and no two ADRs share a number",
        "touches only `.cadre/`",
        "--match-head-commit",
        "Stage named paths only",
        "gh auth setup-git",
        "never to the default branch",
        "without `--admin`",
        "git branch -d",
    ),
    "references/machine.md": (
        "free -m",
        "4 GB",
        "at most 2 workers",
        "One browser per agent",
        "5432",
        "docker rm -f -v <name>",
        "POSTGRES_CONTAINER",
        "Never run `docker system prune`",
    ),
    "references/secrets.md": (
        "Never print the environment",
        "0600",
        "stdin",
        "pbpaste",
        "ask the owner before deleting",
        "shred -u",
    ),
    "references/visual-review.md": (
        "One page per state",
        "light and dark colours explicitly",
        "desktop width and at phone width",
        "## Glass Page (optional integration)",
        "private Pane in the owner's personal Workspace",
        "`wayfinder-pane`",
        "propose_pane_cleanup",
        "never by the share's link",
    ),
    "references/real-services.md": (
        "real test tenant",
        "not on a preview deploy",
        "sign in there once",
        "docs/qualification/",
    ),
}

FENCE = re.compile(r"^(```|~~~).*?^\1", re.S | re.M)
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^#{1,6} +(.+?) *$", re.M)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def prose(text: str) -> str:
    return FENCE.sub("", text)


def slug(heading: str) -> str:
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")


def main() -> None:
    found = {
        str(p.relative_to(SKILL_ROOT))
        for p in SKILL_ROOT.rglob("*")
        if p.is_file() and "__pycache__" not in p.parts
    }
    require(found == EXPECTED_PACKAGE_PATHS, f"package paths differ: {sorted(found ^ EXPECTED_PACKAGE_PATHS)}")

    skill = (SKILL_ROOT / "SKILL.md").read_text()
    match = re.match(r"---\nname: (.+)\ndescription: (.+)\n---\n", skill)
    require(match is not None, "SKILL.md frontmatter must hold name and description")
    require(match.group(1) == "orchestrate", "name must be orchestrate")
    require(len(match.group(2)) <= 1024 and "Use when" in match.group(2), "description must be short and name its triggers")

    for rel in sorted(EXPECTED_PACKAGE_PATHS - {"scripts/test_package.py"}):
        path = SKILL_ROOT / rel
        text = path.read_text()
        for word in FORBIDDEN:
            require(word not in text, f"{rel}: product-specific '{word}'")
        if "Glass Page" in text:
            require(rel in GLASS_PAGE_FILES, f"{rel}: Glass Page belongs only in the optional integration")
        for phrase in REQUIRED.get(rel, ()):
            require(phrase in text, f"{rel} lacks '{phrase}'")
        if rel.endswith(".md"):
            for target in LINK.findall(prose(text)):
                if re.match(r"[a-z]+:", target) or "<" in target:
                    continue
                file_part, _, anchor = target.partition("#")
                resolved = (path.parent / file_part).resolve() if file_part else path
                require(resolved.exists(), f"{rel}: broken link {target}")
                if anchor:
                    headings = {slug(h) for h in HEADING.findall(prose(resolved.read_text()))}
                    require(anchor in headings, f"{rel}: missing anchor {target}")

    glass_in_skill = [l for l in skill.splitlines() if "Glass Page" in l]
    require(all("optional integration" in l for l in glass_in_skill), "SKILL.md must name Glass Page as an optional integration")

    for ref in sorted(p for p in EXPECTED_PACKAGE_PATHS if p.startswith("references/")):
        require(f"]({ref})" in skill, f"SKILL.md does not point at {ref}")

    print(f"orchestrate package valid: {len(EXPECTED_PACKAGE_PATHS)} files")


if __name__ == "__main__":
    main()
