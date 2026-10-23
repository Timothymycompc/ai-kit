---
description: "Settle a question by verified panel, or bring the user the points to decide and what unblocks you"
---

The question, if any: `$ARGUMENTS`; `--no-sheet` in it skips the decision sheet (below). The user decides what is theirs; a verified panel decides the rest, records it and says so. With no question, and whenever the user asks for the points they need to decide or what you need from them to carry on, gather every open decision — the record's proposed and provisional entries (`bash .claude/bin/decisions.sh export --handoff` groups them by status), the conversation's Open items, the decisions subagents reported needing — show them as briefs (below) and record nothing new. Asked to explain them better, give each one's why in plain words: what each choice changes and what waits on it.

## The record

`bash .claude/bin/decisions.sh` is the only way to read or write it: `in-force` lists the decisions in force, `export` the whole record, and `add` and `supersede` write. It lives in the git common directory, shared by every worktree of the clone and never committed; never write it with Write or Edit. Only the main session writes it: run as a subagent, return the briefs and the entries you propose in your report instead. If the helper is missing or fails, say so once and work from the decisions made in this conversation.

## Steps

1. **Settled already?** Read the decisions in force. If one answers the question, report it (its id and the user's words) and stop: never re-ask or re-argue a settled call, including one the user made against advice. Their newest explicit instruction beats any entry; record it as a supersede.
2. **Whose call**, before any panel runs:
   - **Always the user's:** product intent; a material change to scope or architecture; contradicting a decision they made or a fact they stated; operational approvals (merge, push, publish, deploy, authority changes, issues, PRs or comments on any other repo); deleting anything they did not name; strategy or claims in documents others will read; keys, funds, mainnet, money.
   - **Scope modes stop everything:** under plan-only, candidates-only, investigate-only or clear-wins-only, do exactly that and nothing beyond it; a call outside it is a brief.
   - **Principles enable decisions:** a call that applies a principle the user set is decided and cites it; one that stretches a principle, or sets two against each other, is theirs.
3. **Facts.** If a premise needs research, run `/research` on it, or reuse a `.claude/context/research-*.md` whose re-verify-by dates have not passed.
4. **Panel.** A proposer subagent argues for one answer with its premises; an adversary, in its own context, argues the strongest alternative and attacks each premise ("be right, not contrarian: say so if it holds"). Each report ends with **Verified** (command and result), **Decisions made**, **Decisions needed** (as briefs), **Assumptions** and **Next owner**. Each premise then needs a verifier artifact from a source other than the one asserting it — a command and its output, a doc quote with its URL and date, a test, a `file:line` — and is marked `[verified: <artifact>]` or `[assumed]`, with a re-verify-by date if it can decay. A fact the user stated outranks a source that disagrees: report the conflict, never overwrite it. For a security call, add a cross-model check when Codex is installed (`codex exec --sandbox read-only '<brief>'`): same-model panels share blind spots. Run the panel as a dynamic workflow when the session can run one (load the `workflow-authoring` skill first), so the user can watch it in `/workflows`, else as background subagents (`/tasks`); every agent's prompt carries the decisions in force.
5. **Triage.**
   - **Clear:** every premise verified, the panel agrees or the proof settles it, and the call is reversible. Decide it, record it, report it under Done.
   - **Cloudy:** a premise unverified, a split the proof does not settle, a taste or wording call, or expensive if wrong. It goes to the user as a brief; no panel clears a taste call.
   - **The user's** (step 2): a brief.
6. **Record**, single-quoting every value (write an apostrophe as `'\''`: inside double quotes the shell expands `$` and backticks in the user's words):
   `bash .claude/bin/decisions.sh add --kind decision --by panel --question '<question>' --decision '<decision>' --words '<the words it rests on, verbatim>' --premises '<premise [verified: how]; premise [assumed]>'`
   The helper stamps today's date; pass `--date YYYY-MM-DD` when the words are from another day.
   - A clear call: as above, plus `--enforced-by '<test or hook>'` once one proves it. Until then the entry reads `none yet` and stays in Warnings.
   - A brief for the user: the same with `--status proposed` and your recommendation as the decision, so it outlives this session.
   - The user's answer: `supersede <id> --by you` on that proposal (`add --by you` when there is none), with their words verbatim, never paraphrased. Only the user supersedes a decision they made.
   - The helper refuses a field that looks like a credential: write `[redacted]` in its place.

## Brief

Every decision shown to the user: numbered so they answer by number, in their language, asked at the level of intent and policy rather than mechanism, and restated in full every turn until they resolve or drop it — never a pointer to an earlier message.

```text
<n>. <id> — <the question in plain words>
   Recommend: <answer>, because <why>. Against: <the best case against>.
   Premises: <premise> [verified: <how>]; <premise> [assumed]. Reversible | One-way. Blocks: <what waits on it>.
```

Group them as **Needs your call**, **Decided while you were away** (one-way calls and calls against a recommendation first, then a count of the rest) and **Deferred**, with no cap. The numbered list in the last message stays the channel, with or without a sheet; AskUserQuestion only for at most two concrete choices at the end of the turn, after the unblocked work, mirrored in the list. A timeout, an away notice, or a reply asking to wait or explain leaves the item unanswered.

## Decision sheet

On by default whenever a brief needs the user, the round with no question included, a new page each run: a local HTML page with a card per brief, its options as buttons, its context folded away, a notes box, and a Copy answers button. Skip it for `--no-sheet`, or where `.claude/bin/report-page.sh` is missing (a plugin install).

1. **Write the briefs as JSON** to a file under `$TMPDIR`, not under `.claude/`, where the file tools ask before every write. The shape is in the script's header: a title, and per brief its number in the numbered list, its record id as `id`, the options with the recommended one, `why`, `premises`, `reversible`, `blocks`, the panel's arguments and artifacts as `context`, and as `links` every PR, issue, commit and file it names (a full https URL, or a path from the project root with its line).
2. **Render it** from the project root: `bash .claude/bin/report-page.sh decisions <the JSON's path>`. The page and a copy of its JSON go to `.claude/reports/`, which git ignores even in a project that commits `.claude/`, and every earlier page there gains this one in its navigation bar. The script prints the page's path and never opens it, and this session's sandbox cannot either, so tell the user to run the command its stderr prints, prefixed with `!` (`! open <path>`, or `! xdg-open <path>` on Linux). On exit 1, show its one-line reason, fix the JSON once if the data was refused, and otherwise carry on with the list alone.
3. **Answers come back** as a pasted block that starts `Decision answers:`, one line per brief: `<n>. [<id>] <question> → <the choice> | notes: <their notes>`. Each answered line is the user's words. When the record exists, record it word for word on the proposal its `[id]` names, through a quoted heredoc so quotes and paths in the notes reach the helper as data (`add --by you --kind decision` with a `question:` line where the id is not a record id):
   ```bash
   bash .claude/bin/decisions.sh supersede <id> --by you --stdin <<'DECISION_END'
   decision: <what they chose, their notes included, in a line>
   words: <the whole pasted line, verbatim>
   DECISION_END
   ```
   Without a record, quote the lines back under Done. A line reading `→ not answered` stays open unless its notes settle it.

## Output

The briefs, grouped; the page's `! open <path>` line for the user to run; and the ids the record gained.
