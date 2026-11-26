# Piece: Notices

A product with outside users tells them before a release changes what they can do, what they pay, or what data is kept. The owner sends each notice; the agent that makes the change spots that one is needed, tells the owner, and drafts it.

## Recommend

Recommend on when `notice_signals` names a privacy, terms, pricing, or legal page, or the owner says the product has outside users. Recommend off for internal tools, libraries, and anything with no terms or privacy policy.

## Write

1. [notices.md](../templates/docs/agents/notices.md) into `docs/agents/`. Fill `<<NOTICE_CHANNEL>>` with how notices go out, such as an email to every account from an admin screen. When the repository has none yet, write "an email the owner sends to every account" and put building a sending tool in the report as a follow-up.
2. The AGENTS.md section "Notices", and the register entry "Prompt the owner to send a notice".
3. When `trains` is on too, the train's pull request carries every notice line, as [merge-trains.md](../templates/docs/agents/merge-trains.md) says.

## Done

The doc is written and routed, and the register holds the decision.
