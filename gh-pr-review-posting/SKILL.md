---
name: gh-pr-review-posting
description: Post GitHub pull request reviews through `gh api`, with emphasis on a single API call that submits `REQUEST_CHANGES` plus inline comments in one payload. Use when asked to post review findings to a PR, batch inline comments, write payload JSON to `/tmp`, replace accidentally posted standalone inline comments, or convert review/comment bodies to Markdown formatting.
---

# GH PR Review Posting

Follow this workflow to post PR review feedback reliably.

## Quick Start

1. Collect PR context (`repo`, `pr_number`, `head_sha`).
2. Write inline comment specs as a JSON array in `/tmp`.
3. Build one review payload JSON (`event`, `body`, `comments`).
4. Submit exactly one `POST /pulls/{pr}/reviews` call.
5. Verify review state and attached inline comments.

Use [references/github-review-api.md](references/github-review-api.md) for endpoint details and troubleshooting.

## Workflow

### 1) Resolve PR Context

Get the PR head commit SHA used for inline comment anchoring:

```bash
gh pr view <PR_NUMBER> --json number,headRefOid,baseRefName,headRefName,url
```

Capture:
- `headRefOid` -> `commit_id` in review payload
- repo slug -> `owner/repo`
- PR number

### 2) Prepare Inline Comments JSON

Create `/tmp/<name>-inline-comments.json` with this shape:

```json
[
  {
    "path": "services/backend/api/src/payments/payments.controller.ts",
    "line": 99,
    "side": "RIGHT",
    "body": "Markdown comment body"
  }
]
```

Rules:
- `path` must match a file in the PR diff.
- `line` is the line number on the selected side of the diff.
- Use `RIGHT` for new lines on the PR head.

### 3) Build One Review Payload

Build one payload containing `REQUEST_CHANGES` and all inline comments:

```bash
<skill-dir>/scripts/build_review_payload.sh \
  --commit-id <HEAD_SHA> \
  --event REQUEST_CHANGES \
  --body-file /tmp/review-body.md \
  --comments-file /tmp/inline-comments.json \
  --output /tmp/review-payload.json
```

### 4) Post Single Review API Call

```bash
<skill-dir>/scripts/post_review.sh \
  --repo <OWNER/REPO> \
  --pr <PR_NUMBER> \
  --input /tmp/review-payload.json
```

This is the preferred pattern when the user asks for one API call that includes both top-level review text and inline comments.

### 5) Verify

```bash
gh api /repos/<OWNER/REPO>/pulls/<PR_NUMBER>/reviews/<REVIEW_ID>
gh api /repos/<OWNER/REPO>/pulls/<PR_NUMBER>/comments --paginate
```

Confirm:
- review state is `CHANGES_REQUESTED` when requested
- expected inline comments are attached to that review id

## Fixups

### Replace Standalone Inline Comments

If inline comments were posted separately by mistake, delete them and repost one consolidated review:

```bash
<skill-dir>/scripts/delete_inline_comments.sh \
  --repo <OWNER/REPO> \
  --ids-file /tmp/comment-ids.txt
```

Then run steps 3-4 again.

### Convert Existing Review To Markdown

If content was posted as plain text, patch the review body via GraphQL:

```bash
<skill-dir>/scripts/update_review_body_markdown.sh \
  --review-node-id <REVIEW_NODE_ID> \
  --body-file /tmp/review-body.md
```

Inline comment bodies can be patched with REST:

```bash
<skill-dir>/scripts/update_inline_comment_bodies.sh \
  --repo <OWNER/REPO> \
  --input /tmp/inline-comment-updates.json
```

## Operational Notes

- Prefer Markdown in both top-level review body and inline comments.
- Use `/tmp` payload files so users can inspect inputs before posting.
- If network is sandbox-blocked, run `gh api` with elevated permissions.
- Keep all review-comment posting deterministic and idempotent where possible.

## Comment Writing Guidelines

Write comments for humans first. Prioritize clarity, concrete impact, and an actionable fix.

### Style Rules

- Start with the problem in plain language.
- Explain why it matters (bug risk, regression, maintainability, UX impact, etc.).
- Suggest a clear next step or fix.
- Keep wording direct and respectful; avoid blamey tone.
- Include technical depth only as needed for correctness.
- Avoid unnecessary jargon unless the user explicitly asks for deep technical detail.

### Writing Approach

- Do not force a fixed template in every comment.
- Write naturally, but make sure each comment still includes:
  - what is wrong
  - why it matters
  - what to change next
- Keep comments short when the issue is simple; expand only when context is needed.
- Prefer practical wording over abstract labels or formal sections.

### Good vs Bad Examples

Good:

```md
This check treats `0` as missing, so valid amounts can be rejected. Can we switch this to an explicit `null`/`undefined` check so `0` remains valid?
```

Bad:

```md
Falsy bug. Fix this.
```

Good:

```md
The handler returns before the DB write finishes, so the API may report success even if persistence fails. Please `await` the write and return after completion.
```

Bad:

```md
Race condition maybe? This flow feels wrong.
```

Good:

```md
This logic is duplicated in three places. That makes future behavior changes easy to miss in one path. Extracting a shared helper would keep the behavior consistent.
```

Bad:

```md
Please refactor. Not clean.
```
