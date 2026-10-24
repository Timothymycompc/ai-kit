#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# The decision layer's three hooks, replayed the way Claude Code runs them: the command
# registered in settings.json, under `sh -c`, with the payload on stdin.
#
#   decisions-inject.sh        SessionStart, SubagentStart   the list in force, at start
#   decisions-push.sh          PreToolUse, every tool        the list again, once, when it changed
#   decisions-report-check.sh  SubagentStop                  a kit agent's report carries the contract
#
# The record is private to a clone, under its git common directory, so the fixture is a
# real repository with a linked worktree: the two must read one record. What has to hold:
# a project with no record sees nothing at all; no hook can block a tool call or fail a
# session whatever goes wrong inside it; the push is silent until the list changes and
# then reaches each agent exactly once; and the report check holds the kit's own agents to
# the contract and no one else.

echo "[test_decision_hooks] The decision record reaches agents, and kit agents report what they decided"
echo ""

WORK="$(new_tmp)" || exit 1
trap 'rm -rf "$WORK"' EXIT
SETTINGS="$REPO_ROOT/.claude/settings.json"
PLUGIN_HOOKS="$REPO_ROOT/plugin/hooks/hooks.json"
HOOKS_SRC="$REPO_ROOT/.claude/hooks"

# reg <file> <event> <script> — the registered command for <event> that names <script>.
reg() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, event, script = sys.argv[1:4]
for entry in json.load(open(path, encoding="utf-8"))["hooks"].get(event, []):
    for h in entry.get("hooks", []):
        if script in (h.get("command") or ""):
            print(h["command"])
            raise SystemExit
PY
}
INJECT_SS="$(reg "$SETTINGS" SessionStart decisions-inject.sh)"
INJECT_SA="$(reg "$SETTINGS" SubagentStart decisions-inject.sh)"
PUSH="$(reg "$SETTINGS" PreToolUse decisions-push.sh)"
CHECK="$(reg "$SETTINGS" SubagentStop decisions-report-check.sh)"
P_INJECT="$(reg "$PLUGIN_HOOKS" SubagentStart decisions-inject.sh)"
for pair in "SessionStart|$INJECT_SS" "SubagentStart|$INJECT_SA" "PreToolUse|$PUSH" "SubagentStop|$CHECK" "plugin SubagentStart|$P_INJECT"; do
  TOTAL=$((TOTAL + 1))
  if [ -n "${pair#*|}" ]; then
    echo "  PASS: ${pair%%|*} has a registered decision hook to replay"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${pair%%|*} registers no decision hook, so this suite proves nothing there"
    FAIL=$((FAIL + 1))
  fi
done

# ── fixture: a repository, a linked worktree, and the hooks copied into both ──
REPO="$WORK/repo"
WT="$WORK/wt"
mkdir -p "$REPO"
(
  cd "$REPO" && git init -q \
    && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t \
       GIT_COMMITTER_EMAIL=t@example.invalid git commit -q --allow-empty -m init \
    && git worktree add -q "$WT"
) > "$QUIET_LOG" 2>&1 || quiet_fail "fixture repository"
for d in "$REPO" "$WT"; do
  mkdir -p "$d/.claude/hooks"
  cp "$HOOKS_SRC"/decisions-*.sh "$d/.claude/hooks/"
done
REC="$REPO/.git/decisions"
NL='
'

# payload <event> [key=value ...] — a payload as Claude Code sends it: compact JSON, with
# non-ASCII left raw. true/false become booleans, tool_input takes JSON, and a value of
# "-" removes a default key.
payload() {
  python3 - "$@" <<'PY'
import json, sys
event, pairs = sys.argv[1], sys.argv[2:]
d = {"session_id": "sess-main", "transcript_path": "/dev/null", "cwd": "/tmp",
     "permission_mode": "default", "hook_event_name": event}
if event == "PreToolUse":
    d.update(tool_name="Read", tool_input={"file_path": "/tmp/x"}, tool_use_id="toolu_1")
for p in pairs:
    k, v = p.split("=", 1)
    if v == "-":
        d.pop(k, None)
    elif v in ("true", "false"):
        d[k] = v == "true"
    elif k == "tool_input":
        d[k] = json.loads(v)
    else:
        d[k] = v
print(json.dumps(d, ensure_ascii=False, separators=(",", ":")))
PY
}

# run <command> <project dir> <payload> — sets RC, OUT and ERR.
run() {
  set +e
  OUT="$(cd "$2" && printf '%s' "$3" | PATH="${HOOK_PATH:-$PATH}" CLAUDE_PROJECT_DIR="$2" \
    CLAUDE_PLUGIN_ROOT="${HOOK_PLUGIN_ROOT:-}" sh -c "$1" 2>"$WORK/err")"
  RC=$?
  set -e
  ERR="$(cat "$WORK/err")"
}

# ctx <json> — the additionalContext, "" for no output, INVALID for output that is not JSON.
ctx() {
  [ -n "$1" ] || { printf ''; return; }
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("INVALID"); raise SystemExit
sys.stdout.write(d.get("hookSpecificOutput", {}).get("additionalContext", ""))'
}
event_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("hookSpecificOutput", {}).get("hookEventName", ""))
except ValueError:
    print("INVALID")'
}

HEAD_LINE="The user's decisions in force: never contradict one; report a conflict instead"

# set_record <sha> <text> — write the in-force list and its version, as decisions.sh does.
set_record() {
  mkdir -p "$REC"
  printf '%s' "$2" > "$REC/in-force.md"
  printf '%s  in-force.md\n' "$1" > "$REC/in-force.sha"
}

# ── the scripts themselves ──────────────────────────────────────────────────
echo "[scripts]"
for f in decisions-inject.sh decisions-push.sh decisions-report-check.sh; do
  assert_cmd_success "sh -n '$HOOKS_SRC/$f'" "$f parses with sh -n"
  if command -v dash >/dev/null 2>&1; then
    assert_cmd_success "dash -n '$HOOKS_SRC/$f'" "$f parses with dash -n"
  fi
  assert_cmd_success "[ -x '$HOOKS_SRC/$f' ]" "$f is executable"
done
# The record lookup and the output are one block carried by two scripts. A copy is code
# that drifts, so the copies must match byte for byte.
shared() { awk '/^# ---- decision record: lookup and output/{p=1} p; /^# ---- end decision record/{p=0}' "$1"; }
SHARED_INJECT="$(shared "$HOOKS_SRC/decisions-inject.sh")"
assert_eq "yes" "$([ -n "$SHARED_INJECT" ] && echo yes || echo no)" "decisions-inject.sh carries the shared record block"
assert_eq "$SHARED_INJECT" "$(shared "$HOOKS_SRC/decisions-push.sh")" \
  "the record block is identical in decisions-inject.sh and decisions-push.sh"

# ── no record: nothing at all ───────────────────────────────────────────────
echo ""
echo "[no record]"
run "$INJECT_SS" "$REPO" "$(payload SessionStart source=startup)"
assert_eq "0|" "$RC|$OUT$ERR" "SessionStart: silent without a record"
run "$INJECT_SA" "$WT" "$(payload SubagentStart agent_id=a-none agent_type=Explore)"
assert_eq "0|" "$RC|$OUT$ERR" "SubagentStart: silent without a record"
run "$PUSH" "$REPO" "$(payload PreToolUse)"
assert_eq "0|" "$RC|$OUT$ERR" "PreToolUse: silent without a record"
assert_dir_not_exists "$REC" "no hook creates a record directory"
mkdir -p "$WORK/norepo/.claude/hooks"
cp "$HOOKS_SRC"/decisions-*.sh "$WORK/norepo/.claude/hooks/"
run "$INJECT_SS" "$WORK/norepo" "$(payload SessionStart source=startup)"
assert_eq "0|" "$RC|$OUT$ERR" "outside any git repository: silent"
mkdir -p "$REC"
printf '' > "$REC/in-force.md"
run "$PUSH" "$REPO" "$(payload PreToolUse)"
assert_eq "0|" "$RC|$OUT$ERR" "an empty in-force list counts as no record"

# ── the list at session start and at agent start ────────────────────────────
echo ""
echo "[injection]"
LIST="# In force${NL}${NL}- D-1 \"quoted\" and a \\ backslash${NL}- D-2	tab, café — and </script>${NL}- D-3 relaxed stays smooth"
set_record aaaa1111 "$LIST"
# A permissive umask for the call that creates seen/, so the privacy assertion below
# tests the hook's own umask rather than this runner's.
OLD_UMASK="$(umask)"
umask 022
run "$INJECT_SS" "$REPO" "$(payload SessionStart source=startup session_id=sess-main)"
umask "$OLD_UMASK"
assert_eq "0" "$RC" "SessionStart exits 0"
assert_eq "SessionStart" "$(event_of "$OUT")" "the output names SessionStart"
assert_eq "$HEAD_LINE${NL}${NL}$LIST" "$(ctx "$OUT")" \
  "the session gets the heading and the list verbatim: quotes, backslash, tab, non-ASCII"
assert_dir_exists "$REC/seen/sess-main.aaaa1111" "the session is marked as having seen this version"
assert_eq "700 700" "$(python3 -c 'import os, sys; print(" ".join(oct(os.stat(p).st_mode & 0o777)[2:] for p in sys.argv[1:]))' \
  "$REC/seen" "$REC/seen/sess-main.aaaa1111")" "markers are private to the user, like the record (whatever the umask)"
# A subagent of the linked worktree reads the same record: one per clone, shared live.
run "$INJECT_SA" "$WT" "$(payload SubagentStart agent_id=agent-1 agent_type=Explore)"
assert_eq "SubagentStart" "$(event_of "$OUT")" "a subagent's output names SubagentStart"
assert_eq "$HEAD_LINE${NL}${NL}$LIST" "$(ctx "$OUT")" "a subagent in a linked worktree gets the same list"
assert_dir_exists "$REC/seen/agent-1.aaaa1111" "the subagent is marked as having seen this version"
for ev in resume compact clear; do
  run "$INJECT_SS" "$REPO" "$(payload SessionStart source=$ev)"
  assert_contains "$(ctx "$OUT")" "D-3 relaxed stays smooth" "SessionStart source=$ev re-adds the list"
done
mkdir -p "$REPO/sub/dir"
run "$INJECT_SS" "$REPO/sub/dir" "$(payload SessionStart source=startup)"
assert_eq "0|" "$RC|$OUT$ERR" "fixture: a subdirectory without the hooks runs nothing"
mkdir -p "$REPO/sub/dir/.claude/hooks" && cp "$HOOKS_SRC"/decisions-*.sh "$REPO/sub/dir/.claude/hooks/"
run "$INJECT_SS" "$REPO/sub/dir" "$(payload SessionStart source=startup)"
assert_contains "$(ctx "$OUT")" "D-1" "a project rooted below the repository's top finds the record by walking up"
run "$INJECT_SS" "$WORK/norepo" "$(payload SessionStart source=startup)"
OUT_NOREPO="$OUT"
set +e
OUT="$(cd "$WORK/norepo" && payload SessionStart source=startup | GIT_DIR="$REPO/.git" CLAUDE_PROJECT_DIR="$WORK/norepo" sh -c "$INJECT_SS" 2>/dev/null)"
set -e
assert_eq "|D-1" "$OUT_NOREPO|$(ctx "$OUT" | grep -o 'D-1' | head -1)" "GIT_DIR is honoured, through git"
# Grok Build spells the keys in camelCase.
run "$INJECT_SA" "$WT" "$(payload SubagentStart hook_event_name=- session_id=- hookEventName=SubagentStart agentId=agent-camel sessionId=sess-camel)"
assert_eq "SubagentStart" "$(event_of "$OUT")" "camelCase payload: the event is read"
assert_dir_exists "$REC/seen/agent-camel.aaaa1111" "camelCase payload: the agent is keyed on agentId"

# ── the push: silent until the list changes, then once per agent ────────────
echo ""
echo "[push]"
run "$PUSH" "$REPO" "$(payload PreToolUse session_id=sess-main)"
assert_eq "0|" "$RC|$OUT" "the session's tool call after SessionStart is silent (it already holds this version)"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=agent-1 agent_type=Explore)"
assert_eq "0|" "$RC|$OUT" "a subagent's tool call after SubagentStart is silent"
# An agent that never got the list, such as one spawned before the record existed.
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=agent-2 agent_type=general-purpose tool_name=Bash tool_input='{"command":"ls"}')"
assert_eq "PreToolUse" "$(event_of "$OUT")" "an agent that never saw the list gets it at its next tool call"
assert_contains "$(ctx "$OUT")" "$HEAD_LINE" "the push carries the heading"
assert_contains "$(ctx "$OUT")" "new or changed since you last saw it" "the push says the list replaces any earlier copy"
assert_contains "$(ctx "$OUT")" "D-3 relaxed stays smooth" "the push carries the list"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=agent-2)"
assert_eq "0|" "$RC|$OUT" "same version, next tool call: silent"
# The list changes.
LIST2="# In force${NL}${NL}- D-4 supersedes D-1"
set_record bbbb2222 "$LIST2"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=agent-1)"
assert_eq "$HEAD_LINE${NL}This list is new or changed since you last saw it, and replaces any earlier copy.${NL}${NL}$LIST2" \
  "$(ctx "$OUT")" "after a change the running agent is handed the new list"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=agent-1)"
assert_eq "0|" "$RC|$OUT" "and only once"
run "$PUSH" "$REPO" "$(payload PreToolUse session_id=sess-main)"
assert_contains "$(ctx "$OUT")" "D-4 supersedes D-1" "the main session is handed the change too"
run "$PUSH" "$REPO" "$(payload PreToolUse session_id=sess-main)"
assert_eq "0|" "$RC|$OUT" "and only once"
# Parallel tool calls of one agent race on the same version: exactly one pushes.
set_record cccc3333 "# In force${NL}${NL}- D-5 raced"
for i in 1 2 3 4 5 6 7 8; do
  (cd "$WT" && payload PreToolUse agent_id=racer | CLAUDE_PROJECT_DIR="$WT" sh -c "$PUSH" > "$WORK/race.$i" 2>/dev/null) &
done
wait
RACED=0
for i in 1 2 3 4 5 6 7 8; do [ -s "$WORK/race.$i" ] && RACED=$((RACED + 1)); done
assert_eq "1" "$RACED" "eight parallel tool calls of one agent push the change exactly once"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=bystander)"
assert_contains "$(ctx "$OUT")" "D-5 raced" "agents are keyed apart: another agent still gets it"
# A version file that is missing or unusable: the list is still pushed, once per agent,
# under a fixed version. Versioning it by its checksum instead read the whole list on
# every tool call, so no call may run cksum (a stand-in on PATH counts the runs).
rm -f "$REC/in-force.sha"
mkdir -p "$WORK/count"
printf '#!/bin/sh\necho run >> "%s"\nexec %s "$@"\n' "$WORK/cksum.runs" "$(command -v cksum)" > "$WORK/count/cksum"
chmod +x "$WORK/count/cksum"
: > "$WORK/cksum.runs"
HOOK_PATH="$WORK/count:$PATH" run "$PUSH" "$WT" "$(payload PreToolUse agent_id=no-sha)"
assert_contains "$(ctx "$OUT")" "D-5 raced" "without in-force.sha the list is still pushed"
HOOK_PATH="$WORK/count:$PATH" run "$PUSH" "$WT" "$(payload PreToolUse agent_id=no-sha)"
assert_eq "0|" "$RC|$OUT" "and only once"
printf '# In force\n\n- D-5 raced\n- D-5b added by hand\n' > "$REC/in-force.md"
HOOK_PATH="$WORK/count:$PATH" run "$PUSH" "$WT" "$(payload PreToolUse agent_id=no-sha)"
assert_eq "0|" "$RC|$OUT" "a hand edit with no version reaches a running agent only once the helper writes one"
HOOK_PATH="$WORK/count:$PATH" run "$PUSH" "$WT" "$(payload PreToolUse agent_id=no-sha-new)"
assert_contains "$(ctx "$OUT")" "D-5b added by hand" "while an agent that never saw the list is handed it as it is"
printf 'not-a-sha!\n' > "$REC/in-force.sha"
HOOK_PATH="$WORK/count:$PATH" run "$PUSH" "$WT" "$(payload PreToolUse agent_id=no-sha)"
assert_eq "0|" "$RC|$OUT" "an unusable in-force.sha reads like a missing one"
assert_eq "0" "$(grep -c run "$WORK/cksum.runs" || true)" "and no tool call read the list to version it"
set_record cccc3334 "# In force${NL}${NL}- D-5 raced${NL}- D-5b added by hand"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=no-sha)"
assert_contains "$(ctx "$OUT")" "D-5b added by hand" "once a version is written, the running agent is handed the list"

echo ""
echo "[ids]"
set_record dddd4444 "# In force${NL}${NL}- D-6 ids"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=../../escape)"
assert_eq "0|" "$RC|$OUT" "an id that is not a plain name is not used: no push"
assert_cmd_fails "ls -d '$REPO/.git/escape'* '$REC/escape'* 2>/dev/null | grep -q ." "and no marker is made anywhere for it"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=.hidden)"
assert_eq "0|" "$RC|$OUT" "an id starting with a dot is not used"
# A word in a tool's input is not the id. Named once as a value, it is no key at all.
run "$PUSH" "$REPO" "$(payload PreToolUse session_id=sess-grep tool_name=Grep tool_input='{"pattern":"agent_id"}')"
assert_eq "0" "$RC" "a tool input naming agent_id as a value exits 0"
if command -v jq >/dev/null 2>&1; then
  # Named twice, as a key, the top-level one is read through jq.
  run "$PUSH" "$WT" "$(payload PreToolUse agent_id=real-agent tool_name=mcp__x__y tool_input='{"agent_id":"nested"}')"
  assert_contains "$(ctx "$OUT")" "D-6 ids" "a key the tool input repeats is read at the top level"
  assert_dir_exists "$REC/seen/real-agent.dddd4444" "and the marker carries the top-level id"
  assert_dir_not_exists "$REC/seen/nested.dddd4444" "not the tool input's"
fi
# Without jq the ordinary path is unchanged, and an ambiguous id reads as absent.
mkdir -p "$WORK/nojq"
for b in sh cat awk mkdir find cksum rmdir; do ln -sf "$(command -v "$b")" "$WORK/nojq/$b"; done
HOOK_PATH="$WORK/nojq" run "$PUSH" "$WT" "$(payload PreToolUse agent_id=nojq-agent)"
assert_contains "$(ctx "$OUT")" "D-6 ids" "without jq on PATH the push still works"
HOOK_PATH="$WORK/nojq" run "$PUSH" "$WT" "$(payload PreToolUse agent_id=nojq-twice tool_input='{"agent_id":"nested"}')"
assert_eq "0|" "$RC|$OUT" "without jq an ambiguous id is not guessed at"
HOOK_PATH="$WORK/nojq" run "$INJECT_SA" "$WT" "$(payload SubagentStart agent_id=nojq-sub agent_type=Plan)"
assert_contains "$(ctx "$OUT")" "D-6 ids" "without jq on PATH injection still works"

# ── links planted in the record are not followed ────────────────────────────
echo ""
echo "[planted links]"
# These hooks run outside the sandbox, and an agent inside it can write .git/. A link in
# the record must not turn that into a write somewhere the sandbox forbids, nor let a
# tracked file speak as the user.
printf 'keep\n' > "$WORK/outside.txt"
ln -s "$WORK/outside.txt" "$REC/seen/evil.dddd4444"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=evil)"
assert_eq "0|" "$RC|$OUT" "a marker name planted as a link to a file: no push"
assert_eq "keep" "$(cat "$WORK/outside.txt")" "and the file it points to is untouched"
mv "$REC/seen" "$WORK/seen-real"
mkdir -p "$WORK/outside-dir"
ln -s "$WORK/outside-dir" "$REC/seen"
run "$PUSH" "$WT" "$(payload PreToolUse agent_id=via-link)"
assert_eq "0|" "$RC|$OUT" "a seen directory planted as a link: no push"
run "$INJECT_SA" "$WT" "$(payload SubagentStart agent_id=via-link2 agent_type=Explore)"
assert_contains "$(ctx "$OUT")" "D-6 ids" "injection still delivers the list"
assert_eq "" "$(ls -A "$WORK/outside-dir")" "and nothing is written through the link"
rm -f "$REC/seen"
mv "$WORK/seen-real" "$REC/seen"
cp "$REC/in-force.md" "$WORK/tracked.md"
mv "$REC/in-force.md" "$WORK/in-force.real"
ln -s "$WORK/tracked.md" "$REC/in-force.md"
run "$INJECT_SS" "$REPO" "$(payload SessionStart source=startup)"
assert_eq "0|" "$RC|$OUT" "an in-force list that is a link is refused"
rm -f "$REC/in-force.md"
mv "$WORK/in-force.real" "$REC/in-force.md"
mv "$REC" "$WORK/decisions-real"
ln -s "$WORK/decisions-real" "$REC"
run "$INJECT_SS" "$REPO" "$(payload SessionStart source=startup)"
assert_eq "0|" "$RC|$OUT" "a record directory that is a link is refused"
rm -f "$REC"
mv "$WORK/decisions-real" "$REC"

# ── the 10,000-character cap ────────────────────────────────────────────────
echo ""
echo "[size]"
python3 - "$REC" <<'PY'
import os, sys
rec = sys.argv[1]
lines = ["# In force", ""] + ["- D-%03d a decision long enough to fill the list quickly, café" % i for i in range(400)]
open(os.path.join(rec, "in-force.md"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
open(os.path.join(rec, "in-force.sha"), "w").write("eeee5555  in-force.md\n")
PY
run "$INJECT_SA" "$WT" "$(payload SubagentStart agent_id=big agent_type=Explore)"
BIG="$(ctx "$OUT")"
SIZE_OK="$(printf '%s' "$BIG" | python3 -c '
import os, re, sys
text = sys.stdin.read()
body = open(sys.argv[1], encoding="utf-8").read().split("\n")
kept = text.split("\n")[2:]
note = [l for l in kept if l.startswith("The list is longer than fits here")]
lines = [l for l in kept if l and not l.startswith("The list is longer")]
named = re.search(r"The rest is in (.+): read it before deciding\.$", note[0]) if note else None
problems = []
if len(text) >= 10000: problems.append("length %d" % len(text))
if not named: problems.append("no note naming a file")
elif not os.path.exists(named.group(1)) or not os.path.samefile(named.group(1), sys.argv[1]):
    problems.append("note names %s" % named.group(1))
elif "/../" in named.group(1): problems.append("path not plain: %s" % named.group(1))
if not all(l in body for l in lines): problems.append("a line was cut mid-way")
if len(lines) <= 50: problems.append("only %d lines kept" % len(lines))
print("; ".join(problems) or "yes")' "$REC/in-force.md")"
assert_eq "yes" "$SIZE_OK" "a list past the cap is cut at a line under 10,000 characters, with a note naming the file plainly"

# ── a decision hook can never block ─────────────────────────────────────────
echo ""
echo "[never blocks]"
# Whatever a decision hook's script does, its registration exits 0: a hook that only adds
# context, or checks a report, must not be able to block a tool call or fail a session.
mkdir -p "$WORK/broken/.claude/hooks"
for f in decisions-inject.sh decisions-push.sh decisions-report-check.sh; do
  printf 'echo half-written >&2\nif then\nexit 2\n' > "$WORK/broken/.claude/hooks/$f"
done
for pair in "SessionStart|$INJECT_SS" "SubagentStart|$INJECT_SA" "PreToolUse|$PUSH" "SubagentStop|$CHECK"; do
  run "${pair#*|}" "$WORK/broken" "$(payload "${pair%%|*}" agent_id=x agent_type=anchor-engineer)"
  assert_eq "0" "$RC" "${pair%%|*}: a script with a syntax error still exits 0 through its registration"
done
for f in decisions-inject.sh decisions-push.sh decisions-report-check.sh; do
  printf 'exit 2\n' > "$WORK/broken/.claude/hooks/$f"
done
for pair in "SessionStart|$INJECT_SS" "SubagentStart|$INJECT_SA" "PreToolUse|$PUSH" "SubagentStop|$CHECK"; do
  run "${pair#*|}" "$WORK/broken" "$(payload "${pair%%|*}")"
  assert_eq "0" "$RC" "${pair%%|*}: a script that exits 2 still exits 0 through its registration"
done
mkdir -p "$WORK/no-scripts"
run "$PUSH" "$WORK/no-scripts" "$(payload PreToolUse)"
assert_eq "0|" "$RC|$OUT$ERR" "a project without the scripts runs nothing and exits 0"

# ── the plugin copy ─────────────────────────────────────────────────────────
echo ""
echo "[plugin]"
# A plugin-only project: no .claude/hooks of its own, so the plugin's copy runs.
mkdir -p "$WORK/plugin-only"
(cd "$WORK/plugin-only" && git init -q) > "$QUIET_LOG" 2>&1 || quiet_fail "plugin fixture"
mkdir -p "$WORK/plugin-only/.git/decisions"
printf '# In force\n\n- P-1 plugin\n' > "$WORK/plugin-only/.git/decisions/in-force.md"
printf 'ffff6666\n' > "$WORK/plugin-only/.git/decisions/in-force.sha"
HOOK_PLUGIN_ROOT="$REPO_ROOT/plugin" run "$P_INJECT" "$WORK/plugin-only" "$(payload SubagentStart agent_id=pa agent_type=Explore)"
assert_contains "$(ctx "$OUT")" "P-1 plugin" "the plugin's copy injects in a plugin-only project"
# Next to a full install, which registers its own copy, the plugin's copy stays out.
HOOK_PLUGIN_ROOT="$REPO_ROOT/plugin" run "$P_INJECT" "$WT" "$(payload SubagentStart agent_id=pb agent_type=Explore)"
assert_eq "0|" "$RC|$OUT" "the plugin's copy is silent next to a full install"

# ── the report check ────────────────────────────────────────────────────────
echo ""
echo "[report check]"
FULL="Added the vault instruction.${NL}${NL}**Verified:** anchor test, 14 passing${NL}- **Decisions made:** none${NL}## Decisions needed${NL}1. Assumptions — devnet is reachable${NL}| Next owner | solana-qa-engineer |"
stop() {  # stop <agent_type> <last message> [extra key=value ...]
  local t="$1" m="$2"; shift 2
  payload SubagentStop agent_id=ag-stop agent_type="$t" stop_hook_active=false \
    agent_transcript_path=/dev/null last_assistant_message="$m" "$@"
}
decision() {
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw:
    print("silent"); raise SystemExit
try:
    d = json.loads(raw)
except ValueError:
    print("INVALID"); raise SystemExit
print("%s|%s" % (d.get("decision"), d.get("reason", "")))'
}
run "$CHECK" "$REPO" "$(stop anchor-engineer "$FULL")"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "a report carrying all five parts passes: bold, bullets, headings, numbering, tables, dashes"
run "$CHECK" "$REPO" "$(stop anchor-engineer "Done. Tests pass.${NL}Verified: cargo test${NL}Next owner: the lead")"
D="$(decision "$OUT")"
assert_eq "block" "${D%%|*}" "a report missing parts is sent back"
assert_contains "$D" "missing: Decisions made, Decisions needed, Assumptions." "the reason names exactly what is missing"
assert_contains "$D" "write none where there is nothing to say" "the reason says none is an answer"
run "$CHECK" "$REPO" "$(stop anchor-engineer "All done.${NL}Next, I ran the tests and they pass.")"
assert_contains "$(decision "$OUT")" "missing: Verified, Decisions made, Decisions needed, Assumptions, Next owner." \
  "prose that starts with a label word is not a label"
# A few words between a label and its colon, dash or bar still make the label: the
# phrasings agents reach for. A heading or a wholly bold line needs no colon.
NATURAL="Done.${NL}Verified by running anchor test: 14 passing${NL}Decisions I made: none${NL}Decisions needed from you: none${NL}Assumptions made: devnet is reachable${NL}Hand off to: solana-qa-engineer"
run "$CHECK" "$REPO" "$(stop anchor-engineer "$NATURAL")"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "natural phrasings pass: Verified by running ...:, Decisions needed from you:, Assumptions made:, Hand off to:"
NATURAL2="Done.${NL}Verified that the tests pass: cargo test, 3 passing${NL}Decisions made so far: none${NL}Decisions needed from the user - none${NL}Assumptions I made: none${NL}Next owner after review | the lead"
run "$CHECK" "$REPO" "$(stop anchor-engineer "$NATURAL2")"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "and with a dash or a table bar after the words"
HEADINGS="Done.${NL}## Verified by running the suite${NL}cargo test, 3 passing${NL}**Decisions made so far**${NL}none${NL}## Decisions needed from you${NL}none${NL}### Assumptions made${NL}none${NL}## Next owner${NL}the lead"
run "$CHECK" "$REPO" "$(stop anchor-engineer "$HEADINGS")"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "a heading, or a line wholly in bold, is a label without a colon"
# Strict where it matters: a sentence is not a label, however it opens.
PROSE="Verified the build works and the tests pass.${NL}Decided to keep the existing seeds.${NL}Decisions needed none really.${NL}Assumed devnet is reachable.${NL}Next the QA engineer should run the fuzz pass."
run "$CHECK" "$REPO" "$(stop anchor-engineer "$PROSE")"
assert_contains "$(decision "$OUT")" "missing: Verified, Decisions made, Decisions needed, Assumptions, Next owner." \
  "sentences that open with a label word, with no colon, dash or bar after it, are prose"
CLOSE="Verified the build, then ran: cargo test${NL}Decisions made: none${NL}Decisions needed: none${NL}Assumptions about the network that I could not check in time: none${NL}Nextjs upgrade: done"
run "$CHECK" "$REPO" "$(stop anchor-engineer "$CLOSE")"
assert_contains "$(decision "$OUT")" "missing: Verified, Assumptions, Next owner." \
  "a comma before the colon, more than eight words, or a longer word is not a label"
run "$CHECK" "$REPO" "$(stop anchor-engineer "All done." stop_hook_active=true)"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "once only: stop_hook_active lets the agent stop"
run "$CHECK" "$REPO" "$(stop solana-ai-kit:solana-qa-engineer "All done.")"
assert_eq "block" "$(decision "$OUT" | cut -d'|' -f1)" "a plugin-scoped kit agent is held to the contract"
for t in "" general-purpose Explore Plan my-reviewer claude-code-guide "x:solana-ai-kit:anchor-engineer" "solana-ai-kit:other"; do
  run "$CHECK" "$REPO" "$(stop "$t" "All done.")"
  assert_eq "0|silent" "$RC|$(decision "$OUT")" "not a kit agent, not checked: '${t:-internal, empty agent_type}'"
done
run "$CHECK" "$REPO" "$(stop anchor-engineer "All done." agent_id=-)"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "a payload naming no agent_id is not a subagent this can name: not checked"
run "$CHECK" "$REPO" "$(stop anchor-engineer '{"findings": [], "ok": true}')"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "a JSON return value (a workflow agent's schema) is not checked"
run "$CHECK" "$REPO" "$(stop anchor-engineer "")"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "nothing to read: not checked"
# A dash escaped as —, as some JSON writers do, still ends a label.
ESCAPED="$(python3 -c '
import json
m = "Verified — ran it\nDecisions made — none\nDecisions needed — none\nAssumptions — none\nNext owner — lead"
print(json.dumps({"hook_event_name": "SubagentStop", "agent_id": "a", "agent_type": "token-engineer", "stop_hook_active": False, "last_assistant_message": m}))')"
run "$CHECK" "$REPO" "$ESCAPED"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "a dash escaped as \\u2014 still ends a label"

# In auto mode the report is the SubagentHandback message, read from the agent's transcript.
python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
full = ("Report.\nVerified: cargo test, 3 passing\nDecisions made: none\nDecisions needed: none\n"
        "Assumptions: none\nNext owner: the lead")
def handback(msg):
    return json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "Calling \"SubagentHandback\" next"},
        {"type": "tool_use", "id": "toolu_9", "name": "SubagentHandback", "input": {"message": msg}}]}},
        ensure_ascii=False)
user = json.dumps({"type": "user", "message": {"role": "user", "content": "go"}})
result = json.dumps({"type": "user", "message": {"content": [
    {"type": "tool_result", "tool_use_id": "toolu_9", "content": "delivered"}]}})
open(os.path.join(work, "t-full.jsonl"), "w").write("\n".join([user, handback(full), result]) + "\n")
open(os.path.join(work, "t-thin.jsonl"), "w").write("\n".join([user, handback("Report.\nVerified: it works")]) + "\n")
open(os.path.join(work, "t-none.jsonl"), "w").write(user + "\n")
PY
run "$CHECK" "$REPO" "$(stop anchor-engineer "Done." agent_transcript_path="$WORK/t-full.jsonl")"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "a complete SubagentHandback report passes, though the closing text is bare"
run "$CHECK" "$REPO" "$(stop anchor-engineer "$FULL" agent_transcript_path="$WORK/t-thin.jsonl")"
assert_contains "$(decision "$OUT")" "missing: Decisions made, Decisions needed, Assumptions, Next owner." \
  "a thin handback is sent back, whatever the closing text says"
run "$CHECK" "$REPO" "$(stop anchor-engineer "$FULL" agent_transcript_path="$WORK/t-none.jsonl")"
assert_eq "0|silent" "$RC|$(decision "$OUT")" "no handback in the transcript: the final message is the report"
HOOK_PATH="$WORK/nojq" run "$CHECK" "$REPO" "$(stop anchor-engineer "All done.")"
assert_eq "block" "$(decision "$OUT" | cut -d'|' -f1)" "without jq on PATH the check still runs"
for shx in sh dash; do
  command -v "$shx" >/dev/null 2>&1 || continue
  OUT="$(stop anchor-engineer "Done." agent_transcript_path="$WORK/t-thin.jsonl" | "$shx" "$HOOKS_SRC/decisions-report-check.sh" 2>/dev/null)"
  assert_contains "$(decision "$OUT")" "missing: Decisions made" "$shx runs the check the same way"
  OUT="$(cd "$WT" && payload PreToolUse agent_id="shell-$shx" | CLAUDE_PROJECT_DIR="$WT" "$shx" "$HOOKS_SRC/decisions-push.sh" 2>/dev/null)"
  assert_contains "$(ctx "$OUT")" "D-" "$shx runs the push the same way"
done

# ── controls: each mechanism planted back out must change the verdict ────────
echo ""
echo "[controls]"
# mutant <name> <script> <find> <replace> — a project inside the fixture repository whose
# copy of <script> has <find> replaced. Prints nothing when <find> is gone, so the
# control fails and says the mechanism moved.
mutant() {
  local dir="$REPO/mut-$1"
  mkdir -p "$dir/.claude/hooks"
  cp "$HOOKS_SRC"/decisions-*.sh "$dir/.claude/hooks/"
  python3 - "$dir/.claude/hooks/$2" "$3" "$4" <<'PY' && printf '%s' "$dir"
import sys
path, find, repl = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if find not in text:
    sys.exit(1)
open(path, "w", encoding="utf-8").write(text.replace(find, repl))
PY
}
# control <label> <expected-from-original> <got-from-mutant>
control() {
  TOTAL=$((TOTAL + 1))
  if [ -n "$3" ] && [ "$2" != "$3" ]; then
    echo "  PASS: planted failure caught ($1: $2 -> $3)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: planted failure NOT caught ($1 still ${3:-unbuilt})"
    FAIL=$((FAIL + 1))
  fi
}
MUT="$(mutant once decisions-report-check.sh "*'\"stop_hook_active\":true'*" "*'\"no_such_key\":true'*")" || MUT=
GOT=; [ -z "$MUT" ] || { run "$CHECK" "$MUT" "$(stop anchor-engineer "All done." stop_hook_active=true)"; GOT="$(decision "$OUT" | cut -d'|' -f1)"; }
control "stop_hook_active" silent "$GOT"
MUT="$(mutant link decisions-inject.sh '[ ! -L "$R/in-force.md" ]' ':')" || MUT=
GOT=
if [ -n "$MUT" ]; then
  mv "$REC/in-force.md" "$WORK/in-force.real" && cp "$WORK/in-force.real" "$WORK/tracked.md"
  ln -s "$WORK/tracked.md" "$REC/in-force.md"
  run "$INJECT_SS" "$MUT" "$(payload SessionStart source=startup)"
  [ -n "$OUT" ] && GOT=emits || GOT=silent
  rm -f "$REC/in-force.md" && mv "$WORK/in-force.real" "$REC/in-force.md"
fi
control "a linked in-force list" silent "$GOT"
MUT="$(mutant cap decisions-inject.sh '<= 9000' '<= 30000')" || MUT=
GOT=; [ -z "$MUT" ] || { run "$INJECT_SA" "$MUT" "$(payload SubagentStart agent_id=big2 agent_type=Explore)"; GOT="$(ctx "$OUT" | python3 -c 'import sys; print("over" if len(sys.stdin.read()) >= 10000 else "under")')"; }
control "the 10,000-character cap" under "$GOT"
# The registration, not the script, is what keeps a failure from blocking: an `exec`
# there hands the script's exit 2 straight to Claude Code.
for f in decisions-inject.sh decisions-push.sh decisions-report-check.sh; do printf 'exit 2\n' > "$WORK/broken/.claude/hooks/$f"; done
run "$(printf '%s' "$PUSH" | sed 's/&& sh /\&\& exec sh /')" "$WORK/broken" "$(payload PreToolUse)"
control "a registration that execs" 0 "$RC"

print_summary
