---
description: "Apply the fixes the user approved on a review sheet, re-verify each one, and update the sheet"
---

Apply the fixes the user approved on a `/review-round` sheet: the one named in `$ARGUMENTS`, else the newest `.claude/context/review-*.md`. Only what was approved, and never a push or a merge.

## What counts as approved

- an item the user answered with `fix`, `ok` or an instruction, in chat or annotated in the sheet; their words beat the sheet's default;
- every `fix` item, when they accepted the defaults as a whole ("ok", "go with the defaults");
- the clear wins on a sheet made with `--clear-wins`, which that flag approved.

An `ask` nobody answered, a `defer`, and any item on a `--candidates` sheet they did not pick stay as they are. A timeout, an away notice, or a reply asking to wait or explain leaves an item unanswered.

## Steps

1. **Record the answers** that settle a question (an `ask` they answered, a default they overruled): `bash .claude/bin/decisions.sh add --by you --kind decision --question '<the item>' --decision '<what they chose>' --words '<their words, verbatim>'`, adding `--date YYYY-MM-DD` when they said it on another day. Single-quote every value, writing an apostrophe as `'\''`. If the helper is missing or fails, say so and keep their words quoted in the sheet.
2. **Check the head.** The sheet names the commit it reviewed. If the branch has moved since (`git rev-parse <branch>`), re-check each approved item against the new code before touching it.
3. **Fix in parallel, by owned files,** on the branch whose head was reviewed, in its own worktree if it is not checked out. When that head is the default branch itself (a `since <date>` audit, or a range ending there), fix on a new branch from it, named by the kit's branch convention. Group the approved items by the files they touch: groups that share no file run at once, fanned out the way [/implement](implement.md) does (a worktree each from the sheet's head, one integrator, WIP commits, no merges); a single group is fixed in this session.
4. **Re-check each fix** with the evidence that proved the finding: the reproduction must stop reproducing, and the checks that cover the touched files must pass, where zero tests or SKIP counts as a failure. A finding without a reproduction gets a test that would have caught it, or a re-check by a fresh agent with its lens.
5. **Stop on an item** when its re-check fails after two different fixes. It goes back on the sheet as `ask`, with both attempts and their results.
6. **Commit** per item or per group, the message naming the sheet items it closes. A problem found while fixing becomes a new numbered item on the sheet, not an unasked extra change.
7. **Update the sheet:** each item `fixed` (commit, command and result), `failed` (why) or `skipped` (why).

## Output

Per item: its number, status, commit, and the re-check command with its result. Then the head before and after the wave: the fixes moved it, so the sheet no longer covers the head. Run `/review-round <old head>..<new head>` before `/ship`, which accepts only a review of the commit it merges.
