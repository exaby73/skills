# Calibration fixture catalog

Use these neutral, deterministic fixture inputs to forward-test review calibration. Give an independent reviewer only one `### Fixture input` section and the `ui-ux-reviewer` skill. Keep expected outcomes in `expected-results.json`; do not pass that file or another fixture to the reviewer.

## Fixture: material-ui-defects

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/interface-contract.md` before reviewing interface changes. Primary actions must be discoverable from the main content, keyboard focus must remain visible, and shared layout and control contracts apply to every route.
```

Linked `docs/interface-contract.md`

```md
# Interface contract

- A route's primary action is visible and named in its main content without requiring a generic overflow menu.
- Interactive text and controls meet the repository's contrast requirements, and every keyboard-focusable control has a visible focus indicator.
- Content in the main panel aligns to the shared content edge and uses the spacing scale.
- Primary controls use the `action-primary` component, the `color-action-primary` token, and a minimum target height of 44px.
```

Change contract

The route `/work-items/42` lets an operator finalize one work item. Finalize is the primary action and must remain discoverable, operable, and visually consistent in the ready state.

Changed paths

- `routes/work-items/42.html`
- `styles/work-items.css`

Source and rendered artifact

```html
<!-- routes/work-items/42.html -->
<main class="content">
  <h1>Work item 42</h1>
  <p class="summary">Ready for finalization.</p>
  <button class="icon-button" aria-label="More actions">•••</button>
  <div class="menu" hidden>
    <button class="finish" type="button">Finalize</button>
    <button type="button">Archive</button>
  </div>
</main>
```

```css
/* styles/work-items.css */
:root {
  --content-edge: 32px;
  --color-action-primary: #1769aa;
}

.content { padding: var(--content-edge); }
.summary { margin-left: 24px; padding: 12px; }
.finish {
  min-height: 32px;
  background: #888;
  color: #fff;
}
button:focus { outline: none; }
```

The page is runnable. Activating `More actions` reveals the menu, and activating `Finalize` invokes the finalization action.

Rendered observations

- At `/work-items/42`, viewport `390x844`, ready state, the main content exposes only the generic `More actions` icon. The `Finalize` name and action are absent from the visible content and accessibility tree until the menu is opened.
- At the same route and viewport with the menu open, the `Finalize` button renders gray `#888` text on white with computed contrast `3.54:1`. Tabbing to it moves keyboard focus but produces no visible indicator because the focus rule removes the outline.
- At viewport `1440x900`, the summary content begins `24px` from the panel edge while the heading begins `32px` from that edge; the related content therefore uses two alignment edges. The finalization control is `32px` tall.
- The finalization control uses the local `.finish` class, a hard-coded background, and a `32px` target instead of the required `action-primary` component, `color-action-primary` token, and `44px` minimum.

## Fixture: preference-only-ui

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/interface-guidance.md` before reviewing interface changes. The guidance permits either a compact top navigation or a side navigation when hierarchy is clear. Labeled controls, the shared spacing scale, keyboard access, and responsive reachability are required; equivalent icon and card arrangements are acceptable.
```

Linked `docs/interface-guidance.md`

```md
# Interface guidance

- Keep the page title and primary next action visible at every viewport.
- Use the existing control and card patterns, but allow either a leading icon or a trailing icon when the text label remains present.
- Use spacing values from 8px, 16px, and 24px; do not require one particular gap when the hierarchy remains clear.
- A small-screen navigation disclosure may replace the wide-screen side navigation if it is labeled and keyboard reachable.
```

Change contract

The route `/collections` presents collection summaries and provides a primary `Add collection` action.

Changed paths

- `routes/collections.html`
- `styles/collections.css`

Source and rendered artifact

```html
<header class="topbar">
  <button class="nav-toggle" aria-expanded="false" aria-controls="collection-nav">Collections</button>
  <h1>Collections</h1>
  <button class="action-primary" type="button"><span aria-hidden="true">+</span> Add collection</button>
</header>
<nav id="collection-nav" aria-label="Collection sections" hidden>Overview · Archived</nav>
<section class="cards" aria-label="Collection summaries">
  <article class="card"><h2>Recent</h2><p>12 items</p></article>
  <article class="card"><h2>Saved</h2><p>8 items</p></article>
</section>
```

Rendered observations

- At viewport `390x844`, the title and labeled `Add collection` action are visible in the first viewport. The navigation disclosure is labeled, has an `aria-expanded` state, and opens without horizontal overflow. Cards form one column with 16px gaps.
- At viewport `834x1112`, cards form two columns and the action remains reachable without overlap. At `1440x900`, the same top navigation remains clear and the card grid uses the shared 24px outer spacing.
- The plus icon is paired with text, the action uses the shared primary control, and keyboard focus is visible on the toggle, action, and links.
- The compact top navigation is an allowed alternative to side navigation. Text, hierarchy, spacing scale, and responsive behavior remain consistent with the linked guidance.

## Fixture: clean-ui

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/accessibility-contract.md` before reviewing interface changes. Every changed journey must expose a named next action, use semantic controls, preserve visible focus, announce asynchronous state changes, and remain usable at narrow and wide viewports.
```

Linked `docs/accessibility-contract.md`

```md
# Accessibility contract

- Use headings, landmarks, buttons, links, labels, and status regions for their intended meanings.
- Keep focus visible and keep the keyboard path in the same order as the visual path.
- Provide loading, empty, success, error, and permission feedback when the route can reach those states.
- Preserve the shared component and token rules; text must wrap or be intentionally truncated without hiding actions.
```

Change contract

The route `/messages` adds a message list with a `New message` action and a send flow that can report progress, success, failure, or permission denial.

Changed paths

- `routes/messages.html`
- `styles/messages.css`
- `components/message-list.html`

Source and rendered artifact

```html
<nav aria-label="Primary"><a href="/messages" aria-current="page">Messages</a></nav>
<main>
  <h1>Messages</h1>
  <button class="action-primary" type="button">New message</button>
  <section aria-label="Message list">
    <ul><li><a href="/messages/1">Follow-up</a></li></ul>
  </section>
  <p role="status" aria-live="polite" id="send-status"></p>
</main>
```

Rendered observations

- At viewport `360x800`, the heading, `New message` button, and message links are visible and reachable in visual and keyboard order. At `768x1024`, the list uses two columns without clipping. At `1440x900`, the list and action use the shared content edge and spacing tokens.
- The ready state exposes a named next action and semantic links. The empty state replaces the list with `No messages yet` and the same `New message` action. The loading state marks the list container busy and exposes a status message.
- The send journey shows a disabled submit control while pending, announces success in the status region, and shows an error with a reachable `Retry` button when sending fails. A permission state explains why sending is unavailable and leaves navigation usable.
- There is no destructive delete, stale-data, or concurrent-edit path in this change, so those states are not applicable. Text wraps at narrow widths, controls retain visible focus, and no color-only meaning or horizontal page overflow is present.

## Fixture: evidence-blocked-ui

### Fixture input

Repository `AGENTS.md`

```md
# Repository policy

Read `docs/interaction-contract.md` and the route-specific acceptance notes before reviewing interface changes. The profile journey must keep the save action discoverable, preserve keyboard access, and show the result of a save attempt.
```

Linked `docs/interaction-contract.md`

```md
# Interaction contract

Profile edits require a visible save action, a clear pending state, a success or error result, and a usable keyboard path at mobile, tablet, and desktop widths.
```

Change contract

The route `/profile` changes the save action for profile edits.

Changed paths

- `routes/profile.html`
- `styles/profile.css`

Source context

```diff
 <form action="/profile" method="post">
   <label for="display-name">Display name</label>
   <input id="display-name" name="displayName">
-  <button type="submit">Save</button>
+  <button class="save-profile" type="submit">Save changes</button>
 </form>
```

Evidence availability

- The source diff and linked guidance are available.
- No runnable route, browser or emulator session, rendered DOM, accessibility tree, viewport capture, or interaction trace is supplied.
- The attempted preview cannot start because the runtime and fixture data are unavailable. No screenshot or equivalent rendered evidence was supplied.
