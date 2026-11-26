# Review a Pull Request

Review a pull request when you're asked to, and before you merge one. A separate agent reviews: never the one that wrote the change. A review has two passes, run from the pull request's branch after `git fetch`.

1. **Standards and spec:** check the change against `AGENTS.md`, the docs it routes to, and the spec. The spec is the issue the pull request closes; when it closes none, the spec is the pull request's description.
2. **Logic:** hunt adversarially for bugs: wrong results, unhandled edge cases and errors, races, and holes in access control, such as someone reaching data they have no access to. Trace each finding to a concrete input that breaks it.

A review reads and reasons about the code. Run a test only to confirm or rule out a specific finding, and then only that test or file.

When you were asked only to review, report the findings and stop there.

## Findings

Grade each finding **High**, **Medium**, or **Low**, and give each one:

- the file and line;
- the failure scenario: the input or state, and the wrong result it causes;
- the fix.

High is a security or access-control hole, lost or leaked data, a wrong charge, or a broken main path. Medium is a real bug off the main path. Low is a small defect or a clear improvement with no wrong result yet.

## Rounds

- **The first round** reviews the whole pull request, against its base, `origin/<base>`.
- **Each later round** reviews only the fix commits, against the head the last round reviewed. It checks that each fix works and breaks nothing near it. A finding outside those commits counts only when it's High.
- **A pull request that touches sign-in, access control, money, or deleting data** gets one more full round against its base before it merges, after the rounds above come back clean.

Fix every High and Medium, or reply in the pull request with why it stays, and review the fix in the next round. The review is done when a round finds no High or Medium.

**Lows** are fixed before merge, in one push, with no further round: whoever merges diffs that push against the reviewed head and checks it changes only what the Lows named.

When the third round still finds a High or Medium, stop and bring it to the owner, with a proposal: split the pull request, or merge it with an issue filed for what's left.

## Merge

The head you merge is the head the last review covered, plus only the Low fixes checked above. Merge with `gh pr merge <n> --merge --match-head-commit <sha>`, naming that head, so a push after the review refuses the merge. Never merge with `--admin`, and never push to the default branch.

## Delegated Review

When another agent delegates a review to you, its brief adds only what's particular to that pull request. These hold for every one:

1. **Run both passes yourself, one after the other,** starting no subagents.
2. **Post one review, COMMENT only,** with `gh pr review --comment`, or, to attach inline comments, as one review through `gh api repos/<owner>/<repo>/pulls/<n>/reviews` with `event: COMMENT`. Never approve or request changes: the orchestrator decides. Start the body and each comment with this note, naming your model and the person you review for:

   ```md
   > [!NOTE]
   > 🤖 **<model> responding on behalf of <person>**
   ```

   Then a blank line, then your text. The `leaving-pr-comments` skill, if you have it, writes the same note.
3. **End your report** with `Review <url> of <SHA>: <n> high, <n> medium, <n> low`, then one line per finding: grade, `file:line`, the failure scenario, the fix.
