#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_secrets_guard] glob-aware vault matching and the shell -c block"

GUARD="$REPO_ROOT/.claude/hooks/secrets-guard.sh"
assert_file_exists "$GUARD" "the guard ships"
assert_file_exists "$REPO_ROOT/.claude/hooks/secrets-guard.awk" "the decision awk ships"

WORK="$(new_tmp)" || exit 1
trap 'rm -rf "$WORK"' EXIT

# verdict <tier> <command> -> deny | allow | ask | silent
verdict() {
  local pay out
  pay="$(python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$2")"
  out="$(cd "$REPO_ROOT" && printf '%s' "$pay" | CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    KIT_FIREWALL_TIER="$1" KIT_FIREWALL_HEADLESS=0 sh "$GUARD" 2>/dev/null)"
  case "$out" in *'"deny"'*) echo deny ;; *'"allow"'*) echo allow ;; *'"ask"'*) echo ask ;; *) echo silent ;; esac
}
# want <tier> <verdict> <label> <command>
want() {
  local got; got="$(verdict "$1" "$4")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$2" ]; then echo "  PASS: [$1] $2  $3"; PASS=$((PASS + 1))
  else echo "  FAIL: [$1] want $2, got $got  $3  ::  $4"; FAIL=$((FAIL + 1)); fi
}

T='~'   # tilde home; the glob check folds $HOME/${HOME} to this form too

# ── reads through glob characters ───────────────────────────────────────────
# The glob forms the red team routed past the literal vault match: a metacharacter
# inside the protected basename. Every one names a credential and must be denied.
echo "[glob evasions: denied]"
for C in "cat ${T}/.np*" "cat ${T}/.npmr?" "cat ${T}/.config/gh/host*.yml" \
         "cat ${T}/.config/solana/id.jso?" "tac ${T}/.np*" "base64 ${T}/.ssh/id_*" \
         "cat ${T}/.ss*/id_rsa" "cat ${T}/.aw*/credentials" "cat ${T}/.config/solana/*.json" \
         "cat *.pem" "cat ${T}/keys/*.pem" "cat \${HOME}/.np*" "cat \$HOME/.npmr?" \
         "cat ${T}/.[n]pmrc" "cat ${T}/.{npmrc,bashrc}" "cat ${T}/.{bashrc,ssh/id_rsa}" \
         "cat ${T}/.*" "cat ${T}/.config/solana/*"; do
  want relaxed deny "glob could name a credential" "$C"
done

# Readers the plain path already catches, confirmed here so a regression shows, and
# the empty-program sed/awk forms that shifted the file into the pattern slot.
echo "[readers and the empty-program slot: denied]"
for C in "awk 1 ${T}/.npmrc" "nl ${T}/.npmrc" "od ${T}/.config/solana/id.json" \
         "xxd ${T}/.ssh/id_rsa" "dd if=${T}/.config/solana/id.json" "tac ${T}/.npmrc" \
         "sed '' ${T}/.git-credentials" "sed -n '' ${T}/.npmrc" "sed -n p ${T}/.npmrc"; do
  want relaxed deny "reader prints the credential" "$C"
done

# Ordinary globs that name no credential must stay silent — the directory is kept, so
# a build dir or a local file is not swept in.
echo "[ordinary globs: silent]"
for C in "cat ./*.json" "cat host*.yml" "cat *.json" "cat src/*.ts" "cat package*.json" \
         "cat ${T}/.config/*.toml" "cat README*.md" "cat test?.js" "ls ${T}/.config/*" \
         "cat dist/*.js" "cat ./*.pem.example"; do
  want relaxed silent "no credential named" "$C"
done

# Catch-all wildcards (`*`, `dir/*`) that a reader expands must stay silent at every
# tier: a bare `*` basename matches the extension witnesses (x.pem) and a single-segment
# `*` matches .npmrc/_netrc, so the earlier glob check denied `cat src/*`, `git add src/*`
# and `rm -rf target/*` — the opposite of what Relaxed is for. A glob that also names an
# ordinary project file is generic, not credential-targeting, and is not a read. Reader
# NOT `cat` so the generic-wildcard path is exercised beyond one command.
echo "[catch-all wildcards: silent (a generic glob is not a targeted read)]"
for TIER in off relaxed medium high; do
  for C in "cat src/*" "cat *" "cp dist/* out/" "git add src/*" "rm -rf target/*" \
           "grep -rn foo src/*" "cat build/*" "cat logs/*.log" "cat packages/*" \
           "tar czf a.tgz src/*"; do
    want "$TIER" silent "a catch-all glob names ordinary files too" "$C"
  done
done

# .key is exfil-only (kit_secret_re), not a read-block (kit_vault_re): a literal
# `cat x.key` is silent, so its glob form must agree. A regression that re-adds x.key to
# the basename witnesses (or .key to the vault regex) flips this and the drift guard below.
echo "[.key is not a read-block, literal and glob agree: silent]"
for C in "cat ${T}/foo.key" "cat *.key" "cat ${T}/keys/*.key"; do
  want relaxed silent ".key is exfil-only, not read-blocked" "$C"
done

# Plain-path reads stay denied (also the drift guard: narrowing the vault regex to drop
# any of these would fail here AND quietly disable its glob form above).
echo "[plain credential paths: denied at every tier]"
for TIER in off relaxed medium high; do
  for C in "cat ${T}/.config/solana/id.json" "cat ${T}/.ssh/id_rsa" "cat ${T}/.npmrc" \
           "cat ${T}/.git-credentials" "cat ${T}/.config/gh/hosts.yml"; do
    want "$TIER" deny "plain credential read" "$C"
  done
done

# Prose that merely names a credential path is data, never access.
echo "[mentions: silent]"
for C in "git commit -m 'docs: do not read the npmrc'" "echo hi" \
         "grep -rn pattern ${T}/.config README.md"; do
  want relaxed silent "a mention is not a read" "$C"
done

# ── the shell -c block and its one memsearch exception ──────────────────────
# This is the hook alone. Where the permission rules ship, Bash(bash -c *) still
# denies the memsearch line, whatever the hook returns (tests/test_firewall.sh).
# memsearch's collection-derivation line, verbatim from memory-recall/SKILL.md.
MEMSEARCH_CMD=$(cat <<'KIT_MEMSEARCH_EOF'
bash -c 'if [ -n "${MEMSEARCH_DIR:-}" ]; then bash "${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh" "$MEMSEARCH_DIR"; else root=$(git rev-parse --show-toplevel 2>/dev/null || true); if [ -n "$root" ]; then bash "${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh" "$root"; else bash "${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh"; fi; fi'
KIT_MEMSEARCH_EOF
)

echo "[memsearch line: the hook allows it at every tier; every other -c it denies]"
for TIER in off relaxed medium high; do
  want "$TIER" allow "the exact memsearch collection line" "$MEMSEARCH_CMD"
  want "$TIER" deny  "bash -c rm -rf home is denied" "bash -c 'rm -rf ~'"
done

# 20+ near-misses of the memsearch line, plus the other shell-c forms: all denied.
echo "[near-misses and every shell -c form: denied]"
NM=(
  "${MEMSEARCH_CMD}; whoami"
  "${MEMSEARCH_CMD} "
  "whoami; ${MEMSEARCH_CMD}"
  "env X=1 ${MEMSEARCH_CMD}"
  "${MEMSEARCH_CMD}x"
  "bash -c 'bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh\"'"
  "bash -c 'bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/other.sh\"'"
  "sh -c 'echo hi'"
  "bash -c \"echo hi\""
  "zsh -c 'echo hi'"
  "dash -c 'echo hi'"
  "ksh -c 'echo hi'"
  "bash -lc 'echo hi'"
  "bash -ic 'echo hi'"
  "sh -lc 'echo hi'"
  "env bash -c 'echo hi'"
  "command sh -c 'echo hi'"
  "exec bash -c 'echo hi'"
  "timeout 5 bash -c 'echo hi'"
  "nice -n 5 sh -c 'echo hi'"
  "/bin/bash -c 'echo hi'"
  "/usr/bin/env bash -c 'echo hi'"
  "bash  -c  'echo hi'"
  "eval 'bash -c \"echo hi\"'"
)
for C in "${NM[@]}"; do
  for TIER in relaxed high; do want "$TIER" deny "shell -c near-miss / form" "$C"; done
done

# Not a shell -c: a shell given a script, prose, and the shells the decision left out.
echo "[not a shell -c: silent]"
for C in "bash script.sh" "bash ./x.sh 'a; b'" "sh install.sh" "cargo build --release" \
         "echo 'run bash -c later'" "git commit -m 'note: bash -c is blocked'" \
         "fish -c 'echo hi'" "ash -c 'echo hi'" "ls -la"; do
  want relaxed silent "not a blocked shell -c" "$C"
done

# ── drift guard: every canonical protected path still matches the vault regex ──
# The glob check tests a glob against these canonical paths; if kit_vault_re is
# narrowed so one stops matching, the glob evasion for it silently reopens. Assert
# the regex still covers each, so that change is caught here.
echo "[vault regex still covers the canonical credential paths]"
# shellcheck source=/dev/null
. "$REPO_ROOT/.claude/hooks/lib-headless.sh"
VRE="$(kit_vault_re)"
for P in ".ssh/id_rsa" ".gnupg/key" ".aws/credentials" ".config/solana/id.json" \
         ".npmrc" ".netrc" "_netrc" ".git-credentials" ".config/gh/hosts.yml" \
         ".kube/config" ".cargo/credentials" ".cargo/credentials.toml" ".docker/config.json" \
         ".pypirc" ".gem/credentials" ".claude/.credentials.json" "key.pem" ".zsh_history"; do
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$P" | KIT_VRE="$VRE" awk '{ exit ($0 ~ ENVIRON["KIT_VRE"]) ? 0 : 1 }'; then
    echo "  PASS: vault regex matches $P"; PASS=$((PASS + 1))
  else
    echo "  FAIL: vault regex NO LONGER matches $P (glob witness for it is now dead)"; FAIL=$((FAIL + 1))
  fi
done

# When memory-recall/SKILL.md is on this machine, the hook's allowlisted line must be
# its line-12 command verbatim; otherwise the exemption silently stops matching.
SKILL="$HOME/.claude/plugins/marketplaces/memsearch-plugins/plugins/claude-code/skills/memory-recall/SKILL.md"
if [ -r "$SKILL" ]; then
  LIVE="$(python3 - "$SKILL" <<'PY'
import re, sys
line = open(sys.argv[1]).read().split("\n")[11]
m = re.search(r'!`(.*)`', line)
print(m.group(1) if m else "")
PY
)"
  assert_eq "$MEMSEARCH_CMD" "$LIVE" "the allowlisted line matches memory-recall/SKILL.md line 12"
  assert_file_contains "$GUARD" "derive-collection.sh" "the guard carries the memsearch line"
else
  echo "  SKIP: memory-recall/SKILL.md not installed here; cannot cross-check the allowlisted line"
  SKIP=$((SKIP + 1))
fi

print_summary
