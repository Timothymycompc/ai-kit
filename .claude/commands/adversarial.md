---
description: "Put a task's load-bearing claims and key decisions through a proposer and an adversary, with proof"
disable-model-invocation: true
---

Do `$ARGUMENTS`, building on nothing that has not survived an adversary. This command is literal: every task given runs adversarially, each with at least one proposer and adversary pair, and none is dropped as not worth one. It does no triage; [/explore](explore.md) is the command that sorts tasks by what they need. Stacked with `/parallel` (`/parallel /adversarial <task>`), every pair below runs as a lane of that fan-out. Calls written into the task, `/name(...)`, run as [/parallel's Composition](parallel.md#composition) says; as an outer call, this command attacks what its inner calls return.

## Steps

1. **Decisions in force:** `bash .claude/bin/decisions.sh in-force`. If the helper is missing or fails, or the record is empty, say so and use the decisions made in this conversation. An entry is a premise, not a question to reopen: evidence against it goes to the user as a brief, and only the user supersedes it (their newest explicit instruction does).
2. **Items:** per task, every claim and decision that changes what gets built if it is wrong; a task with none still gets a pair, on its result. Leave the rest.
3. **Pairs:** per item (closely related items can share one), a proposer subagent that makes the case and an independent adversary briefed to refute it ("be right, not contrarian: say so if it holds"). Neither edits the checkout; a reproduction runs in a scratch worktree or a temp directory. An item that can fail more than one way gets an adversary per lens (security, correctness, cost, the user's intent). A security call also gets a cross-model adversary when Codex is installed (`codex exec --sandbox read-only '<brief>'`): same-model pairs share blind spots. Run the pairs at once, as a dynamic workflow when the Workflow tool is available (the user watches it in `/workflows`), else as background subagents (`/tasks`); each brief carries the decisions in force.
4. **Proof per premise:** a command and its output, a doc quote with its URL, a test, or `file:line`, from a source other than the one making the claim. Current official docs outrank a local install or memory.
5. **Verdicts,** each with its proof and one plain-language line: **PASS** (holds, proven), **NEEDS-FIX** (holds once a named change is made), **REFUTED** (disproven, proof attached), **UNVERIFIED** (no proof either way: it could not run, the source was unreachable, a limit hit; never counted as PASS or REFUTED). A High or Critical finding is reproduced, command and output, before it is reported; one that does not reproduce is UNVERIFIED.
6. **Triage:**
   - **Always the user's,** as a brief carrying the pair's findings: product intent; a material change to scope or architecture; contradicting a decision in force or a fact they stated; operational approvals (merge, push, publish, deploy, authority changes, issues, PRs or comments on another repo); deleting anything they did not name; claims in documents others will read; keys, funds, mainnet.
   - **Clear** (every premise proven, the pair agrees or the proof settles it, reversible): decide, record, report. A call that applies a principle the user set cites it; one that stretches a principle, or sets two against each other, is theirs.
   - **Cloudy** (a premise UNVERIFIED, a split the proofs do not settle, a taste or wording call, or expensive if wrong): the user's, as a brief. No panel clears a taste call.
   - A plan, an investigation or a list of candidates is delivered as exactly that: no edits beyond it.
7. **Record each clear call.** Only this session writes the record; agents propose in their reports.
   `bash .claude/bin/decisions.sh add --kind decision --by panel --question '<question>' --decision '<decision>' --words '<user words>' --premises '<premise [verified: how]; premise [assumed]>' --enforced-by '<test or hook, or none yet>'`
   `--words` quotes, never paraphrases, the user words the call rests on (the principle it applies, or the request itself); the helper stamps today's date, so add `--date YYYY-MM-DD` when those words are from another day. `none yet` keeps the call in Warnings until a test or hook enforces it. Single-quote every value (an apostrophe is `'\''`): in double quotes the shell expands `$` and backticks inside the user's words.

## Output

Inside the usual Done / Warnings / Open:
- **Done:** one line per item (claim, verdict, proof), then the decided calls: one-way ones and ones that went against a recommendation or an adversary first, then a count of the rest.
- **Warnings:** UNVERIFIED items that something still rests on.
- **Open:** every call that is the user's or cloudy, as a numbered brief in the user's language, ordered by what it blocks and restated in full until answered:

  ```text
  3. <id> — <the question in plain words>
     Recommend: <answer>, because <why>. Against: <the best case against>.
     Premises: <premise> [verified: <how>]; <premise> [assumed]. Reversible | One-way. Blocks: <what waits on it>.
  ```

The numbered list is the channel. Use AskUserQuestion only for at most two concrete choices at the end of the turn, mirrored in the list. A timeout, an away notice, or a reply asking to wait or explain leaves the item unanswered.
