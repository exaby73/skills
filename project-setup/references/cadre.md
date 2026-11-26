# Piece: Cadre

Every change goes through Cadre: a track for a feature or a bug, quick for one bounded change, and Wisp for exploration that changes nothing. Cadre owns `.cadre/` and its own onboarding, so this run never writes there.

## Write

- **The route:** the AGENTS.md section "Deliver through Cadre" from [templates/AGENTS.md](../templates/AGENTS.md).
- **The decision:** the register entry "Deliver work through Cadre".
- **The tracker link:** the Cadre paragraph in [templates/docs/agents/issue-tracker.md](../templates/docs/agents/issue-tracker.md), when `tracker` is on.

## Hand Off to Cadre

Name the next step in the report, by what `detect.sh` reports:

| `cadre_project` | Next step |
| --- | --- |
| `missing` | Run `cadre:create`; it classifies the repository as greenfield or brownfield itself. When it drafts `.cadre/guidelines.md`, give it [the delivery lessons](../templates/cadre-guidelines-delivering.md) as that file's "Delivering through Cadre" section, and point its other sections at the repository's docs rather than restating them. |
| `partial` | Run `cadre:create`, which resumes an interrupted setup. |
| `initialized` | When `.cadre/guidelines.md` lacks the delivery lessons, propose them through `cadre:refresh`. |

When the session has no Cadre, keep this piece off, and name Cadre in the report as something the owner can add later by running this skill again.

## Done

`AGENTS.md` routes to Cadre, the register records the decision, and the report names the Cadre command to run next.
