# Piece: Docs Governance

The `docs-governance` skill owns this piece, and its BOOTSTRAP.md is the procedure. Read both, from the installed skill when the repository has it, or from [hexsis-llc/skills](https://github.com/hexsis-llc/skills/tree/main/skills/docs-governance) when it doesn't yet. This file says only how a project-setup run folds BOOTSTRAP into its one plan.

## Fold BOOTSTRAP Into the Plan

| BOOTSTRAP step | In project-setup |
| --- | --- |
| 1. Explore | Step 1, Detect. `detect.sh` reports the markers; read the files it names. |
| 2. Settle the shape | Step 3, the plan. Put each of BOOTSTRAP's six questions in the plan as a recommendation, instead of asking them one at a time. |
| 3. Canonical `AGENTS.md` | The plan's row for `CLAUDE.md`, from BOOTSTRAP's table for what `claude_md` reports. |
| 4. Create the homes | Step 5, Write. Create only the folders the repository has content for now, plus `docs/adr/` with a `README.md` whose table lists no ADRs yet. |
| 5. Install the skill and route agents | The `skills` piece installs `docs-governance`; [templates/AGENTS.md](../templates/AGENTS.md) carries the routes. |
| 6. From the record-based model | Only when the repository has `CHG-*` or `DEC-*` records. Put the move in the plan as its own item for the owner to approve or defer. |
| 7. Check the setup | Step 6, Verify. |

## What Project Setup Adds

- **`AGENTS.md`:** build it from [templates/AGENTS.md](../templates/AGENTS.md). An existing `AGENTS.md` keeps its title and text; add the template's sections it lacks, in the template's order, with its own sections after "Who decides".
- **The register:** a new `docs/product-decisions.md` starts from [templates/docs/product-decisions.md](../templates/docs/product-decisions.md). Every piece the owner turns on adds its entry there, dated the day they approve the plan.
- **The index:** `docs/README.md` lists every doc this run writes, under its folder, with when to read it. Take each line's wording from the doc's first paragraph.
- **The glossary:** a new `GLOSSARY.md` holds a title and a one-line summary of the project, with no terms yet. Terms arrive through `grill-with-docs` and `domain-modeling`.
- **Domain docs:** [templates/docs/agents/domain.md](../templates/docs/agents/domain.md) into `docs/agents/`, which tells the engineering skills to read the glossary and ADRs before exploring.

## Done

`detect.sh` reports `agents_md=file`, `claude_md=symlink-to-agents` (or `import-agents`), `docs_index`, `glossary`, `decision_register`, and `adr_dir` present, `agent_docs` including domain, and `scratch_ignored=yes`.
