---
description: "Chain the steps from intake to fix wave, pausing at the user's gates; stops before /ship"
---

Run the whole cycle on `$ARGUMENTS`: PR or issue numbers, a board, or a goal; with none, ask what to work on. Each stage is a kit command run through the Skill tool with its argument (`solana-ai-kit:<name>` in a plugin install), so each stage's own rules apply. This session holds the decisions between stages, and the user holds the gates. It never merges; a push or a PR waits for the user's go-ahead at the ship gate, and the run ends by asking them to type `/ship`, which only they can run.

## Stage file

Start `.claude/context/crew-<YYYY-MM-DD>-<slug>.md` and update it after every stage: the user's request verbatim with its date, the stage reached, each stage's output path, the pinned base and the branch, each gate's answers quoted, and any running workflow. A resumed run (`/proceed`) starts from it, not from memory.

## Stages

1. `/intake <request>`: the numbered work list and its questions. **Gate 1**, when it has questions for the user.
2. `/research <question>` for the open questions a fact settles; skip it when there are none.
3. `/decide <question>` for each open decision: clear calls are decided and recorded, and the user's calls wait for gate 2.
4. `/plan-work <goal>`: the plan file. **Gate 2**, always: the plan's approval, with the calls it rests on.
5. `/implement <plan file>`: the integration branch and its head SHA.
6. `/review-round <branch>`: the numbered sheet. **Gate 3**, when the sheet holds anything for the user to answer or approve.
7. `/fix-wave <sheet>`, then `/review-round <old head>..<new head>` on what the wave changed. At most two fix waves; what survives them goes to the user.
8. **Ship gate**, always: the branch, its head SHA, the review that covers it, and what is still open. Ask the user to push the branch and open its PR (`/pr-description` writes it; pushing is theirs to do or approve), then to type `/ship <PR>`.

## Gates

- A gate ends the turn with the numbered list inside Done / Warnings / Open, grouped and written as [/decide's briefs](decide.md#brief). A timeout, an away notice, or a reply asking to wait or explain is no answer: the next stage waits.
- Record each answer in the user's words: `bash .claude/bin/decisions.sh supersede <id> --by you --decision '<what they chose>' --words '<their words, verbatim>'` on the proposal it answers, or `add --by you --kind decision --question '<the brief>'` with the same options where none was recorded; add `--date YYYY-MM-DD` when they said it on another day. Single-quote every value, writing an apostrophe as `'\''`. If the helper is missing or fails, say so and keep their words quoted in the stage file.
- A scope the user names is a hard stop: plan-only ends at gate 2, investigate-only after `/decide`, and candidates-only at the sheet of `/review-round --candidates`; clear-wins-only runs `/review-round --clear-wins`.
- Stages that fan out run as dynamic workflows when the session can run them, so the user can watch in `/workflows`; else as background subagents (`/tasks`). A workflow takes no input mid-run, so every question waits for the next gate.

## Interruptions

After a usage limit, a crash or a compaction, re-read the stage file and `bash .claude/bin/decisions.sh in-force`, then relaunch only unfinished work. A call made while recovering is recorded with `--status provisional --by agent` and goes to the user at the next gate; recovery never passes a gate on their behalf.
