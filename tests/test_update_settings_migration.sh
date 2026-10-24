#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# A kit hook has to reach a project that was installed before it existed (issue #91).
#
# install.sh copies settings.json only when absent, and nothing else in update.sh writes
# the `hooks` block: the context-mode matcher patch edits an entry that is already there,
# and firewall.sh owns permissions and sandbox and nothing else. So a guard added after a
# project was installed used to arrive as a script on disk with no line running it — the
# state that looks configured and enforces nothing.
#
# What this suite holds update.sh to: it registers a kit hook the project is missing, it
# leaves everything else in that file exactly as it found it, and running it twice gives
# the same file as running it once.

echo "[test_update_settings_migration] /update carries the kit's hooks into an older install"
echo ""

PROJ="$(new_tmp)" || exit 1
WORK="$(new_tmp)" || exit 1
trap 'rm -rf "$PROJ" "$WORK"' EXIT

SETTINGS="$PROJ/.claude/settings.json"
SECURITY="$PROJ/.claude/security.json"

run_update() {
  (cd "$PROJ" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh "$@") 2>&1
}

# guard_entries <script> — how many hook entries in settings.json run that kit script.
guard_entries() {
  python3 - "$SETTINGS" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
needle, n = sys.argv[2], 0
for entries in (data.get("hooks") or {}).values():
    for entry in entries if isinstance(entries, list) else []:
        for hook in entry.get("hooks") or []:
            if needle in (hook.get("command") or ""):
                n += 1
print(n)
PY
}

# shipped_entries <script> — how many hook entries the kit's own settings.json runs that
# script in. secrets-guard.sh ships twice: on Bash and context-mode, and on Read and Grep.
shipped_entries() {
  python3 - "$REPO_ROOT/.claude/settings.json" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
needle, n = sys.argv[2], 0
for entries in (data.get("hooks") or {}).values():
    for entry in entries if isinstance(entries, list) else []:
        if any(needle in (h.get("command") or "") for h in entry.get("hooks") or []):
            n += 1
print(n)
PY
}

# entries_on <script> <matcher> — how many entries run that script with exactly that matcher.
entries_on() {
  python3 - "$SETTINGS" "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
needle, matcher, n = sys.argv[2], sys.argv[3], 0
for entry in (data.get("hooks") or {}).get("PreToolUse") or []:
    if entry.get("matcher") == matcher and any(
            needle in (h.get("command") or "") for h in entry.get("hooks") or []):
        n += 1
print(n)
PY
}

# json_slice <key> — one top-level key, canonicalized, for before/after comparison.
json_slice() {
  python3 - "$SETTINGS" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps(data.get(sys.argv[2]), sort_keys=True, separators=(",", ":")))
PY
}

# --- A real install, then an older one made out of it -----------------------
(cd "$PROJ" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$PROJ" >/dev/null 2>&1

echo "[baseline]"
assert_json_valid "$SETTINGS" "a fresh install has a settings.json"
GUARDS="$(python3 - "$REPO_ROOT/.claude/settings.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
names = set()
for entries in (data.get("hooks") or {}).values():
    for entry in entries if isinstance(entries, list) else []:
        for hook in entry.get("hooks") or []:
            for word in (hook.get("command") or "").split("/"):
                word = word.split('"')[0]
                if word.endswith(".sh"):
                    names.add(word)
print(" ".join(sorted(names)))
PY
)"
TOTAL=$((TOTAL + 1))
if [ -n "$GUARDS" ]; then
  echo "  PASS: the kit registers hook scripts to carry over ($GUARDS)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the kit's settings.json registers no hook script, so this suite proves nothing"
  FAIL=$((FAIL + 1))
fi

# The hook set this kit ships, read from update.sh rather than pinned, so a scenario that
# records the current set stays current when the set is bumped.
WANT_HS="$(awk -F= '/^  HOOK_SET_VERSION=/{print $2; exit}' "$REPO_ROOT/.claude/bin/update.sh")"
assert_eq "yes" "$([[ "$WANT_HS" =~ ^[0-9]+$ ]] && echo yes || echo no)" \
  "fixture: update.sh names the hook set it ships ($WANT_HS)"

PERMS_BEFORE="$(json_slice permissions)"
SANDBOX_BEFORE="$(json_slice sandbox)"

# Roll the project back to a pre-guard install: drop every kit hook entry, keep a hook
# the user wrote, and add settings of their own that must come through untouched.
python3 - "$SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
hooks = data.get("hooks") or {}
for event in list(hooks):
    kept = [
        entry for entry in hooks[event]
        if not any(".sh" in (h.get("command") or "") for h in entry.get("hooks") or [])
    ]
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
hooks.setdefault("PreToolUse", []).insert(0, {
    "matcher": "Write",
    "hooks": [{"type": "command", "command": "echo my-own-hook >&2; exit 0"}],
})
data["hooks"] = hooks
data["model"] = "opusplanner"  # a session setting of the user's
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY

# A pre-guard install has no record either.
python3 - "$SECURITY" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data.pop("hookSetVersion", None)
data.pop("hookSetFingerprint", None)
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY

echo ""
echo "[an older install, before the update]"
for script in $GUARDS; do
  assert_eq "0" "$(guard_entries "$script")" "fixture: $script is not registered"
done
assert_eq "1" "$(guard_entries my-own-hook)" "fixture: the user's own hook is there"

# --- Dry run reports and writes nothing -------------------------------------
echo ""
echo "[dry run]"
BEFORE_SHA="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
DRY_OUT="$(run_update --dry-run)"
assert_contains "$DRY_OUT" "would register" "--dry-run says it would register the kit hooks"
assert_eq "$BEFORE_SHA" "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" "--dry-run writes nothing to settings.json"

# --- The real run -----------------------------------------------------------
echo ""
echo "[update]"
RUN1="$(run_update)"
assert_contains "$RUN1" "registered" "the run reports the hooks it registered"
assert_json_valid "$SETTINGS" "settings.json is still valid JSON"
for script in $GUARDS; do
  assert_eq "$(shipped_entries "$script")" "$(guard_entries "$script")" \
    "$script is registered as often as the kit ships it"
done
assert_eq "1" "$(entries_on secrets-guard.sh 'Read|Grep')" "secrets-guard.sh is registered on Read and Grep"

echo ""
echo "[nothing of the user's was touched]"
assert_eq "1" "$(guard_entries my-own-hook)" "the user's own hook is still there, once"
assert_eq "$PERMS_BEFORE" "$(json_slice permissions)" "permissions untouched (firewall.sh owns them)"
assert_eq "$SANDBOX_BEFORE" "$(json_slice sandbox)" "sandbox untouched"
assert_eq '"opusplanner"' "$(json_slice model)" "a session setting of the user's is untouched"
FIRST_PRE="$(python3 - "$SETTINGS" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]["PreToolUse"]
print(entries[0]["hooks"][0]["command"])
PY
)"
assert_contains "$FIRST_PRE" "my-own-hook" "the kit's entries were appended, not inserted ahead of the user's"

# --- Versioned gate ---------------------------------------------------------
echo ""
echo "[gate]"
assert_file_contains "$SECURITY" "hookSetVersion" "the applied hook set is recorded in security.json"
assert_json_valid "$SECURITY" "security.json is still valid JSON"
assert_contains "$(python3 -c "
import json; print(json.load(open('$SECURITY')).get('tier'))")" "relaxed" "the recorded tier is untouched"

# --- Idempotent -------------------------------------------------------------
echo ""
echo "[twice == once]"
AFTER_ONE="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
RUN2="$(run_update)"
assert_eq "$AFTER_ONE" "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" "a second /update leaves settings.json byte-identical"
TOTAL=$((TOTAL + 1))
if grep -q "] registered" <<<"$RUN2"; then
  echo "  FAIL: the second run registered hooks again"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: the second run registers nothing"
  PASS=$((PASS + 1))
fi
RUN3="$(run_update)"
assert_eq "$AFTER_ONE" "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" "a third /update is still byte-identical"

# --- One guard missing: only that one comes back ----------------------------
echo ""
echo "[one guard missing]"
ONE_GUARD="$(printf '%s\n' $GUARDS | head -1)"
python3 - "$SETTINGS" "$SECURITY" "$ONE_GUARD" <<'PY'
import json, sys

settings_path, security_path, needle = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(settings_path, encoding="utf-8"))
for event, entries in (data.get("hooks") or {}).items():
    data["hooks"][event] = [
        entry for entry in entries
        if not any(needle in (h.get("command") or "") for h in entry.get("hooks") or [])
    ]
json.dump(data, open(settings_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)

# The gate has to let the run happen: a project that loses a guard between updates is
# behind the recorded set, which is what a bumped HOOK_SET_VERSION expresses.
security = json.load(open(security_path, encoding="utf-8"))
security["hookSetVersion"] = 0
json.dump(security, open(security_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_eq "0" "$(guard_entries "$ONE_GUARD")" "fixture: $ONE_GUARD removed again"
run_update >/dev/null
assert_eq "$(shipped_entries "$ONE_GUARD")" "$(guard_entries "$ONE_GUARD")" "$ONE_GUARD comes back"
for script in $GUARDS; do
  assert_eq "$(shipped_entries "$script")" "$(guard_entries "$script")" \
    "$script is still registered as often as the kit ships it"
done

# --- An install from hook set 2: secrets-guard.sh on Bash, not yet on Read and Grep ---
#
# The state every install before hook set 3 is in. Identity by script alone would read
# secrets-guard.sh as already running and never add its second entry, so the identity
# also asks whether the live entry's matcher selects the shipped entry's tools.
echo ""
echo "[hook set 2 -> 3: a second entry for a script already running]"
python3 - "$SETTINGS" "$SECURITY" <<'PY'
import json, sys
settings_path, security_path = sys.argv[1], sys.argv[2]
data = json.load(open(settings_path, encoding="utf-8"))
data["hooks"]["PreToolUse"] = [e for e in data["hooks"]["PreToolUse"] if e.get("matcher") != "Read|Grep"]
json.dump(data, open(settings_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
security = json.load(open(security_path, encoding="utf-8"))
security["hookSetVersion"] = 2
security["hookSetFingerprint"] = "0000000000000000"
json.dump(security, open(security_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_eq "0" "$(entries_on secrets-guard.sh 'Read|Grep')" "fixture: no Read and Grep entry yet"
assert_eq "1" "$(entries_on secrets-guard.sh 'Bash|mcp__context-mode__.*')" "fixture: secrets-guard.sh runs on Bash"
SET3="$(run_update)"
assert_contains "$SET3" "secrets-guard.sh (Read|Grep)" "the run names the entry it registered"
assert_eq "1" "$(entries_on secrets-guard.sh 'Read|Grep')" "the Read and Grep entry is added"
for script in $GUARDS; do
  assert_eq "$(shipped_entries "$script")" "$(guard_entries "$script")" \
    "$script is registered as often as the kit ships it, no Bash entry doubled"
done
AFTER_SET3="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
run_update >/dev/null
assert_eq "$AFTER_SET3" "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" "a second /update adds nothing more"

# A user who already runs secrets-guard.sh on every tool gets no second copy.
python3 - "$SETTINGS" "$SECURITY" <<'PY'
import json, sys
settings_path, security_path = sys.argv[1], sys.argv[2]
data = json.load(open(settings_path, encoding="utf-8"))
pre = data["hooks"]["PreToolUse"]
data["hooks"]["PreToolUse"] = [e for e in pre if not any(
    "secrets-guard.sh" in (h.get("command") or "") for h in e.get("hooks") or [])]
data["hooks"]["PreToolUse"].append({"matcher": "*", "hooks": [
    {"type": "command", "command": "sh ./tools/secrets-guard.sh on-every-tool"}]})
json.dump(data, open(settings_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
security = json.load(open(security_path, encoding="utf-8"))
security["hookSetVersion"] = 0
json.dump(security, open(security_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
run_update >/dev/null
assert_eq "1" "$(guard_entries secrets-guard.sh)" "a secrets-guard.sh entry on every tool is not doubled"
assert_file_contains "$SETTINGS" "on-every-tool" "the user's own entry is still the one that runs"

# --- A guard the user rewrote is left alone ---------------------------------
#
# Identity is the script the command names and the tools its matcher selects, not the
# entry's shape, so a project running a guard its own way must not get a second copy of
# it alongside.
echo ""
echo "[a guard the user rewrote]"
python3 - "$SETTINGS" "$SECURITY" "$ONE_GUARD" <<'PY'
import json, sys

settings_path, security_path, needle = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(settings_path, encoding="utf-8"))
for event, entries in (data.get("hooks") or {}).items():
    data["hooks"][event] = [
        entry for entry in entries
        if not any(needle in (h.get("command") or "") for h in entry.get("hooks") or [])
    ]
data["hooks"].setdefault("PreToolUse", []).append({
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "sh ./tools/%s with-my-own-flags" % needle}],
})
json.dump(data, open(settings_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)

security = json.load(open(security_path, encoding="utf-8"))
security["hookSetVersion"] = 0
json.dump(security, open(security_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
run_update >/dev/null
assert_eq "1" "$(guard_entries "$ONE_GUARD")" "the user's own invocation of $ONE_GUARD is not doubled"
assert_file_contains "$SETTINGS" "with-my-own-flags" "the user's own invocation is still the one that runs"

# --- Migration F1/F2/F10: a narrowed or respelled matcher must not be doubled, and
# --- /doctor check 10 must read it the way /update does -------------------------------
#
# /update judges a shipped entry already-run by the script it names and the tools its
# matcher selects. named_tools reads only a plain `|` list, so without a probe set a
# shipped `Bash|mcp__context-mode__.*` offered only Bash and a user entry on the MCP
# half read as not-running — a second full copy appended, against the CHANGELOG's
# promise. And a live matcher respelled `Read, Grep` or `Read | Grep`, or anchored, read
# as selecting nothing, so the Read|Grep entry was appended beside a working one.
echo ""
echo "[F1: a guard narrowed to its context-mode half is not doubled]"
cp "$REPO_ROOT/.claude/settings.json" "$SETTINGS"; cp "$REPO_ROOT/.claude/security.json" "$SECURITY"
python3 - "$SETTINGS" "$SECURITY" <<'PY'
import json, sys
sp, qp = sys.argv[1], sys.argv[2]
d = json.load(open(sp, encoding="utf-8"))
for e in d["hooks"]["PreToolUse"]:
    if any("egress-guard.sh" in (h.get("command") or "") for h in e.get("hooks") or []):
        e["matcher"] = "mcp__context-mode__.*"      # the user drops Bash, keeps the MCP half
json.dump(d, open(sp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
s = json.load(open(qp, encoding="utf-8")); s["hookSetVersion"] = 0
json.dump(s, open(qp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_eq "1" "$(guard_entries egress-guard.sh)" "fixture: egress-guard runs once, on the MCP half"
run_update >/dev/null
assert_eq "1" "$(guard_entries egress-guard.sh)" "a guard narrowed to its context-mode half is not doubled"
assert_eq "1" "$(entries_on egress-guard.sh 'mcp__context-mode__.*')" "the user's narrowing is left in place"

echo "[F2: Read, Grep / Read | Grep / anchored spellings are not doubled]"
# /doctor check 10 carries this same matcher reading (its own copy), so the two agree
# by construction; pin that doctor.md still has it, so a revert there is caught.
assert_file_contains "$REPO_ROOT/.claude/commands/doctor.md" 're.fullmatch(r"[A-Za-z0-9_\-, |]+", m)' \
  "doctor check 10 reads a matcher as /update does (exact |/, list)"
assert_file_contains "$REPO_ROOT/.claude/commands/doctor.md" 'print("hook_set:"' \
  "doctor check 10 reads the recorded hook set, to tell predates from removed-at-set"
# doctor_fg — doctor check 10's file_guard over the current $SETTINGS (its selects()
# verbatim), so the test pins that /doctor reads the matcher the way /update does.
doctor_fg() {
  python3 - "$SETTINGS" <<'PY'
import json, re, sys
pre = ((json.load(open(sys.argv[1], encoding="utf-8")).get("hooks") or {}).get("PreToolUse") or [])
def selects(m, tool):
    if not isinstance(m, str) or m.strip() in ("", "*"): return True
    if re.fullmatch(r"[A-Za-z0-9_\-, |]+", m):
        return tool in [a.strip() for a in re.split(r"[|,]", m)]
    try: return re.search(m, tool) is not None
    except re.error: return False
def fg(e):
    if not any("secrets-guard" in (h.get("command") or "") for h in e.get("hooks") or []): return False
    m = e.get("matcher"); return selects(m, "Read") or selects(m, "Grep")
print("True" if any(fg(e) for e in pre) else "False")
PY
}
for SPELL in "Read, Grep" "Read,Grep" "Read | Grep" " Read|Grep " "^(Read|Grep)$"; do
  cp "$REPO_ROOT/.claude/settings.json" "$SETTINGS"; cp "$REPO_ROOT/.claude/security.json" "$SECURITY"
  python3 - "$SETTINGS" "$SECURITY" "$SPELL" <<'PY'
import json, sys
sp, qp, spell = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(sp, encoding="utf-8"))
for e in d["hooks"]["PreToolUse"]:
    if any("secrets-guard.sh" in (h.get("command") or "") for h in e.get("hooks") or []) \
       and (e.get("matcher") or "").replace(" ", "") in ("Read|Grep", "Read,Grep", "^(Read|Grep)$"):
        e["matcher"] = spell
json.dump(d, open(sp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
s = json.load(open(qp, encoding="utf-8")); s["hookSetVersion"] = 0
json.dump(s, open(qp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
  BEFORE="$(guard_entries secrets-guard.sh)"
  assert_eq "True" "$(doctor_fg)" "doctor reads '$SPELL' as covering the file guard (agrees with /update)"
  run_update >/dev/null
  assert_eq "$BEFORE" "$(guard_entries secrets-guard.sh)" "the respelled matcher '$SPELL' is not doubled"
  assert_eq "1" "$(entries_on secrets-guard.sh "$SPELL")" "the user's spelling '$SPELL' is left in place"
done

echo "[F10: at the current hook set a removed Read|Grep entry is not re-added, and doctor says so]"
cp "$REPO_ROOT/.claude/settings.json" "$SETTINGS"; cp "$REPO_ROOT/.claude/security.json" "$SECURITY"
python3 - "$SETTINGS" "$SECURITY" "$REPO_ROOT/.claude/settings.json" "$WANT_HS" <<'PY'
import json, sys
sp, qp = sys.argv[1], sys.argv[2]
d = json.load(open(sp, encoding="utf-8"))
d["hooks"]["PreToolUse"] = [e for e in d["hooks"]["PreToolUse"]
    if not (any("secrets-guard.sh" in (h.get("command") or "") for h in e.get("hooks") or [])
            and e.get("matcher") in ("Read|Grep", "Read, Grep", "Read,Grep", " Read|Grep ", "Read | Grep", "^(Read|Grep)$"))]
json.dump(d, open(sp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
s = json.load(open(qp, encoding="utf-8"))
s["hookSetVersion"] = int(sys.argv[4])
# today's shipped set and fingerprint, so the gate stays closed: computed from the kit's block.
import hashlib
kit = json.load(open(sys.argv[3], encoding="utf-8"))["hooks"]
s["hookSetFingerprint"] = hashlib.sha256(json.dumps(kit, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()[:16]
json.dump(s, open(qp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_eq "False" "$(doctor_fg)" "fixture: the file guard is gone"
assert_eq "0" "$(entries_on secrets-guard.sh 'Read|Grep')" "fixture: no Read|Grep entry at the current hook set"
run_update >/dev/null
assert_eq "0" "$(entries_on secrets-guard.sh 'Read|Grep')" "update does not re-add it at the current hook set (gate closed)"

# --- An install with no settings.json is reported, not rebuilt --------------
echo ""
echo "[no settings.json]"
mv "$SETTINGS" "$WORK/settings.json.away"
reopen_gate() {
  python3 - "$SECURITY" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["hookSetVersion"] = 0
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
}
reopen_gate
NO_SETTINGS_OUT="$(run_update)"
assert_contains "$NO_SETTINGS_OUT" "settings.json is missing" "a project with no settings.json is told, not silently skipped"
assert_file_not_exists "$SETTINGS" "/update does not write a settings.json the project does not have"
mv "$WORK/settings.json.away" "$SETTINGS"

# --- What is still fresh-install-only is said out loud ----------------------
echo ""
echo "[honesty]"
python3 - "$SETTINGS" "$SECURITY" <<'PY'
import json, sys
settings_path, security_path = sys.argv[1], sys.argv[2]
data = json.load(open(settings_path, encoding="utf-8"))
data.pop("enabledPlugins", None)
data.pop("extraKnownMarketplaces", None)
json.dump(data, open(settings_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
security = json.load(open(security_path, encoding="utf-8"))
security["hookSetVersion"] = 0
json.dump(security, open(security_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
PLUGIN_OUT="$(run_update)"
assert_contains "$PLUGIN_OUT" "security plugin is not" "a missing plugin registration is reported rather than assumed"
TOTAL=$((TOTAL + 1))
if python3 -c "
import json,sys
d = json.load(open('$SETTINGS'))
sys.exit(0 if not d.get('enabledPlugins') else 1)"; then
  echo "  PASS: /update does not enable a plugin on the user's behalf"
  PASS=$((PASS + 1))
else
  echo "  FAIL: /update wrote enabledPlugins into the project"
  FAIL=$((FAIL + 1))
fi

print_summary
