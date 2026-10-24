---
description: "Triage tasks into adversarial, parallel, serial or yours, then run each one that way"
disable-model-invocation: true
---

Sort the tasks in `$ARGUMENTS` by what each one needs, then run each that way. [/adversarial](adversarial.md) and [/parallel](parallel.md) run everything they are given in their one mode; this command picks the mode per task, so adversaries go only where being wrong is costly. It is a kit command and has nothing to do with Claude Code's built-in `Explore` subagent, which only searches code.

## Steps

1. **Tasks.** Split the text into tasks the way [Composition](parallel.md#composition) splits a call's parentheses, number them, and print the split; with nothing given, the tasks are this conversation's unfinished work. A task written as `/adv(...)` or `/adversarial(...)` is adversarial, and one written as `/par(...)` or `/parallel(...)` is parallel: the user chose, so it skips the triage and starts with the other tasks. Any other call runs first, as Composition says, and what it returns is triaged with the rest.
2. **Decisions in force:** `bash .claude/bin/decisions.sh in-force`. If the helper is missing or fails, or the record is empty, say so and use the decisions made in this conversation. Every agent's brief carries them, as [/parallel's Dispatch](parallel.md#dispatch) says.
3. **Triage** the rest as [Triage](#triage) says, and show its lines before launching the tasks, one per task: `<id> | <label> | <reason>`.
4. **Run each task by its label:**
   - **adversarial:** as [/adversarial](adversarial.md) does, with at least one proposer and adversary pair;
   - **parallel:** as [/parallel](parallel.md) does, a lane each and no adversary;
   - **serial:** in one queue, one at a time and in dependency order, each in this session or by one agent;
   - **user:** as [/decide](decide.md) treats a call that is the user's: no panel, at most one agent to gather the facts or list the options, then a numbered brief on its decision sheet.

   The adversarial tasks, the parallel lanes and the serial queue start together, as one board when the Workflow tool is available. Tasks that would write the same files, or that need another's result, run one after another instead, and the run says so ([Composition](parallel.md#composition), rules 4 and 5).
5. **No pause for approval,** except on the user-labelled tasks: those wait for the user's answer, with any task that needs it, and everything else runs. The user changes a label by sending the task again with `/adv` or `/par` in front.

## Triage

Every command that triages runs it this way: this one, `/research`, `/plan-work` and `/review-round` before their adversarial pass, and `/decide` before its panel.

1. Number the items, each on one self-contained line: what it is, and what rides on it. The triage sees nothing else.
2. One subagent on Sonnet labels them: the Agent tool with `model: "sonnet"`, or `agent(<prompt>, {model: 'sonnet'})` inside a workflow. Its prompt is the [Triage rubric](#triage-rubric) section below, verbatim, then the numbered items, and nothing more. Where no subagent can run, apply the rubric in this session and say so.
3. It returns one line per item, `<id> | <label> | <reason>`, the label one of adversarial, parallel, serial or user. Ask once more for any item left without a valid line; one still unlabelled is adversarial, with "no valid label" as its reason.
4. With `/adversarial` or `/adv` in front of the command, skip the triage: every item is adversarial.
5. Show the lines in the command's output, or in the file it writes, so a wrong label can be seen.

## Output

The triage lines first, then one line per task: its label, what it produced (a report path, a verdict, a commit) and the command or file that proves it. Inside Done / Warnings / Open, the user-labelled tasks go in Open as numbered briefs ([format](decide.md#brief)), with the sheet's `! open <path>` line and the tasks waiting on each.

## Triage rubric

Label each item by what it needs, not what was asked; if you overrule a request for adversarial review, say so in the reason.

### Labels

- **adversarial**: a no-stake agent tries to refute or break it (pro/con pair for two-sided decisions).
- **parallel**: independent reviewers or lenses; nobody plays attacker.
- **serial**: one agent, one at a time, checks a primary source, runs a test or command, or re-checks a fix.
- **user**: the owner decides. One agent may gather facts or list options; no panel, persona or adversary generates, ranks or picks.

### Order: first match wins

1. **user**: preference or owner-set scope, not facts: naming, tone, visual style, a document's scope (what it covers, expands or cuts) or length, framing a message, options differing in style or scale rather than correctness, a direction the owner already chose, including generating options for any of these. Wording errors (grammar, broken placeholders, wrong numbers) are facts.
2. **adversarial**: new, planned or broadly changed logic that enforces a boundary or vouches for safety (permissions, command parsing, guards, auth, data access, signing, moving money, spend limits, secrets, malware or supply-chain screening), or an item that is itself a check others will rely on (CI assertion, validator, scanner, release gate). Green tests and low cost don't lower this; tests cover what the author imagined. Still step 3 here: whether a value the logic uses (address, ID, version) is right, and re-checking a narrow fix (one named finding, a changed condition or value) unless it rewrites parsing or matching or claims to close a class of bypasses.
3. **serial**: a determinate question (number, version, address, yes/no) one primary source, test or command settles, however costly an error; confirming that fixes or an agreed must-fix list landed; findings their reporter already reproduced.
4. **adversarial**, if being wrong is costly (others build on it, or an error loses data, funds, days or legal standing, revertible or not) and:
   - a design, plan or premise (not a list of checkable facts), the lead's own included, will drive that work, above all when evidence already cuts against it;
   - a check claims a guarantee and may be unable to fail;
   - unreproduced findings will drive it;
   - claims come from a party with reason to overclaim (contest entries, vendors, outside proposals); or
   - an argument or interpretation (not checkable facts) goes to a regulator, counterparty or the public before approval.
5. **parallel**: everything else: ordinary or merged code, many independent facts or citations (whatever rides on them), lens audits of existing systems, screening ideas against facts.

### Examples

- adversarial: rewritten secret-upload guard, tests green; fix round rewriting its tokenizer; dropping a live database column.
- parallel: pull request adding a CSV export; auditing a codebase for slow queries.
- serial: one-line fix plus a test reproducing the bug.
- user: landing-page palette; judges ranking five homepage designs.

### Output

One line per item, nothing else: `<id> | <label> | <one-line reason>`
