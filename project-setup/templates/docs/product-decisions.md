<!-- project-setup template. A new register starts with the title and intro; an
existing one keeps its own. Append only the entries whose piece the owner turned
on and whose heading the register lacks, dated <<TODAY>>, the day the owner
approved the setup plan. Delete this comment. -->
# Product Decisions

The owner's decisions about <<PROJECT_NAME>>, one entry each. A changed decision gets a dated note, not a rewrite. Questions the owner has not decided yet are under [Open](#open).

## Let the owner decide the tech stack and agents own the engineering

Accepted on <<TODAY>>. <<OWNER>> chooses languages, frameworks, hosting, and third-party services. Agents make every engineering decision inside that stack, including structure, libraries, interfaces, and tests, and record the ones that are hard to reverse as ADRs in `docs/adr/`.

<!-- piece: skills -->
## Keep agent skills up to date in every pull request

Accepted on <<TODAY>>. `skills-lock.json` lists the agent skills this repository uses, and `<<SETUP_COMMAND>>` installs the latest version of each. When an update changes `skills-lock.json`, the agent commits it in the pull request it is working on, so skills never fall behind. [manage-agent-skills.md](development/manage-agent-skills.md) says how.

<!-- piece: cadre -->
## Deliver work through Cadre

Accepted on <<TODAY>>. Agents deliver every change through Cadre's workflow in `.cadre/`, which `.cadre/workflow.md` defines: a track, with its spec, plan, phases, and review, for a feature or a bug; quick for one bounded change; and Wisp for exploration that changes nothing. GitHub Issues stay where work is asked for, triaged, and closed: a track names the issue it delivers, and the pull request that delivers it closes it. Cadre's approvals add to the repository's own rules and replace none of them. Only Cadre's commands change `.cadre/`.

<!-- piece: review -->
## Review every pull request with a separate agent

Accepted on <<TODAY>>. A pull request merges only after a separate agent reviews it, in rounds, until a round finds nothing High or Medium, and the head that merges is the head that was reviewed. [review.md](agents/review.md) says how.

<!-- piece: trains -->
## Batch reviewed pull requests in merge trains

Accepted on <<TODAY>>. Reviewed pull requests merge into a merge train, a branch that batches them, and CI runs only on pull requests to `<<DEFAULT_BRANCH>>`: a train's, or a hotfix's. A release follows each train. [merge-trains.md](agents/merge-trains.md) says how.

<!-- piece: notices -->
## Prompt the owner to send a notice

Accepted on <<TODAY>>. Whenever an agent changes the privacy policy, the terms, or anything they describe, so that the change affects what people can do, what they pay, or what data is kept, it tells the owner a notice needs sending before the release, and drafts it. The release waits until the owner confirms it was sent. [notices.md](agents/notices.md) says how.

<!-- piece: approvals -->
## Let the orchestrator approve routine changes

Accepted on <<TODAY>>. The orchestrator, the agent that coordinates delivery for the owner, approves these without asking:

<<ADOPTED_APPROVALS>>

Everything else still goes to the owner: real trade-offs, new scope, money, privacy and data, notices, first looks at new visible behaviour, reversing a decision in this register, and the stack or services.

## Open

None yet.
