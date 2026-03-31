# GitHub PR Review API Reference

## Single-call Review + Inline Comments

Endpoint:

```bash
POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews
```

Payload shape:

```json
{
  "commit_id": "<HEAD_SHA>",
  "event": "REQUEST_CHANGES",
  "body": "Markdown summary",
  "comments": [
    {
      "path": "path/in/repo.ts",
      "line": 42,
      "side": "RIGHT",
      "body": "Markdown inline comment"
    }
  ]
}
```

## Useful Endpoints

- Get review:
  - `GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews/{review_id}`
- List inline comments:
  - `GET /repos/{owner}/{repo}/pulls/{pull_number}/comments`
- Delete inline comment:
  - `DELETE /repos/{owner}/{repo}/pulls/comments/{comment_id}`
- Patch inline comment body:
  - `PATCH /repos/{owner}/{repo}/pulls/comments/{comment_id}`

## Review Body Markdown Update

REST PATCH for submitted review bodies is not consistently available. Use GraphQL mutation:

```graphql
mutation($id: ID!, $body: String!) {
  updatePullRequestReview(input: { pullRequestReviewId: $id, body: $body }) {
    pullRequestReview { id body url }
  }
}
```

`$id` is the review node id (for example: `PRR_...`).

## Common Failure Modes

- `Not Found (404)`:
  - wrong repo slug
  - wrong endpoint (`/pulls/comments/...` vs `/pulls/{pr}/comments`)
  - trying unsupported REST patch for a submitted review body
- Inline comment rejected:
  - `path` not in PR diff
  - `line` not valid on selected side
  - stale `commit_id`
- Network blocked in sandbox:
  - rerun with elevated permissions for `gh api`
