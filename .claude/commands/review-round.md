---
description: "Review a PR, branch, range or since <date> by lens; reproduce High and Critical; a numbered sheet"
---

Review `$ARGUMENTS` independently: a PR number, a branch, a range `A..B`, or `since <date>` for what landed on the base branch since then; empty means the current branch against `main` (else `master`). Any stack, not only program code. It never edits the code under review: `/diff-review` is the self-check in the context that wrote the code, and this is the independent one.

- `--candidates`: no defaults. Every item is `ask`, with a recommendation, and nothing goes to `/fix-wave` until the user picks.
- `--clear-wins`: only clear wins (confirmed, small, reversible, no dilemma) are `fix`, and the flag approves them; everything else is `defer`.

## Steps

1. **Target.** Run each `gh` and network `git` call bare, as the whole Bash command: a pipe, redirect, `$(...)` or `cd` prefix keeps it in the sandbox, where it may fail to authenticate.
   - PR: `gh pr view <n> --json headRefOid,baseRefName,title,body,files`, `gh pr diff <n>`, then `git fetch origin pull/<n>/head`.
   - Branch: `git rev-parse <branch>` and `git diff <base>...<branch>`. Range: `git diff A..B`.
   - `since <date>`: after `git fetch origin <base>`, `git rev-list -1 --first-parent --before=<date> origin/<base>` is the start, and the diff is `<start>..origin/<base>`.

   A review covers one commit, the head; uncommitted changes are not in it, so say so. Reviewers read the head from `git worktree add --detach .claude/worktrees/review-<slug> <head>`, which leaves the user's checkout alone.
2. **Decisions in force:** `bash .claude/bin/decisions.sh in-force`. If the helper is missing or fails, or the record is empty, say so and use the decisions made in this conversation. Every reviewer gets them verbatim.
3. **One reviewer per lens, all in parallel.** Copies of one generalist reviewer return mostly false positives; a lens each finds different things. Skip a lens with nothing to read, and say why in the header.
   - **Security and accounts:** on program code, `/diff-review`'s Solana checks and `/audit-solana`'s bug classes; elsewhere secrets, auth, injection and supply chain, as `/audit-infra` covers them.
   - **CU:** changed on-chain instructions, measured the way `/profile-cu` and `/benchmark` do.
   - **Tests and gates:** changed behaviour has tests, and each gate is shown to run: a suite that reports zero tests, SKIP, or a pass with nothing asserted is a failure.
   - **Docs against code:** README, docs, comments and help text say what the code now does.
   - **Ripple and counts:** shared files (CHANGELOG, VERSION, lockfiles, test registries, counts) and the project's own ripple rules, where its instruction file keeps them.
   - **Product:** what a user sees and does, the way `/product-review` looks at it.
   - **Decisions:** the change against the decisions in force, with `bash .claude/bin/decisions.sh export` for their history and the agents' reports where they are on disk: a decision contradicted, a call made without the user that was theirs ([triage](decide.md)), a call reported as decided whose premises nobody verified.
4. **Triage the findings, then reconcile adversarially.** Merge duplicate findings, then label them with [/explore's triage](explore.md#triage); with `/adversarial` or `/adv` in front, all of them are adversarial. Each High or Critical finding, and each one labelled adversarial, goes to a fresh agent that reproduces it against the review worktree without editing the reviewed files (a scratch test goes in its own temp directory), and returns the command and its output. A finding labelled adversarial then goes to a peer that sees the claim and the reproduction, but not the reviewer's argument, and answers CONFIRM, DISPUTE or DOWNGRADE with its reason; one labelled user is an `ask` item. A finding that does not reproduce is never reported as High or Critical: it is unverified.
5. **Sheet.** Merge duplicates, then number every item once, each with a default action: `fix` (confirmed or self-evident, and the fix is clear and fits this change), `ask` (the user's call: taste or product, scope, an interface, a decision in force, or a dispute the proof does not settle) or `defer` (real, but not this change). Write it to `.claude/context/review-<YYYY-MM-DD>-<slug>.md`, the slug ending in the short head SHA, even when it holds no items: it is the record `/ship` checks. Then remove the review worktree (outside the sandbox if it refuses).

Lenses and reproducers are independent, so run them as a dynamic workflow when the session can run one, with a findings schema per lens and the decisions in force in each prompt, so the user can watch it in `/workflows`; else as background subagents launched in one message (`/tasks`), with the triage, the reproducers and the peers as later batches. A workflow takes no input mid-run, so questions wait for the sheet.

## Output

```
REVIEW ROUND: <target> @ <full head SHA> vs <base> | <n> items | lenses run; skipped (why) | triage: <n> adversarial, <n> parallel, <n> serial, <n> user
## Needs your call
<n>. [<severity>][<lens>][<label>] <file:line> — <the problem in plain words>
     Recommend: <action>, because <why>. Against: <the best case against>.
     Evidence: <command → result> | unverified. Verdict (labelled adversarial): CONFIRM | DISPUTE | DOWNGRADE.
## Fix by default
<n>. [<severity>][<lens>][<label>] <file:line> — <problem> → <fix>. Evidence: <command → result>
## Deferred
<n>. [<severity>][<lens>][<label>] <file:line> — <problem>. Not now because: <reason>
## Disputed and dropped
- <claim> — <why the proof rejected it>
```

The sheet goes to the file and, as the numbered list, into the last message, in the user's language. They answer by number, inline ("1 ok · 4 defer · 7 fix, but keep the API") or in the file, and a bare "ok" approves every `fix` item while each `ask` needs its own answer. `/fix-wave` applies what they approve; silence approves nothing. The header names the full head SHA because `/ship` accepts a review only of the commit it merges.
