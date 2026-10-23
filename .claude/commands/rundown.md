---
description: "Status rundown for a returning user: decided while away, needs your call, in flight, blocked, next"
---

Bring the user back up to speed from facts gathered now, not from memory. Arguments, if any: `$ARGUMENTS`. They may narrow the scope (a PR, a branch, `since <date>`); `--handoff` also writes the rundown to a file for a teammate or the next session.

## Gather

- **Record:** `bash .claude/bin/decisions.sh export`. What the user has not seen: entries dated since they last spoke (or since the date given) that a panel or an agent decided, and every provisional or proposed entry. If the helper is missing or fails, say the record is unavailable and use the conversation.
- **git:** `git status --short`, `git log --oneline -20`, `git branch -vv` (unpushed work), `git worktree list` (a sibling worktree may be another session's work).
- **gh:** `gh pr list`, `gh pr list --state merged --limit 20`, `gh pr checks <n>` for each open PR in scope, `gh run list --limit 10`. Run each `gh` and network `git` command bare, as the whole Bash call: a pipe, a redirect, `$(...)` or a `cd` prefix keeps it inside the sandbox, where it may fail to authenticate. Skip what does not apply (no remote, no `gh`).
- **Work files:** the plans, review sheets and `/crew` stage file the kit's commands keep in `.claude/context/`.
- **This session:** agents and workflows still running, instructions received but not carried out, and briefs still unanswered.

## Report

Five sections, each numbering its items from 1, stand in for Done / Warnings / Open in this reply; skip an empty one. Every PR, issue, commit and file they name is a clickable link: a full URL (`https://github.com/<owner>/<repo>/pull/<n>`), or a path from the project root with its line (`src/lib.rs:42`).

1. **Decided while you were away:** what landed (commits, merges, finished lanes, with links), then the calls made without the user: one-way calls and calls that went against a recommendation or an adversary first, each with its record id and how to reverse it, then a count of the rest.
2. **Needs your call:** every open question, provisional calls to ratify included, as a numbered brief in the user's language, ordered by what it blocks and restated in full, never as a pointer to an earlier message:

   ```text
   1. <id> — <the question in plain words>
      Recommend: <answer>, because <why>. Against: <the best case against>.
      Premises: <premise> [verified: <how>]; <premise> [assumed]. Reversible | One-way. Blocks: <what waits on it>.
   ```

   AskUserQuestion only for at most two concrete choices, mirrored in the list. A timeout or an away notice leaves the item unanswered.
3. **In flight:** running agents and workflows, open PRs with their CI and review state, and lane worktrees with unmerged commits, each with its owner.
4. **Blocked:** what cannot move and on what (failing CI, a dead agent, an unanswered call), and what is broken or unenforced: a check that did not run, a decision in force that a test or hook should enforce but whose `enforced-by` is still `none yet`.
5. **Next:** the next actions in order, the user's instructions not yet carried out (with their date), and what to type to continue, such as `/proceed`.

## --handoff

Write the same rundown to `.claude/context/handoff-<YYYY-MM-DD>.md`, append the output of `bash .claude/bin/decisions.sh export --handoff`, and give the path. A full install gitignores `.claude/context/`, and the record is private: whether the file leaves this machine is the user's call. No secrets, keys or tokens go in it.
