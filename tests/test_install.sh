#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_install] Installing to temp directory: $TEMP_DIR"

# Initialize a git repo so submodule commands work
(cd "$TEMP_DIR" && git init -q)

# Run install.sh targeting temp dir (use local source for testing)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$TEMP_DIR"

echo ""
echo "[test_install] Verifying installation..."

assert_dir_exists "$TEMP_DIR/.claude" ".claude/ directory exists"
assert_file_exists "$TEMP_DIR/CLAUDE.md" "CLAUDE.md exists"
assert_eq "### Recurring Issues|### Fix Patterns|### Config Conventions" \
  "$(sed -n '/^## Project Learnings/,/^## [^#]/p' "$TEMP_DIR/CLAUDE.md" 2>/dev/null | grep '^### ' | paste -sd'|' - || true)" \
  "CLAUDE.md has the Project Learnings subsections /dream and /diff-review write to"
# docs/ is the kit's own long-form spec. The copy loop takes named .claude/
# subdirectories plus named root files, so a project must not receive it.
assert_dir_not_exists "$TEMP_DIR/docs" "docs/ is not copied into a project"
assert_file_not_exists "$TEMP_DIR/QUICK-START.md" "QUICK-START.md is not copied into a project"
assert_dir_exists "$TEMP_DIR/.claude/agents" ".claude/agents/ directory exists"
assert_dir_exists "$TEMP_DIR/.claude/commands" ".claude/commands/ directory exists"
assert_file_exists "$TEMP_DIR/.claude/skills/SKILL.md" "SKILL.md exists"
assert_json_valid "$TEMP_DIR/.claude/settings.json" "settings.json is valid JSON"

# Count agents
AGENT_COUNT=$(find "$TEMP_DIR/.claude/agents" -name "*.md" | wc -l | tr -d ' ')
assert_eq "15" "$AGENT_COUNT" "Agent count is 15"

# Count commands
CMD_COUNT=$(find "$TEMP_DIR/.claude/commands" -name "*.md" | wc -l | tr -d ' ')
assert_eq "34" "$CMD_COUNT" "Command count is 34"

# The firewall ships its tier record and its generator; without both, a fresh install has
# a policy nothing can describe or lower.
assert_json_valid "$TEMP_DIR/.claude/security.json" ".claude/security.json is valid JSON"
assert_file_exists "$TEMP_DIR/.claude/bin/firewall.sh" ".claude/bin/firewall.sh is installed"
assert_cmd_success "[ -x '$TEMP_DIR/.claude/bin/firewall.sh' ]" ".claude/bin/firewall.sh is executable"
assert_file_exists "$TEMP_DIR/.claude/commands/firewall.md" "/firewall is installed"
assert_eq "relaxed" "$(python3 -c "
import json; print(json.load(open('$TEMP_DIR/.claude/security.json')).get('tier', '__MISSING__'))" 2>/dev/null)" \
  "a fresh install lands on the relaxed tier"

# Check .gitignore was updated
assert_file_exists "$TEMP_DIR/.gitignore" ".gitignore exists"
GITIGNORE_CONTENT="$(cat "$TEMP_DIR/.gitignore")"
assert_contains "$GITIGNORE_CONTENT" ".claude/skills/ext/" ".gitignore contains ext/ entry"
assert_contains "$GITIGNORE_CONTENT" "CLAUDE.local.md" ".gitignore contains CLAUDE.local.md entry"
assert_contains "$GITIGNORE_CONTENT" ".gitmodules" ".gitignore contains .gitmodules (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" "CLAUDE.md" ".gitignore contains CLAUDE.md (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" ".mcp.json" ".gitignore contains .mcp.json (config gitignored by default)"
assert_contains "$GITIGNORE_CONTENT" "solana-ai-kit config" ".gitignore has config markers for /commit-claude-config"

# Check .claude/VERSION exists
assert_file_exists "$TEMP_DIR/.claude/VERSION" ".claude/VERSION file exists"

# Check .claude/bin scripts exist
assert_file_exists "$TEMP_DIR/.claude/bin/update.sh" ".claude/bin/update.sh exists"
assert_file_exists "$TEMP_DIR/.claude/bin/resync.sh" ".claude/bin/resync.sh exists"
assert_file_exists "$TEMP_DIR/.claude/bin/skills.sh" ".claude/bin/skills.sh exists for /add-skill"
assert_file_exists "$TEMP_DIR/.claude/commands/add-skill.md" "/add-skill is installed"

# An unreachable upstream used to exit 128 with nothing on either stream: under set -e
# with pipefail the failing git ls-remote made its assignment fatal, so the fallback to
# main never ran, and a failed clone was swallowed by `| tail -1 || true`. A file:// URL
# to a path that does not exist fails at once and needs no network.
echo "[unreachable upstream]"
UNREACH="$(new_tmp)" || exit 1
UNREACH_RC=0
SOLANA_AI_KIT_UPSTREAM="file:///nonexistent/no-such-repo.git" \
  bash "$SCRIPT_DIR/../install.sh" "$UNREACH" > "$UNREACH/out" 2> "$UNREACH/err" || UNREACH_RC=$?
assert_eq "1" "$UNREACH_RC" "an unreachable upstream exits 1, not 128"
assert_contains "$(cat "$UNREACH/err")" "Could not clone" "an unreachable upstream says why on stderr"
assert_contains "$(cat "$UNREACH/err")" "(main)" "the fallback to main runs when the tag lookup fails"

# A token in SOLANA_AI_KIT_UPSTREAM (a private fork) must not reach the terminal or a CI
# log through our own message; git already keeps it out of its own.
echo "[upstream credentials]"
CREDS="$(new_tmp)" || exit 1
SOLANA_AI_KIT_UPSTREAM="file://tok3n-s3cr3t@/nonexistent/no-such-repo.git" \
  bash "$SCRIPT_DIR/../install.sh" "$CREDS" > "$CREDS/out" 2> "$CREDS/err" || true
assert_contains "$(cat "$CREDS/err")" "Could not clone file:///nonexistent/no-such-repo.git" "the failure names the upstream without its credentials"
assert_file_not_contains "$CREDS/err" "tok3n-s3cr3t" "no credential from the upstream URL reaches stderr"
assert_file_not_contains "$CREDS/out" "tok3n-s3cr3t" "no credential from the upstream URL reaches stdout"

# A local source without .claude/ used to fall through to the network clone silently,
# so an install meant to test a local tree installed whatever GitHub served instead.
echo "[local source without .claude/]"
NOSRC="$(new_tmp)" || exit 1
mkdir -p "$NOSRC/src" "$NOSRC/target"
NOSRC_RC=0
SOLANA_AI_KIT_LOCAL_SRC="$NOSRC/src" SOLANA_AI_KIT_UPSTREAM="file:///nonexistent/no-such-repo.git" \
  bash "$SCRIPT_DIR/../install.sh" "$NOSRC/target" > "$NOSRC/out" 2> "$NOSRC/err" || NOSRC_RC=$?
assert_eq "1" "$NOSRC_RC" "a local source without .claude/ exits 1"
assert_contains "$(cat "$NOSRC/err")" "SOLANA_AI_KIT_LOCAL_SRC=$NOSRC/src has no .claude/" "the refusal names the local source"
assert_file_not_contains "$NOSRC/err" "Could not clone" "it refuses before trying the network"
assert_dir_not_exists "$NOSRC/target/.claude" "nothing is installed"

print_summary
