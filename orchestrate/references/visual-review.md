# Visual Review

The owner approves what people will see by looking at it. Share for review at two points:

- **Spec approval:** mocks of each new screen or state, before the build starts.
- **First look:** screenshots of the built UI, before its pull request merges, for any new visible behaviour.

## Share for Review

- One page per state: empty, loading, filled, error, and each role that sees something different.
- Set light and dark colours explicitly on each page, and show both.
- Show each state at desktop width and at phone width.
- Share privately, with the owner only, unless they ask for more.
- Read the owner's comments on what you shared, answer each one in its thread, and turn each requested change into work or a register entry.
- Cite an approval by its date, what was approved, and its issue or pull request, never by the share's link, which may be deleted: "Approved on YYYY-MM-DD: the owner approved the screens from first-look screenshots (#123)."
- Clean up old shares once their approval is recorded.

Without an integration below, share through what the host offers, such as an artifact or a page in the preview browser, or attach screenshots to the pull request.

## Glass Page (optional integration)

When the session has Glass Page's tools, share through it:

- Publish each mock set or first look as a private Pane in the owner's personal Workspace, one Page per state.
- Read the owner's comment threads on those Panes with the thread tools, and reply to each in its thread.
- Publish a decision map from a `wayfinder` map with the `wayfinder-pane` skill.
- Clean up old Panes by giving the owner the cleanup link from `propose_pane_cleanup`, once their approvals are recorded. Only the owner deletes.

Call Glass Page's `get_instructions` before the first publish in a session.
