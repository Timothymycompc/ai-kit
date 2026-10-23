---
description: "Run a task with parallel agents: file-owned lanes, one integrator, worktrees, verified reports"
disable-model-invocation: true
---

Run `$ARGUMENTS` with parallel agents. An empty task, or a bare `proceed`, means the unfinished work: take stock of what is done (files, commits, agent reports) and fan out only the rest. Stacked with `/adversarial` (`/parallel /adversarial <task>`), both commands receive the task and its proposer and adversary pairs run as lanes here. If the task itself starts with a `/command`, that command did not load (stacking works only when typed at the interactive prompt; `claude -p` loads the first command alone): say so, then run the rest.

## Plan

1. **Decisions in force:** `bash .claude/bin/decisions.sh in-force`, and `bash .claude/bin/decisions.sh hash` for the record's hash. If the helper is missing or fails, or the record is empty, say so and use the decisions made in this conversation. Settle what the lanes would depend on before dispatch, or bring it to the user: lanes built on an open question get rebuilt.
2. **Lanes** that need nothing from each other, each with a goal, the files it owns, the files it only reads, and a report file (in the session scratchpad, or in `.claude/context/`, which a full install gitignores). One owner per file. Shared files (CHANGELOG, VERSION, counts, lockfiles, test registries, indexes) belong to one integrator, this session: a lane writes the change it needs there into its report.
3. **A worktree per writer,** from a pinned commit (`git rev-parse HEAD`, which leaves out uncommitted changes); readers share the checkout. `isolation: worktree` branches from the remote's default branch unless the user's settings set `worktree.baseRef` to `"head"`, so to start anywhere else run `git worktree add -b <lane-branch> .claude/worktrees/<lane> <sha>` and brief the writer with that literal path. Writers make WIP commits on their branch: no `git stash` (every worktree shares one stash stack), no push, no merge.

## Dispatch

4. Prefer a dynamic workflow when the Workflow tool is available, so the user can watch every agent in `/workflows`; otherwise launch background subagents in one message, which the user watches in `/tasks` (20 run at once by default; a workflow queues the rest). A workflow takes no input mid-run: a decision point ends one workflow, and the next starts once it is settled here.
5. Every brief carries:
   - the lane, its files and its worktree;
   - what not to do: edit outside its files, push, merge, run `decisions.sh add` or `supersede`, or settle a conflict with another lane instead of reporting it;
   - the decisions in force verbatim, under "The user's decisions in force: never contradict one; report a conflict instead", and the record hash;
   - the return contract: the full report written to its file, returning the path plus **Verified** (command and result), **Decisions made** (routine ones as a count), **Decisions needed** (as briefs), **Assumptions**, **Next owner**, and the record hash it worked from.

   In a workflow, pass the hash through `args` into each agent's prompt: relaunched with a new hash after the record changes, those agents run again instead of returning cached results built on old decisions.

## Integrate

6. **Verify before relaying:** re-run each claim the next step rests on (command, test, `file:line`). A gate that ran zero tests or reported SKIP has not passed.
7. Integrate lane branches one at a time, the way [/implement](implement.md) does: `git diff --name-only <sha>..<lane-branch>` must list only that lane's files, then `git cherry-pick <sha>..<lane-branch>`; a conflict means a lane wrote outside its files, so stop and look. Apply the shared-file changes, then re-run the checks of every shared file a lane touched: a clean cherry-pick can still drop a line another lane needed. Pushing, opening PRs and merging PRs stay the user's call unless a standing order covers them.
8. Remove each lane worktree once integrated (`git worktree remove <path>`, outside the sandbox if it refuses the write to the git directory), and stop any server or watcher a lane left running.

## Output

Done names each lane and what it proved. What the lanes need decided goes in Open as numbered briefs: the question in plain words, your recommendation and the case against it, premises marked verified or assumed, whether it is reversible, and what it blocks.
