#!/usr/bin/env bash
set -euo pipefail

# The safe-ai-skill project policy (.safe-ai-skill/policy.yaml): shipped, installed
# once, never overwritten, added by /update when missing, and gitignored with the
# rest of the kit config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

POLICY=".safe-ai-skill/policy.yaml"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_safe_ai_skill_policy] safe-ai-skill project policy"
echo ""

yaml_json() {  # yaml_json <file>: the YAML as JSON; status 2 when no YAML parser is installed
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$1"
  elif python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$1"
  else
    return 2
  fi
}
new_project() { mkdir -p "$TEMP_DIR/$1" && git -C "$TEMP_DIR/$1" init -q && echo "$TEMP_DIR/$1"; }
install_kit() { SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$@" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh $*"; }
update_kit() { (cd "$1" && shift && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh "$@" 2>&1); }
config_block() { sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$1/.gitignore"; }

echo "[template]"
assert_file_exists "$REPO_ROOT/$POLICY" "The kit ships $POLICY"
status=0
JSON="$(yaml_json "$REPO_ROOT/$POLICY")" || status=$?
if [ "$status" -eq 2 ]; then
  echo "  SKIP: no YAML parser (ruby or python3 with PyYAML) to parse $POLICY"
else
  assert_eq "0" "$status" "$POLICY parses as YAML"
  assert_eq "True" "$(printf '%s' "$JSON" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(sorted(d) == ["secrets", "supply_chain"] and d["supply_chain"] == {"verify_skills_dirs": [".claude/skills"]} and sorted(d["secrets"]) == ["allow_read_globs"])')" \
    "It sets only supply_chain.verify_skills_dirs, to [.claude/skills], and secrets.allow_read_globs"
  # The dotenv allows hand the .env decision to the firewall tier, so they must name
  # exactly the files firewall.sh's DENY_ENV_WRITE and DENY_ENV_READ name: a file allowed
  # here but missing there would be readable even at High.
  SYNC="$(printf '%s' "$JSON" | REPO_ROOT="$REPO_ROOT" python3 -c '
import json, os, re, sys
allow = json.load(sys.stdin)["secrets"]["allow_read_globs"]
src = open(os.path.join(os.environ["REPO_ROOT"], ".claude/bin/firewall.sh")).read()
env_files = re.findall(r"\"([^\"]+)\"", re.search(r"ENV_FILES = \[(.*?)\]", src, re.S).group(1))
dotenv = [a for a in allow if a not in ("**/.env.example", "**/.env.schema")]
print("in-sync" if dotenv == env_files else "allow=%s fw=%s" % (dotenv, env_files))')"
  assert_eq "in-sync" "$SYNC" "the dotenv allows name exactly firewall.sh's ENV_FILES, in order"
  # The default's deny_read_globs has **/.env.*, which matches .env.schema; an allow glob
  # wins over it. A list replaces the default's instead of merging, so .env.example has to
  # be restated or the override would make it unreadable.
  ALLOW="$(printf '%s' "$JSON" | python3 -c 'import json, sys; print(" ".join(json.load(sys.stdin).get("secrets", {}).get("allow_read_globs", [])))')"
  assert_contains "$ALLOW" "**/.env.schema" "secrets.allow_read_globs lets the agent read .env.schema"
  assert_contains "$ALLOW" "**/.env.example" "...and keeps **/.env.example, which a replacing list would otherwise drop"
fi
assert_file_not_contains "$REPO_ROOT/$POLICY" "verify_ext_submodules:" "verify_ext_submodules stays at its default (false would scan ext/ as one skill)"

echo "[install.sh]"
P1="$(new_project default)"
install_kit "$P1"
assert_file_exists "$P1/$POLICY" "install.sh writes $POLICY"
assert_eq "" "$(diff "$REPO_ROOT/$POLICY" "$P1/$POLICY" 2>&1 || true)" "...as a copy of the kit's template"
assert_contains "$(config_block "$P1")" ".safe-ai-skill/" "The gitignore config block lists .safe-ai-skill/"
printf 'supply_chain:\n  verify_skills_dirs: []\n' > "$P1/$POLICY"
install_kit "$P1"
assert_file_contains "$P1/$POLICY" "verify_skills_dirs: []" "Re-running install.sh keeps the project's own policy"
assert_eq "1" "$(config_block "$P1" | grep -cxF '.safe-ai-skill/')" "...and lists .safe-ai-skill/ once"

echo "[install.sh --agents]"
P2="$(new_project agents)"
install_kit --agents "$P2"
assert_file_not_exists "$P2/$POLICY" "--agents writes no policy (safe-ai-skill's hooks run in Claude Code only)"
assert_eq "" "$(config_block "$P2" | grep -xF '.safe-ai-skill/' || true)" "...and does not gitignore it"

echo "[gitignore backfill]"
P3="$(new_project backfill)"
printf '# >>> solana-ai-kit config — gitignored by default; run /commit-claude-config to version it >>>\n.gitmodules\n.claude/\nCLAUDE.md\n.mcp.json\n# <<< solana-ai-kit config <<<\n' > "$P3/.gitignore"
install_kit "$P3"
assert_contains "$(config_block "$P3")" ".safe-ai-skill/" "install.sh adds .safe-ai-skill/ to a config block written by an older install"

echo "[update.sh]"
P4="$(new_project update)"
install_kit "$P4"
rm -rf "$P4/.safe-ai-skill"
grep -vxF '.safe-ai-skill/' "$P4/.gitignore" > "$TEMP_DIR/gitignore" && cp "$TEMP_DIR/gitignore" "$P4/.gitignore"
DRY="$(update_kit "$P4" --dry-run)"
assert_contains "$DRY" "[would create] $POLICY" "update.sh --dry-run reports the missing policy"
assert_contains "$DRY" "[would update] .gitignore" "...and the gitignore entry it would add"
assert_file_not_exists "$P4/$POLICY" "...and writes nothing"
OUT="$(update_kit "$P4")"
assert_contains "$OUT" "[created] $POLICY" "update.sh adds the policy to an install that lacks it"
assert_eq "" "$(diff "$REPO_ROOT/$POLICY" "$P4/$POLICY" 2>&1 || true)" "...as a copy of the kit's template"
assert_contains "$(config_block "$P4")" ".safe-ai-skill/" "...and gitignores it with the kit config"
printf 'supply_chain:\n  verify_skills_dirs: []\n' > "$P4/$POLICY"
OUT="$(update_kit "$P4")"
assert_file_contains "$P4/$POLICY" "verify_skills_dirs: []" "update.sh keeps an edited policy"
assert_contains "$OUT" "[notice] $POLICY was edited, so it was kept" "...and says safe-ai-skill still denies .env there"
# An unedited copy of a version the kit shipped earlier is still kit-owned, so /update
# refreshes it: how the dotenv allows reach existing installs. Needs the old blob.
if OLD_POLICY="$(git -C "$REPO_ROOT" cat-file -p 636f1003bb0228e11136f8d78c284d8ce3181eec 2>/dev/null)"; then
  printf '%s\n' "$OLD_POLICY" > "$P4/$POLICY"
  DRY="$(update_kit "$P4" --dry-run)"
  assert_contains "$DRY" "[would update] $POLICY (unedited copy" "update.sh --dry-run reports refreshing an unedited old policy"
  OUT="$(update_kit "$P4")"
  assert_contains "$OUT" "[updated] $POLICY (unedited copy" "update.sh refreshes an unedited old policy"
  assert_eq "" "$(diff "$REPO_ROOT/$POLICY" "$P4/$POLICY" 2>&1 || true)" "...to the kit's current template"
  OUT="$(update_kit "$P4")"
  assert_eq "" "$(printf '%s\n' "$OUT" | grep -F "$POLICY" || true)" "...and a current copy is not mentioned again"
else
  echo "  SKIP: the old-policy refresh needs the kit's git history (shallow clone)"
fi

print_summary
