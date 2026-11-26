# Piece: Cadre

Every change goes through Cadre: a track for a feature or a bug, quick for one bounded change, and Wisp for exploration that changes nothing. Cadre owns `.cadre/` and its own onboarding: this run writes the routes to it, then runs `cadre:create`, which writes `.cadre/`.

## Write

- **The route:** the AGENTS.md section "Deliver through Cadre" from [templates/AGENTS.md](../templates/AGENTS.md).
- **The decision:** the register entry "Deliver work through Cadre".
- **The tracker link:** this paragraph, added to `docs/agents/issue-tracker.md` after its first paragraph, when `tracker` is on:

  ```md
  A Cadre track keeps its spec and plan in `.cadre/tracks/` and names the issue it delivers ([decision](../product-decisions.md#deliver-work-through-cadre)).
  ```

## Run Cadre

After this run's commit, by what `detect.sh` reports:

| `cadre_project` | Run |
| --- | --- |
| `missing` | `cadre:create`. |
| `partial` | `cadre:create`, which resumes the interrupted setup. |
| `initialized` | Nothing now. When `.cadre/guidelines.md` lacks the delivery lessons, offer `cadre:refresh` in the report to add them. |

Follow the `cadre:create` skill in full; it owns its own steps, questions, and commit. Bring it what this run already knows, so it asks less:

- the greenfield or brownfield call, with `detect.sh`'s evidence;
- the stack, the runner, and the check commands from the plan;
- for `guidelines.md`, [the delivery lessons](../templates/cadre-guidelines-delivering.md) as its "Delivering through Cadre" section, and pointers to the docs this run wrote (`AGENTS.md`, `docs/README.md`, `docs/development/writing-tests.md`, `docs/agents/review.md`) in its other sections instead of restating them.

When the owner declines Cadre's approval, the route and the register entry stay: report that Cadre isn't set up yet, and that running `cadre:create` again finishes it.

When the session has no Cadre, keep this piece off, and name Cadre in the report as something the owner can add later by running this skill again.

## Done

`AGENTS.md` routes to Cadre, the register records the decision, and `detect.sh` reports `cadre_project=initialized` with Cadre's commit on the branch.
