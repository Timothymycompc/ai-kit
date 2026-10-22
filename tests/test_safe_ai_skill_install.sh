#!/usr/bin/env bash
set -euo pipefail

# install.sh installs the safe-ai-skill plugin in a full install. settings.json only
# enables it: Claude Code installs a plugin from an external source only when each user
# runs the install. A fake `claude` first on PATH records every call, and an isolated
# CLAUDE_CONFIG_DIR stands in for Claude Code's install list, so no real install runs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_safe_ai_skill_install] install.sh installs the safe-ai-skill plugin"
echo ""

BIN="$TEMP_DIR/bin" && mkdir -p "$BIN"
LOG="$TEMP_DIR/claude.log"
cat > "$BIN/claude" <<'EOF'
#!/bin/sh
printf '%s :: %s\n' "$PWD" "$*" >> "$CLAUDE_FAKE_LOG"
cat >> "$CLAUDE_FAKE_LOG.stdin"
case "$*" in
  "plugin install safe-ai-skill@stbr --scope project")
    if [ -n "${CLAUDE_FAKE_FAIL_FIRST:-}" ] && [ ! -e "$CLAUDE_FAKE_LOG.failed" ]; then
      : > "$CLAUDE_FAKE_LOG.failed"
      echo "Plugin safe-ai-skill not found in marketplace stbr" >&2
      exit 1
    fi
    echo "Successfully installed plugin: safe-ai-skill@stbr (scope: project)" ;;
  "plugin marketplace add "*) echo "Successfully added marketplace: stbr" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/claude"
# Git Bash on native Windows, and 32-bit ARM Linux: safe-ai-skill has no engine build
# for either.
WINBIN="$TEMP_DIR/winbin" && mkdir -p "$WINBIN"
printf '#!/bin/sh\n[ "$1" = -s ] && echo MINGW64_NT-10.0-26100 || echo x86_64\n' > "$WINBIN/uname"
chmod +x "$WINBIN/uname"
ARMBIN="$TEMP_DIR/armbin" && mkdir -p "$ARMBIN"
printf '#!/bin/sh\n[ "$1" = -s ] && echo Linux || echo armv7l\n' > "$ARMBIN/uname"
chmod +x "$ARMBIN/uname"

N=0
# run_install [VAR=value ...] -- [install.sh args]: installs into a fresh project and sets
# P to it and OUT to the output. stdin carries a line claude must never read: under
# `curl | bash` the script itself is stdin.
run_install() {
  local vars=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  N=$((N + 1)); P="$TEMP_DIR/p$N"
  mkdir -p "$P" && git -C "$P" init -q
  rm -f "$LOG" "$LOG.stdin" "$LOG.failed"
  OUT="$(printf 'NOT-FOR-CLAUDE\n' | env PATH="$BIN:$PATH" CLAUDE_FAKE_LOG="$LOG" CLAUDE_CONFIG_DIR="$TEMP_DIR/cc$N" \
    SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" ${vars[@]+"${vars[@]}"} bash "$REPO_ROOT/install.sh" "$@" "$P" 2>&1)" || true
}
calls() { [ -f "$LOG" ] && cat "$LOG" || true; }
SAS_CMD="claude plugin install safe-ai-skill@stbr --scope project"

echo "[local source: not installed, command printed]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL= --
assert_eq "" "$(calls)" "A local-source install never calls claude (tests and offline runs)"
assert_contains "$OUT" "safe-ai-skill is enabled but not installed" "...and the closing box says the plugin is not installed"
assert_contains "$OUT" "$SAS_CMD" "...with the command that installs it"

echo "[installed by default]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 --
assert_eq "p$N :: plugin install safe-ai-skill@stbr --scope project" "$(calls | sed -E 's#^.*/([^/]+) :: #\1 :: #')" \
  "install.sh runs claude plugin install safe-ai-skill@stbr --scope project, in the project"
assert_eq "1" "$(calls | wc -l | tr -d ' ')" "...once"
assert_contains "$OUT" "Installed safe-ai-skill" "...reports it"
assert_contains "$OUT" "Security plugin: safe-ai-skill is installed." "...and the closing box says so"
assert_eq "" "$(cat "$LOG.stdin" 2>/dev/null || true)" "claude never reads install.sh's stdin"

echo "[marketplace registered on first failure]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 CLAUDE_FAKE_FAIL_FIRST=1 --
assert_contains "$(calls)" "plugin marketplace add https://github.com/solanabr/ai-kit.git" "A failed first install registers the kit's marketplace"
assert_eq "2" "$(calls | grep -c 'plugin install safe-ai-skill@stbr --scope project')" "...then installs again"
assert_contains "$OUT" "Security plugin: safe-ai-skill is installed." "...and reports the plugin installed"

echo "[already installed]"
N1=$((N + 1)); mkdir -p "$TEMP_DIR/cc$N1/plugins" "$TEMP_DIR/p$N1"
printf '{"version": 2, "plugins": {"safe-ai-skill@stbr": [{"scope": "project", "projectPath": "%s"}]}}\n' "$TEMP_DIR/p$N1" \
  > "$TEMP_DIR/cc$N1/plugins/installed_plugins.json"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 --
assert_eq "" "$(calls)" "A plugin Claude Code already records for this project is not installed again"
assert_contains "$OUT" "Security plugin: safe-ai-skill is installed." "...and is reported installed"

echo "[--no-safe-ai-skill]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 -- --no-safe-ai-skill
assert_eq "" "$(calls)" "--no-safe-ai-skill skips the plugin install"
assert_contains "$OUT" "safe-ai-skill skipped" "...and the closing box says so, with the command"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=0 --
assert_eq "" "$(calls)" "SOLANA_AI_KIT_SAFE_AI_SKILL=0 skips it too"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=false --
assert_eq "" "$(calls)" "...and so does =false"

echo "[unsupported platform]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 PATH="$WINBIN:$BIN:$PATH" --
assert_eq "" "$(calls)" "On native Windows, where it would block every tool call, it is not installed"
assert_contains "$OUT" "has no engine build for MINGW64_NT-10.0-26100/x86_64" "...and install.sh says why"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 PATH="$ARMBIN:$BIN:$PATH" --
assert_eq "" "$(calls)" "On a CPU it ships no build for (32-bit ARM Linux), it is not installed either"
assert_contains "$OUT" "has no engine build for Linux/armv7l" "...and install.sh names the platform"

echo "[--agents]"
run_install SOLANA_AI_KIT_SAFE_AI_SKILL=1 -- --agents
assert_eq "" "$(calls)" "An --agents install never installs it: its hooks are Claude Code only"
assert_eq "0" "$(printf '%s\n' "$OUT" | grep -c 'Security plugin:' || true)" "...and its closing box does not mention it"

print_summary
