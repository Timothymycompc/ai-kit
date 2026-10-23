#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_secrets_guard] glob-aware vault matching, the shell -c block and gh's host file"

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
# This is the hook alone, and it sees only the agent's own calls. At Medium and High
# the rule Bash(bash -c *) also denies the memsearch line, whatever the hook returns;
# at Off and Relaxed no rule names bash -c (tests/test_firewall.sh).
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

# ── gh's host file through the Read and Grep tools, and context-mode's paths ──
# Off and Relaxed leave the file readable so gh starts inside the sandbox; the guard
# refuses Claude Code's Read and Grep on it at every tier, in any spelling that reaches
# the same file. Everything runs against a FAKE home holding a fake host file, and the
# path is assembled at run time, so nothing real is read and no command line here names
# a credential path.
echo "[gh's host file: Read and Grep refused in every spelling, at every tier]"
FH="$WORK/home"
mkdir -p "$FH/.config/gh" "$FH/proj/src" "$FH/links" "$FH/dotfiles/nvim"
HY="hosts.y""ml"
GHF="$FH/.config/gh/$HY"
printf 'github.com:\n    oauth_token: FAKE-NOT-A-TOKEN\n' > "$GHF"
printf 'export const x = 1\n' > "$FH/proj/src/app.ts"
ln -s "$GHF" "$FH/links/sym.yml"
ln "$GHF" "$FH/links/hard.yml"
ln -s "$FH/.config" "$FH/links/cfg"
# A stow-style link inside .config: through it, `..` by text and `..` by the kernel
# name two different files.
ln -s "$FH/dotfiles/nvim" "$FH/.config/nvim"

# tool_verdict <tier> <tool> <tool_input JSON> [cwd] [env...] -> deny | allow | ask | silent
tool_verdict() {
  local tier="$1" tool="$2" input="$3" cwd="${4:-$FH/proj}" pay out
  shift 4 2>/dev/null || shift $#
  pay="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":json.loads(sys.argv[2]),"cwd":sys.argv[3]}))' "$tool" "$input" "$cwd")"
  out="$(cd "$cwd" && printf '%s' "$pay" | env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$FH" \
    CLAUDE_PROJECT_DIR="$REPO_ROOT" KIT_FIREWALL_TIER="$tier" KIT_FIREWALL_HEADLESS=0 "$@" \
    sh "$GUARD" 2>/dev/null)"
  case "$out" in *'"deny"'*) echo deny ;; *'"allow"'*) echo allow ;; *'"ask"'*) echo ask ;; *) echo silent ;; esac
}
# want_tool <tier> <verdict> <label> <tool> <tool_input JSON> [cwd] [env...]
want_tool() {
  local tier="$1" w="$2" label="$3" got; shift 3
  got="$(tool_verdict "$tier" "$@")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$w" ]; then echo "  PASS: [$tier] $w  $label"; PASS=$((PASS + 1))
  else echo "  FAIL: [$tier] want $w, got $got  $label  ::  $1 $2"; FAIL=$((FAIL + 1)); fi
}
rd() { python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1]}))' "$1"; }
gp() { python3 -c 'import json,sys; print(json.dumps({"pattern": "token", "path": sys.argv[1]}))' "$1"; }
G_NOPATH='{"pattern": "token"}'

for TIER in off relaxed medium high; do
  want_tool "$TIER" deny "Read, direct path"                 Read "$(rd "$GHF")"
  want_tool "$TIER" deny "Read, the ~ form"                  Read "$(rd "~/.config/gh/$HY")"
  want_tool "$TIER" deny "Read, a .. segment"                Read "$(rd "$FH/proj/../.config/gh/$HY")"
  want_tool "$TIER" deny "Read, a symlink to it"             Read "$(rd "$FH/links/sym.yml")"
  want_tool "$TIER" deny "Read, a hard link to it"           Read "$(rd "$FH/links/hard.yml")"
  want_tool "$TIER" deny "Read, .. through a symlinked dir"  Read "$(rd "$FH/links/cfg/../.config/gh/$HY")"
  want_tool "$TIER" deny "Read, .. resolved as text"         Read "$(rd "$FH/.config/nvim/../gh/$HY")"
  want_tool "$TIER" deny "Grep on the file itself"           Grep "$(gp "$GHF")"
  want_tool "$TIER" deny "Grep on ~/.config/gh"              Grep "$(gp "~/.config/gh")"
  want_tool "$TIER" deny "Grep on ~/.config"                 Grep "$(gp "~/.config")"
  want_tool "$TIER" deny "Grep on \$HOME"                    Grep "$(gp "$FH")"
  want_tool "$TIER" deny "Grep on ~"                         Grep "$(gp "~")"
  want_tool "$TIER" deny "Grep on a link to ~/.config"       Grep "$(gp "$FH/links/cfg")"
  want_tool "$TIER" deny "Grep with no path, run from \$HOME" Grep "$G_NOPATH" "$FH"
  want_tool "$TIER" silent "Read of an ordinary file"        Read "$(rd "$FH/proj/src/app.ts")"
  want_tool "$TIER" silent "Grep of the project"             Grep "$(gp "$FH/proj")"
  want_tool "$TIER" silent "Grep of a relative path"         Grep "$(gp "src")"
  want_tool "$TIER" silent "Grep with no path, in the project" Grep "$G_NOPATH"
  want_tool "$TIER" silent "Grep of a sibling of the file's directory" Grep "$(gp "$FH/dotfiles")"
  want_tool "$TIER" silent "Read of a path that does not exist" Read "$(rd "$FH/.config/gh/nope.yml")"
  want_tool "$TIER" silent "Grep of a path that does not exist" Grep "$(gp "$FH/no/such/dir")"
done

# Another case is the same file only on a case-insensitive volume (macOS's default).
if [ -e "$FH/.CONFIG/GH/HOSTS.YML" ]; then
  want_tool relaxed deny "Read, another case on a case-insensitive volume" Read "$(rd "$FH/.CONFIG/GH/HOSTS.YML")"
  want_tool relaxed deny "Grep, another case on a case-insensitive volume" Grep "$(gp "$FH/.Config")"
else
  want_tool relaxed silent "Read, another case on a case-sensitive volume names no such file" \
    Read "$(rd "$FH/.CONFIG/GH/HOSTS.YML")"
fi

# gh's own resolution: GH_CONFIG_DIR, then XDG_CONFIG_HOME.
mkdir -p "$FH/altgh" "$FH/xdg/gh"
cp "$GHF" "$FH/altgh/$HY"
cp "$GHF" "$FH/xdg/gh/$HY"
want_tool relaxed deny "Read, the host file under GH_CONFIG_DIR" Read "$(rd "$FH/altgh/$HY")" "$FH/proj" \
  GH_CONFIG_DIR="$FH/altgh"
want_tool relaxed deny "Grep on GH_CONFIG_DIR" Grep "$(gp "$FH/altgh")" "$FH/proj" GH_CONFIG_DIR="$FH/altgh"
want_tool relaxed deny "Read, the host file under XDG_CONFIG_HOME" Read "$(rd "$FH/xdg/gh/$HY")" "$FH/proj" \
  XDG_CONFIG_HOME="$FH/xdg"

# A stow-style home, where ~/.config itself links into a dotfiles tree: a Grep of that
# tree reads the file through its physical path.
FH2="$WORK/home2"
mkdir -p "$FH2/dotfiles/config/gh" "$FH2/proj"
cp "$GHF" "$FH2/dotfiles/config/gh/$HY"
ln -s "$FH2/dotfiles/config" "$FH2/.config"
SAVE_FH="$FH"; FH="$FH2"
want_tool relaxed deny "Grep of the dotfiles tree ~/.config links into" Grep "$(gp "$FH2/dotfiles")" "$FH2/proj"
want_tool relaxed deny "Read through the linked ~/.config" Read "$(rd "~/.config/gh/$HY")" "$FH2/proj"
FH="$SAVE_FH"

# No host file at all: nothing to protect, so nothing is refused.
FH3="$WORK/home3"
mkdir -p "$FH3/proj"
SAVE_FH="$FH"; FH="$FH3"
want_tool relaxed silent "Grep of \$HOME when gh has no host file" Grep "$(gp "$FH3")" "$FH3/proj"
FH="$SAVE_FH"

# The payload is read without jq too, through lib-headless.sh's awk fallback.
NOJQ="$WORK/nojq"
mkdir -p "$NOJQ"
for b in sh awk sed cat tr head grep dirname readlink env; do
  p="$(command -v "$b" 2>/dev/null)" && ln -s "$p" "$NOJQ/$b"
done
want_tool relaxed deny "Read, direct path, with no jq on PATH" Read "$(rd "$GHF")" "$FH/proj" PATH="$NOJQ"
want_tool relaxed silent "Read of an ordinary file, with no jq on PATH" Read "$(rd "$FH/proj/src/app.ts")" "$FH/proj" \
  PATH="$NOJQ"

# A Bash call is never mistaken for a file tool, prose naming one included, and the
# Bash corpus still decides it.
echo "[gh's host file: the Bash and MCP surfaces]"
for TIER in off relaxed; do
  want_tool "$TIER" deny "a Bash call mentioning Read still meets the corpus" \
    Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": "echo \"Read\"; cat " + sys.argv[1]}))' "~/.config/gh/$HY")"
  want_tool "$TIER" silent "Bash prose mentioning Read and Grep stays silent" \
    Bash '{"command": "git commit -m \"Read and Grep: docs\""}'
  # A field whose value is exactly "Read" passes the cheap pre-filter; the tool name
  # decides, and the payload still meets the corpus.
  want_tool "$TIER" deny "an MCP payload whose intent is \"Read\" still meets the corpus" \
    mcp__context-mode__ctx_execute '{"language": "shell", "code": "cat ~/.npmrc", "intent": "Read"}'
done
# context-mode reads a path in its own process: the same test as Grep's root.
cx() { python3 -c 'import json,sys; print(json.dumps({"path": sys.argv[1], "language": "shell", "code": "echo hi"}))' "$1"; }
ix() { python3 -c 'import json,sys; print(json.dumps({"path": sys.argv[1], "source": "notes"}))' "$1"; }
for TIER in off relaxed; do
  want_tool "$TIER" deny "ctx_execute_file on a symlink to it" mcp__context-mode__ctx_execute_file "$(cx "$FH/links/sym.yml")"
  want_tool "$TIER" deny "ctx_execute_file on a hard link to it" mcp__context-mode__ctx_execute_file "$(cx "$FH/links/hard.yml")"
  want_tool "$TIER" deny "ctx_index on ~/.config" mcp__context-mode__ctx_index "$(ix "~/.config")"
  want_tool "$TIER" deny "ctx_index on \$HOME" mcp__context-mode__ctx_index "$(ix "$FH")"
  want_tool "$TIER" silent "ctx_index on the project" mcp__context-mode__ctx_index "$(ix "$FH/proj")"
  want_tool "$TIER" silent "ctx_execute_file on an ordinary file" mcp__context-mode__ctx_execute_file "$(cx "$FH/proj/src/app.ts")"
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
