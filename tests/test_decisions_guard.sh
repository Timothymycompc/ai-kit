#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# decisions-guard.sh, replayed the way Claude Code runs it: the command registered in
# settings.json, under `sh -c`, with the payload on stdin. Whatever the decision record
# holds is handed to every agent as the user's decision, so only the user's main session
# writes it. A subagent's payload carries agent_id; the guard refuses it `decisions.sh add`
# and `supersede`, and any file tool aimed into the record directory. The main session,
# the helper's readers, reading the record and every mere mention of the helper pass.
#
# Nothing here runs the helper or writes an entry: the guard decides on the command text
# and on the path, so every case is a payload. Git runs only inside the temp directory,
# under GIT_CEILING_DIRECTORIES, so no step can reach a real repository's record.

echo "[test_decisions_guard] Only the main session writes the decision record"
echo ""

WORK="$(new_tmp)" || exit 1
trap 'rm -rf "$WORK"' EXIT
export GIT_CEILING_DIRECTORIES="$WORK"
SETTINGS="$REPO_ROOT/.claude/settings.json"
PLUGIN_HOOKS="$REPO_ROOT/plugin/hooks/hooks.json"
HOOKS_SRC="$REPO_ROOT/.claude/hooks"
NL='
'

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
GUARD="$(reg "$SETTINGS" PreToolUse decisions-guard.sh)"
P_GUARD="$(reg "$PLUGIN_HOOKS" PreToolUse decisions-guard.sh)"
for pair in "settings.json|$GUARD" "plugin hooks.json|$P_GUARD"; do
  TOTAL=$((TOTAL + 1))
  if [ -n "${pair#*|}" ]; then
    echo "  PASS: ${pair%%|*} registers the guard on PreToolUse"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${pair%%|*} registers no decisions guard, so this suite proves nothing there"
    FAIL=$((FAIL + 1))
  fi
done

# ── fixture: a repository with a space in its path, a linked worktree, hooks in both ──
REPO="$WORK/a repo"
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
  cp "$HOOKS_SRC"/* "$d/.claude/hooks/"
done
REC="$REPO/.git/decisions"
mkdir -p "$REC"

# payload <tool> <tool_input json> [agent_id] — a payload as Claude Code sends it.
payload() {
  python3 - "$@" <<'PY'
import json, sys
tool, tin = sys.argv[1], json.loads(sys.argv[2])
agent = sys.argv[3] if len(sys.argv) > 3 else ""
d = {"session_id": "sess-main", "transcript_path": "/dev/null", "cwd": "/tmp",
     "permission_mode": "default", "hook_event_name": "PreToolUse",
     "tool_name": tool, "tool_input": tin, "tool_use_id": "toolu_1"}
if agent:
    d["agent_id"] = agent
    d["agent_type"] = "general-purpose"
print(json.dumps(d, ensure_ascii=False, separators=(",", ":")))
PY
}
cmd_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1]}))' "$1"; }
file_input() { python3 -c 'import json, sys; print(json.dumps({sys.argv[1]: sys.argv[2], "content": "x"}))' "${2:-file_path}" "$1"; }

# run <hook command> <project dir> <payload> — sets RC, OUT and ERR.
run() {
  set +e
  OUT="$(cd "$2" && printf '%s' "$3" | PATH="${HOOK_PATH:-$PATH}" CLAUDE_PROJECT_DIR="$2" \
    CLAUDE_PLUGIN_ROOT="${HOOK_PLUGIN_ROOT:-$REPO_ROOT/plugin}" sh -c "$1" 2>"$WORK/err")"
  RC=$?
  set -e
  ERR="$(cat "$WORK/err")"
}
# verdict — deny (exit 2 with a deny decision), silent (exit 0, no output), or what it did.
verdict() {
  if [ "$RC" = 2 ] && grep -q '"permissionDecision":"deny"' <<<"$OUT"; then
    echo deny
  elif [ "$RC" = 0 ] && [ -z "$OUT$ERR" ]; then
    echo silent
  else
    echo "rc=$RC out=${OUT:0:80} err=${ERR:0:80}"
  fi
}
# bash_as <agent or ""> <command> [project] / edit_as <agent or ""> <tool> <path> [project] [key]
bash_as() { run "$GUARD" "${3:-$REPO}" "$(payload Bash "$(cmd_input "$2")" "$1")"; verdict; }
edit_as() { run "$GUARD" "${4:-$REPO}" "$(payload "$2" "$(file_input "$3" "${5:-file_path}")" "$1")"; verdict; }

# ── the script ──────────────────────────────────────────────────────────────
echo "[script]"
assert_cmd_success "sh -n '$HOOKS_SRC/decisions-guard.sh'" "decisions-guard.sh parses with sh -n"
if command -v dash >/dev/null 2>&1; then
  assert_cmd_success "dash -n '$HOOKS_SRC/decisions-guard.sh'" "decisions-guard.sh parses with dash -n"
fi
assert_cmd_success "[ -x '$HOOKS_SRC/decisions-guard.sh' ]" "decisions-guard.sh is executable"
assert_file_exists "$HOOKS_SRC/decisions-guard.awk" "its awk pass ships beside it"
# The guard finds the record the way the two record hooks do, through copies of their
# functions. A copy is code that drifts, so the copies must match byte for byte.
fn() { awk -v f="$1" '$0 ~ "^" f "\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$2"; }
for f in json_str common_dir; do
  ORIG="$(fn "$f" "$HOOKS_SRC/decisions-inject.sh")"
  assert_eq "yes" "$([ -n "$ORIG" ] && echo yes || echo no)" "decisions-inject.sh defines $f()"
  assert_eq "$ORIG" "$(fn "$f" "$HOOKS_SRC/decisions-guard.sh")" "$f() is identical in decisions-guard.sh and decisions-inject.sh"
done

# ── the main session writes ─────────────────────────────────────────────────
echo ""
echo "[the main session]"
ADD="bash .claude/bin/decisions.sh add --kind decision --question 'Which cluster?' --decision 'devnet' --words 'use devnet'"
assert_eq "silent" "$(bash_as "" "$ADD")" "the main session runs decisions.sh add"
assert_eq "silent" "$(bash_as "" "bash .claude/bin/decisions.sh supersede D-2026-10-20-x --decision d --words w")" \
  "the main session runs decisions.sh supersede"
assert_eq "silent" "$(edit_as "" Write "$REC/D-2026-10-20-x.md")" "the main session's file tools reach the record"
# Nothing but the payload read: the main session's every call passes on builtins alone.
mkdir -p "$WORK/bare"
for b in sh cat; do ln -sf "$(command -v "$b")" "$WORK/bare/$b"; done
HOOK_PATH="$WORK/bare"
assert_eq "silent" "$(bash_as "" "$ADD")" "the main session's path needs nothing but sh and cat"
assert_eq "silent" "$(bash_as agent-1 "cargo test --workspace")" "a subagent's call that never names the helper: sh and cat only"
assert_eq "silent" "$(edit_as agent-1 Write "$REPO/src/lib.rs")" "a subagent's edit outside the record: sh and cat only"
unset HOOK_PATH

# ── a subagent runs the helper's write commands ─────────────────────────────
echo ""
echo "[subagent: the helper's write commands]"
DENY_CMDS=(
  "$ADD"
  "bash .claude/bin/decisions.sh supersede D-2026-10-20-x --decision d --words w --by you"
  "sh .claude/bin/decisions.sh add --kind principle --decision d --words w"
  ".claude/bin/decisions.sh add --kind decision --question q --decision d --words w"
  "./.claude/bin/decisions.sh supersede D-1 --decision d --words w"
  "\"\$CLAUDE_PROJECT_DIR\"/.claude/bin/decisions.sh add --kind D --question q --decision d --words w"
  "bash /abs/path/.agents/bin/decisions.sh add --kind D --question q --decision d --words w"
  "cd /tmp/x && bash .claude/bin/decisions.sh add --kind D --question q --decision d --words w"
  "DECISIONS_DATE=2026-10-01 bash .claude/bin/decisions.sh add --kind D --question q --decision d --words w"
  "env DECISIONS_DATE=2026-10-01 nohup bash .claude/bin/decisions.sh add --question q"
  "timeout 30 bash -x .claude/bin/decisions.sh add --question q"
  "bash .claude/bin/decisions.sh \"supersede\" D-1 --decision d --words w"
  "bash -c 'bash .claude/bin/decisions.sh add --kind D --question q --decision d --words w'"
  "eval \"bash .claude/bin/decisions.sh supersede D-1 --decision d --words w\""
  "if true; then bash .claude/bin/decisions.sh add --question q; fi"
  "ID=\$(bash .claude/bin/decisions.sh add --kind D --question q --decision d --words w)"
  "printf 'decision: d\\nwords: w\\n' | bash .claude/bin/decisions.sh add --kind D --question q --stdin"
  "source .claude/bin/decisions.sh add --question q"
  "bash .claude/bin/DECISIONS.SH add --question q"
  "bash .claude/bin/decisions.sh add --kind D --question q --stdin <<'DECISION_END'${NL}decision: d${NL}words: w${NL}DECISION_END"
  # A heredoc a shell or an interpreter runs is code, quoted delimiter or not.
  "sh -s <<'EOF'${NL}bash .claude/bin/decisions.sh add --kind D --question q --decision d --words w${NL}EOF"
  "python3 - <<'PY'${NL}import os${NL}os.system(\"bash .claude/bin/decisions.sh add --kind D --question q --decision d --words w\")${NL}PY"
)
for c in "${DENY_CMDS[@]}"; do
  assert_eq "deny" "$(bash_as agent-1 "$c")" "refused: ${c//$NL/\\n}"
done
# A linked worktree's subagent is the same agent as far as the record goes.
assert_eq "deny" "$(bash_as agent-wt "$ADD" "$WT")" "refused from a linked worktree too"

# ── what a subagent may still do ────────────────────────────────────────────
echo ""
echo "[subagent: the readers, and mentions]"
ALLOW_CMDS=(
  "bash .claude/bin/decisions.sh in-force"
  "bash .claude/bin/decisions.sh hash"
  "bash .claude/bin/decisions.sh export --handoff"
  "bash .claude/bin/decisions.sh path"
  "bash .claude/bin/decisions.sh help"
  "bash .claude/bin/decisions.sh"
  "cat \"\$(git rev-parse --git-common-dir)/decisions/in-force.md\""
  "grep -rn 'decisions.sh add' .claude/commands/"
  "rg -n \"decisions.sh supersede\" docs/"
  "git commit -m 'docs: the main session runs bash .claude/bin/decisions.sh add'"
  "echo 'bash .claude/bin/decisions.sh add --kind D'"
  "echo run .claude/bin/decisions.sh add from the main session"
  "cat > notes.md <<'EOF'${NL}bash .claude/bin/decisions.sh add --kind D${NL}EOF"
  "python3 - <<'PY'${NL}print(\"the main session runs bash .claude/bin/decisions.sh add\")${NL}PY"
  "bash tests/test_decisions.sh"
  "sed -n 1,40p .claude/bin/decisions.sh"
  "shellcheck .claude/bin/decisions.sh"
)
for c in "${ALLOW_CMDS[@]}"; do
  assert_eq "silent" "$(bash_as agent-1 "$c")" "passes: ${c//$NL/\\n}"
done

# ── a subagent aims a file tool into the record ─────────────────────────────
echo ""
echo "[subagent: file tools]"
for t in Write Edit MultiEdit; do
  assert_eq "deny" "$(edit_as agent-1 "$t" "$REC/D-2026-10-20-x.md")" "$t into the record is refused"
done
assert_eq "deny" "$(edit_as agent-1 NotebookEdit "$REC/notes.ipynb" "" notebook_path)" "NotebookEdit into the record is refused"
assert_eq "deny" "$(edit_as agent-1 Write "$REC/in-force.md")" "the in-force list itself is refused"
assert_eq "deny" "$(edit_as agent-1 Write "$REC/seen/agent-1.abc/x")" "so is the hooks' own state under seen/"
assert_eq "deny" "$(edit_as agent-wt Write "$REC/D-x.md" "$WT")" "from a linked worktree, the shared record is the same record"
assert_eq "deny" "$(edit_as agent-1 Write "$REPO/.git/worktrees/wt/../../decisions/D-x.md")" "a path with .. is folded before it is compared"
assert_eq "deny" "$(edit_as agent-1 Write "$REPO/./.git//decisions/D-x.md")" "so are . and doubled slashes"
ln -s "$REPO" "$WORK/alias"
assert_eq "deny" "$(edit_as agent-1 Write "$WORK/alias/.git/decisions/D-x.md")" "a path through a linked directory is resolved first"
# Resolved before the path is looked at, so a link into the record is the record
# whatever the link is named: to the directory, to a file inside it, or a chain.
mkdir -p "$WORK/links" "$REPO/src"
ln -s "$REC" "$WORK/links/rec"
ln -s "../a repo/.git/decisions" "$WORK/links/rel"
ln -s "$REC/in-force.md" "$WORK/links/list"
ln -s "$WORK/links/list" "$WORK/links/list2"
ln -s "$REPO/src" "$WORK/links/code"
assert_eq "deny" "$(edit_as agent-1 Write "$WORK/links/rec/D-x.md")" "a link to the record named without 'decisions' is the record"
assert_eq "deny" "$(edit_as agent-1 Write "$WORK/links/rel/D-x.md")" "so is a relative one"
assert_eq "deny" "$(edit_as agent-1 Edit "$WORK/links/list")" "a link to a file inside the record is that file"
assert_eq "deny" "$(edit_as agent-1 Write "$WORK/links/list2")" "a chain of links is followed to its end"
assert_eq "silent" "$(edit_as agent-1 Write "$WORK/links/code/lib.rs")" "a link that leads elsewhere passes"
assert_eq "deny" "$(edit_as agent-1 Write "$REPO/.git/DECISIONS/D-x.md")" "case is folded: a filesystem that folds it opens the record either way"
assert_eq "deny" "$(edit_as agent-1 Write ".git/decisions/D-x.md")" "a relative path is taken from the session's directory"
rmdir "$REC"
assert_eq "deny" "$(edit_as agent-1 Write "$REC/D-x.md")" "a record not created yet is refused too"
assert_dir_not_exists "$REC" "and the guard created nothing"
mkdir -p "$REC"
# Text that names a key is not the key: a content string carries its quotes escaped.
CONTENT_FIRST="$(python3 -c 'import json, sys; print(json.dumps({"content": "{\"file_path\": \"%s/D-x.md\"}" % sys.argv[1], "file_path": sys.argv[2]}))' "$REC" "$REPO/notes.json")"
run "$GUARD" "$REPO" "$(payload Write "$CONTENT_FIRST" agent-1)"
assert_eq "silent" "$(verdict)" "a file_path named inside the content is not the target"
QUOTED="$(python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1] + "/D-\"q\".md", "content": "x"}))' "$REC")"
run "$GUARD" "$REPO" "$(payload Write "$QUOTED" agent-1)"
assert_eq "deny" "$(verdict)" "a target whose path carries a JSON escape is decoded, then refused"
for p in "$REPO/docs/decisions.md" "$REPO/.claude/bin/decisions.sh" "$REPO/tests/test_decisions.sh" \
         "$REPO/.git/decisions-old/D-x.md" "$REPO/.git/config" "$WORK/elsewhere/decisions/D-x.md"; do
  assert_eq "silent" "$(edit_as agent-1 Write "$p")" "passes: Write ${p#"$WORK"/}"
done
# A tool the guard is not about stays silent, whatever path it names.
run "$GUARD" "$REPO" "$(payload Read "$(file_input "$REC/in-force.md")" agent-1)"
assert_eq "silent" "$(verdict)" "Read of the record passes: reading is open to every agent"
# Grok Build spells the payload in camelCase.
CAMEL="$(python3 -c 'import json, sys; print(json.dumps({"hookEventName": "PreToolUse", "toolName": "Write", "agentId": "g-1", "toolInput": {"filePath": sys.argv[1], "content": "x"}}))' "$REC/D-x.md")"
run "$GUARD" "$REPO" "$CAMEL"
assert_eq "deny" "$(verdict)" "a camelCase payload (agentId, toolName, filePath) is read too"

# ── the deny ────────────────────────────────────────────────────────────────
echo ""
echo "[the refusal]"
run "$GUARD" "$REPO" "$(payload Bash "$(cmd_input "$ADD")" agent-1)"
assert_eq "2" "$RC" "a refusal exits 2, which Claude Code treats as a block"
assert_contains "$ERR" "only the user's main session writes" "it says who writes the record"
assert_contains "$ERR" "Decisions made or Decisions needed" "and where the agent puts the decision instead"
assert_contains "$OUT" '"permissionDecision":"deny"' "and carries the deny decision for harnesses that read stdout"

# ── context-mode's tools ────────────────────────────────────────────────────
echo ""
echo "[MCP: context-mode]"
mcp_as() { run "$GUARD" "$REPO" "$(payload "$1" "$2" agent-1)"; verdict; }
# Built in python: bash 3.2 brace-expands a "{a,b}" written inside "$(...)".
mcp_in() {
  python3 - "$1" "$ADD" <<'PY'
import json, sys
kind, add = sys.argv[1], sys.argv[2]
print(json.dumps({
    "shell": {"language": "shell", "code": add},
    "batch": {"commands": [{"label": "x", "command": add}], "queries": ["q"]},
    "python": {"language": "python", "code": "import os; os.system('%s')" % add.replace("'", "")},
    "search": {"queries": ["decisions.sh add"]},
}[kind]))
PY
}
assert_eq "deny" "$(mcp_as mcp__context-mode__ctx_execute "$(mcp_in shell)")" "ctx_execute with shell code is refused"
assert_eq "deny" "$(mcp_as mcp__context-mode__ctx_batch_execute "$(mcp_in batch)")" "ctx_batch_execute is refused"
assert_eq "deny" "$(mcp_as mcp__context-mode__ctx_execute "$(mcp_in python)")" "a shell-out from ctx_execute's Python is refused"
assert_eq "silent" "$(mcp_as mcp__context-mode__ctx_search "$(mcp_in search)")" "ctx_search naming the helper passes"

# ── without jq ──────────────────────────────────────────────────────────────
echo ""
echo "[without jq]"
mkdir -p "$WORK/nojq"
for b in sh cat awk sed tr head grep dirname; do ln -sf "$(command -v "$b")" "$WORK/nojq/$b"; done
HOOK_PATH="$WORK/nojq"
assert_eq "deny" "$(bash_as agent-1 "$ADD")" "without jq a subagent's add is still refused"
assert_eq "deny" "$(edit_as agent-1 Write "$REC/D-x.md")" "without jq a subagent's Write into the record is still refused"
assert_eq "silent" "$(bash_as agent-1 "bash .claude/bin/decisions.sh in-force")" "without jq a reader still passes"
unset HOOK_PATH

# ── under each shell ────────────────────────────────────────────────────────
echo ""
echo "[shells]"
# The registration runs `sh`, which is bash on macOS and often dash on Linux.
for shx in sh dash bash; do
  command -v "$shx" >/dev/null 2>&1 || continue
  for c in "deny|Bash|$(cmd_input "$ADD")|agent-1" "deny|Write|$(file_input "$REC/D-x.md")|agent-1" \
           "silent|Bash|$(cmd_input "$ADD")|" "silent|Bash|$(cmd_input "bash .claude/bin/decisions.sh in-force")|agent-1"; do
    IFS='|' read -r want tool tin agent <<< "$c"
    who="the main session"; [ -z "$agent" ] || who="a subagent"
    run "$shx \"\$CLAUDE_PROJECT_DIR/.claude/hooks/decisions-guard.sh\"" "$REPO" "$(payload "$tool" "$tin" "$agent")"
    assert_eq "$want" "$(verdict)" "$shx: $tool from $who -> $want (${tin:0:48})"
  done
done

# ── the plugin's copy ───────────────────────────────────────────────────────
echo ""
echo "[plugin]"
mkdir -p "$WORK/plugin-only"
(cd "$WORK/plugin-only" && git init -q) > "$QUIET_LOG" 2>&1 || quiet_fail "plugin fixture"
run "$P_GUARD" "$WORK/plugin-only" "$(payload Write "$(file_input "$WORK/plugin-only/.git/decisions/D-x.md")" agent-1)"
assert_eq "deny" "$(verdict)" "in a plugin-only project the plugin's copy refuses a Write into the record"
run "$P_GUARD" "$WORK/plugin-only" "$(payload Bash "$(cmd_input "$ADD")" agent-1)"
assert_eq "deny" "$(verdict)" "and the helper's add, through the plugin's own awk and library"
run "$P_GUARD" "$WORK/plugin-only" "$(payload Bash "$(cmd_input "$ADD")")"
assert_eq "silent" "$(verdict)" "while the main session passes"

# ── controls: each mechanism planted back out must change the verdict ────────
echo ""
echo "[controls]"
# mutant <name> <file> <find> <replace> — a project in the fixture repository whose copy of
# <file> has <find> replaced. Prints nothing when <find> is gone, so the control fails
# and says the mechanism moved.
mutant() {
  local dir="$REPO/mut-$1"
  mkdir -p "$dir/.claude/hooks"
  cp "$HOOKS_SRC"/* "$dir/.claude/hooks/"
  python3 - "$dir/.claude/hooks/$2" "$3" "$4" <<'PY' && printf '%s' "$dir"
import sys
path, find, repl = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if find not in text:
    sys.exit(1)
open(path, "w", encoding="utf-8").write(text.replace(find, repl))
PY
}
control() {  # control <label> <expected-from-original> <got-from-mutant>
  TOTAL=$((TOTAL + 1))
  if [ -n "$3" ] && [ "$2" != "$3" ]; then
    echo "  PASS: planted failure caught ($1: $2 -> $3)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: planted failure NOT caught ($1 still ${3:-unbuilt})"
    FAIL=$((FAIL + 1))
  fi
}
MUT="$(mutant gate decisions-guard.sh "*'\"agent_id\"'* | *'\"agentId\"'*) ;;" "*) ;;")" || MUT=
GOT=; [ -z "$MUT" ] || GOT="$(bash_as "" "$ADD" "$MUT")"
control "the agent_id gate" silent "$GOT"
MUT="$(mutant prose decisions-guard.awk 'w = cmdword_x(T, n, 1, 1)' \
  'w = ""; for (CWI = 1; CWI < n; CWI++) if (is_helper(T[CWI])) { w = base(T[CWI]); break }')" || MUT=
GOT=; [ -z "$MUT" ] || GOT="$(bash_as agent-1 "echo run .claude/bin/decisions.sh add from the main session" "$MUT")"
control "command position, not prose" silent "$GOT"
MUT="$(mutant fold decisions-guard.sh 'a = tolower(ENVIRON["KIT_A"]); b = tolower(ENVIRON["KIT_B"])' 'a = ENVIRON["KIT_A"]; b = ENVIRON["KIT_B"]')" || MUT=
GOT=; [ -z "$MUT" ] || GOT="$(edit_as agent-1 Write "$REPO/.git/DECISIONS/D-x.md" "$MUT")"
control "the case fold" deny "$GOT"
MUT="$(mutant resolve decisions-guard.sh 'if cd -P -- "$_d" 2>/dev/null; then' 'if false; then')" || MUT=
GOT=; [ -z "$MUT" ] || GOT="$(edit_as agent-1 Write "$WORK/alias/.git/decisions/D-x.md" "$MUT")"
control "resolving linked directories" deny "$GOT"
MUT="$(mutant name-first decisions-guard.sh '  target "$P"' \
  '  case $P in *[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn][Ss]*) ;; *) return 0 ;; esac; target "$P"')" || MUT=
GOT=; [ -z "$MUT" ] || GOT="$(edit_as agent-1 Write "$WORK/links/rec/D-x.md" "$MUT")"
control "resolving before the name is read" deny "$GOT"
MUT="$(mutant last-link decisions-guard.sh 'while [ -L "$Q" ]' 'while false')" || MUT=
GOT=; [ -z "$MUT" ] || GOT="$(edit_as agent-1 Edit "$WORK/links/list" "$MUT")"
control "following a link in the last place" deny "$GOT"
MUT="$(mutant interp decisions-guard.awk 'function hd_interp_line(w, l) { gsub(/["\047]/, "", l); return l }' '')" || MUT=
GOT=; [ -z "$MUT" ] || GOT="$(bash_as agent-1 "python3 - <<'PY'${NL}import os${NL}os.system(\"$ADD\")${NL}PY" "$MUT")"
control "the interpreter-heredoc callback" deny "$GOT"

assert_dir_exists "$REC" "fixture: the record directory is still there"
assert_eq "" "$(ls -A "$REC")" "and nothing in this suite wrote into it"

print_summary
