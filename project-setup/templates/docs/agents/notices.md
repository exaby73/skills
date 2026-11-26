# Prompt the Owner to Send a Notice

Before a release changes what people can do, what they pay, or what data <<PROJECT_NAME>> keeps, everyone affected gets a notice, sent through <<NOTICE_CHANNEL>>. The owner sends it, and only once they know it's needed. So the agent that makes the change tells them and drafts it ([decision](../product-decisions.md#prompt-the-owner-to-send-a-notice)).

## When a change needs one

A change needs a notice when it changes, for anyone:

- the privacy policy or the terms, beyond wording that keeps their meaning;
- or anything they describe, such as what data is kept, for how long, and who sees it, plans, prices, limits, deleting accounts, and the services that process data, so that the pages no longer match what <<PROJECT_NAME>> does.

A change to either page that affects nobody, such as a typo fixed, needs none, but only the owner decides that. Ask them, and once they confirm it, write a line that starts `No notice needed:` and gives the reason. When you can't tell whether a change needs one, ask the owner too.

## What to do

1. **Change the pages to match,** in the same pull request, when your change makes them out of date.
2. **Set the effective date** of each page you changed to the day the release that carries it is published, so the page never says a change applied before its notice went out.
3. **Draft the notice** in your pull request's description, under a heading `Notice draft`: which page changed, a subject on one line, and a message that says what changes, in plain words, the date it applies from, which is the release day, and where to write about it.
4. **Add the notice line** to the description, starting `Before publishing:` and saying the owner sends the notice, such as "Before publishing: the owner sends the notice drafted below, and confirms it was sent."
5. **Tell the owner,** in your report, that a notice needs sending before the release, and point them at the draft.

The work is done when the pages match, their effective dates are the release's, the description has the draft and the line, and your report tells the owner.

## At release

The release waits until the owner confirms each notice was sent. Before it goes out, check that three dates are one day: each changed page's effective date, the date the notice says the change applies from, and the day the release is published. If the release slips, correct the pages' dates and the notice's date together.
