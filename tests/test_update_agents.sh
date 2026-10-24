#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Split out of tests/test_update.sh: /update in an --agents install. Its own install,
# so it runs beside test_update.sh rather than after it.

echo "[test_update_agents] update.sh in an --agents install"
echo ""

# --- Agents mode ---
echo "[agents mode]"
AGENTS_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$AGENTS_DIR"' EXIT
(cd "$AGENTS_DIR" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" --agents "$AGENTS_DIR" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh"

assert_dir_exists "$AGENTS_DIR/.agents" ".agents/ exists after --agents install"
assert_file_exists "$AGENTS_DIR/.agents/bin/update.sh" ".agents/bin/update.sh exists"

(cd "$AGENTS_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/update.sh) > "$QUIET_LOG" 2>&1 || quiet_fail "update.sh"
assert_dir_exists "$AGENTS_DIR/.agents/agents" ".agents/agents/ valid after agents-mode update"
assert_dir_exists "$AGENTS_DIR/.agents/commands" ".agents/commands/ valid after agents-mode update"

# --- Agents mode: an older install's /cleanup (Claude Code only) ---
# --dry-run must report the removal and write nothing; the real update removes it.
echo "[agents mode: Claude-Code-only files]"
tree_sum() { (cd "$1" && find . -path ./.git -prune -o -type f -exec cksum {} + | LC_ALL=C sort -k3 | cksum); }
echo "# /cleanup from an older --agents install" > "$AGENTS_DIR/.agents/commands/cleanup.md"
TREE_BEFORE="$(tree_sum "$AGENTS_DIR")"
DRY_AGENTS="$(cd "$AGENTS_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/update.sh --dry-run 2>&1)"
assert_eq "$TREE_BEFORE" "$(tree_sum "$AGENTS_DIR")" "--dry-run changes no file in an --agents install"
assert_contains "$DRY_AGENTS" "[would remove] .agents/commands/cleanup.md" "--dry-run reports the /cleanup it would remove"
UPDATE_AGENTS="$(cd "$AGENTS_DIR" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .agents/bin/update.sh 2>&1)"
assert_contains "$UPDATE_AGENTS" "[removed] .agents/commands/cleanup.md" "update reports removing /cleanup"
assert_file_not_exists "$AGENTS_DIR/.agents/commands/cleanup.md" "update removes /cleanup from an --agents install"

print_summary
