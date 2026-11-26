#!/usr/bin/env python3
"""Validate the project-setup package: files, links, templates, and genericity."""

from __future__ import annotations

import re
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parent.parent
TEMPLATES = SKILL_ROOT / "templates"

EXPECTED_PACKAGE_PATHS = {
    "SKILL.md",
    "agents/openai.yaml",
    "references/agent-skills.md",
    "references/cadre.md",
    "references/conventions.md",
    "references/docs-governance.md",
    "references/merge-trains.md",
    "references/notices.md",
    "scripts/detect.sh",
    "scripts/test-detect.sh",
    "scripts/test_package.py",
    "templates/AGENTS.md",
    "templates/cadre-guidelines-delivering.md",
    "templates/docs/agents/domain.md",
    "templates/docs/agents/issue-tracker.md",
    "templates/docs/agents/merge-trains.md",
    "templates/docs/agents/notices.md",
    "templates/docs/agents/review.md",
    "templates/docs/agents/triage-labels.md",
    "templates/docs/development/manage-agent-skills.md",
    "templates/docs/development/writing-tests.md",
    "templates/docs/product-decisions.md",
    "templates/scripts/install-skills.sh",
}
PIECES = {"docs", "skills", "cadre", "tracker", "testing", "review", "trains", "notices", "approvals"}
PLACEHOLDERS = {
    "PROJECT_NAME",
    "PROJECT_SUMMARY",
    "OWNER",
    "GITHUB_REPO",
    "DEFAULT_BRANCH",
    "SETUP_COMMAND",
    "CHECK_COMMANDS",
    "INSTALL_SCRIPT",
    "SKILLS_VERSION",
    "NOTICE_CHANNEL",
    "TODAY",
    "ADOPTED_APPROVALS",
}
TRIAGE_LABELS = ("needs-triage", "needs-info", "ready-for-agent", "ready-for-human", "wontfix")
# Strings that belong to one product or client, never to a generic setup.
FORBIDDEN = ("ai_share", "Hexsis-LLC", "glasspage.ai", "/staff/notices", "SvelteKit", "Cloudflare", "Drizzle", "Polar")
# Glass Page may appear only where it is named as an optional integration.
GLASS_PAGE_FILES = {"references/agent-skills.md"}
SKILL_SECTIONS = (
    "## Pieces\n",
    "## 1. Detect\n",
    "## 2. Settle the Choices\n",
    "## 3. Show the Plan\n",
    "## 4. Get One Approval\n",
    "## 5. Write\n",
    "## 6. Run Setup and Verify\n",
    "## 7. Commit and Report\n",
)
ROUTED_TEMPLATES = (
    "docs/agents/review.md",
    "docs/agents/merge-trains.md",
    "docs/agents/notices.md",
    "docs/agents/issue-tracker.md",
    "docs/agents/triage-labels.md",
    "docs/agents/domain.md",
    "docs/development/writing-tests.md",
    "docs/development/manage-agent-skills.md",
)

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


def anchors(path: Path) -> set[str]:
    return {slug(h) for h in HEADING.findall(prose(path.read_text()))}


def check_links(path: Path, text: str, root: Path) -> None:
    for target in LINK.findall(prose(text)):
        if re.match(r"[a-z]+:", target) or "<" in target:
            continue
        file_part, _, anchor = target.partition("#")
        resolved = (path.parent / file_part).resolve() if file_part else path
        require(resolved.exists(), f"{path.relative_to(root)}: broken link {target}")
        if anchor and resolved.suffix == ".md":
            require(anchor in anchors(resolved), f"{path.relative_to(root)}: missing anchor {target}")


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
    require(match.group(1) == "project-setup", "name must be project-setup")
    require(len(match.group(2)) <= 1024 and "Use when" in match.group(2), "description must be short and name its triggers")
    for section in SKILL_SECTIONS:
        require(section in skill, f"SKILL.md lacks {section.strip()}")
    for phrase in ("one approval", "idempotent", "nothing to change", "writes nothing into `.cadre/`", "cadre:create"):
        require(phrase in skill, f"SKILL.md lacks '{phrase}'")
    for piece in PIECES:
        require(f"| `{piece}`:" in skill, f"SKILL.md's piece table lacks {piece}")

    for rel in sorted(EXPECTED_PACKAGE_PATHS):
        path = SKILL_ROOT / rel
        text = path.read_text()
        if rel != "scripts/test_package.py":
            for word in FORBIDDEN:
                require(word not in text, f"{rel}: product-specific '{word}'")
        if "Glass Page" in text and rel not in GLASS_PAGE_FILES and rel != "SKILL.md" and rel != "scripts/test_package.py":
            raise SystemExit(f"{rel}: Glass Page belongs only in the optional integration")
        if rel.endswith(".md") and not rel.startswith("templates/"):
            check_links(path, text, SKILL_ROOT)

    glass_lines = [l for l in (SKILL_ROOT / "references/agent-skills.md").read_text().splitlines() if "Glass Page" in l]
    require(all("optional" in l or "Glass Page tools" in l for l in glass_lines), "Glass Page must be named as optional")

    used = set()
    for path in TEMPLATES.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(TEMPLATES)
        text = path.read_text()
        for name in re.findall(r"<<([A-Z_]+)>>", text):
            require(name in PLACEHOLDERS, f"templates/{rel}: unknown placeholder {name}")
            used.add(name)
        for piece in re.findall(r"<!-- piece: ([a-z]+) -->", text):
            require(piece in PIECES, f"templates/{rel}: unknown piece {piece}")
        if path.suffix == ".md":
            # Template links resolve inside the project the templates build.
            check_links(path, text, TEMPLATES)
    require(used == PLACEHOLDERS, f"placeholders never used: {sorted(PLACEHOLDERS - used)}")

    agents = (TEMPLATES / "AGENTS.md").read_text()
    for rel in ROUTED_TEMPLATES:
        require(rel in agents, f"templates/AGENTS.md does not route to {rel}")
    labels = (TEMPLATES / "docs/agents/triage-labels.md").read_text()
    conventions = (SKILL_ROOT / "references/conventions.md").read_text()
    for label in TRIAGE_LABELS:
        require(f"`{label}`" in labels, f"triage-labels.md lacks {label}")
        require(f"gh label create {label} " in conventions, f"conventions.md does not create {label}")

    review = (TEMPLATES / "docs/agents/review.md").read_text()
    for phrase in ("COMMENT only", "file and line", "failure scenario", "only the fix commits", "sign-in, access control, money, or deleting data", "no further round", "--match-head-commit"):
        require(phrase in review, f"review.md lacks '{phrase}'")
    cadre = (TEMPLATES / "cadre-guidelines-delivering.md").read_text()
    for phrase in ("worktreePath", "clean review", "git branch -d", "placeholder hash", "stacked pull request"):
        require(phrase in cadre, f"cadre lessons lack '{phrase}'")

    catalog = (SKILL_ROOT / "references/agent-skills.md").read_text()
    for skill_name in ("docs-governance", "writing-for-agents", "gwt-tester", "code-review", "pair-review", "leaving-pr-comments", "wayfinder", "wayfinder-pane", "impeccable", "research", "prototype", "tdd", "diagnosing-bugs", "grilling", "domain-modeling", "orchestrate"):
        require(f"`{skill_name}`" in catalog, f"catalog lacks {skill_name}")

    print(f"project-setup package valid: {len(EXPECTED_PACKAGE_PATHS)} files")


if __name__ == "__main__":
    main()
