#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

CMDS_DIR="$REPO_ROOT/.claude/commands"

echo "[test_commands] Checking command frontmatter..."

COUNT=0
for f in "$CMDS_DIR"/*.md; do
  name="$(basename "$f")"
  COUNT=$((COUNT + 1))

  if head -1 "$f" | grep -q "^---"; then
    frontmatter="$(sed -n '/^---$/,/^---$/p' "$f" | head -20 || true)"

    TOTAL=$((TOTAL + 1))
    if grep -q "^description:" <<<"$frontmatter"; then
      echo "  PASS: $name has description:"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $name missing description:"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "  FAIL: $name has no frontmatter"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
  fi
done

echo ""
assert_eq "54" "$COUNT" "Total command count is 54"
assert_file_exists "$CMDS_DIR/firewall.md" "/firewall exists (shows and switches the security tier)"
# /firewall drives the generator; it must not hand-edit the block it regenerates.
assert_file_contains "$CMDS_DIR/firewall.md" "firewall.sh" "firewall.md calls bin/firewall.sh rather than editing settings.json by hand"
# /ship merges PRs, and the firewall lets `gh pr merge` through at Relaxed, so whether it runs
# is the user's typing alone: Claude must not be able to invoke it from its description. Read
# from the frontmatter, since the same words in the body would leave it model-invocable.
SHIP_FRONT="$(awk 'NR==1 && $0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$CMDS_DIR/ship.md")"
assert_eq "disable-model-invocation: true" "$(printf '%s\n' "$SHIP_FRONT" | grep -x 'disable-model-invocation:[[:space:]]*true' || true)" \
  "/ship is user-only (disable-model-invocation: true in its frontmatter)"

echo ""
echo "[test_commands] Checking /explore, the short aliases and composition..."
# Project commands have no alias field, so each short name is a file that has the model read
# its full command and follow it. It must name a target that exists (rep's, report.md, ships
# in its own change) and stay user-only like /explore, which keeps both out of every
# session's listing and leaves /adversarial and /parallel to start only from the user.
# Frontmatter is read on its own, as for /ship above.
front() { awk 'NR==1 && $0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$1" 2>/dev/null || true; }
for pair in adv:adversarial par:parallel rep:report res:research exp:explore; do
  short="${pair%%:*}"; full="${pair#*:}"
  f="$CMDS_DIR/$short.md"
  assert_file_exists "$f" "/$short exists"
  assert_file_contains "$f" "\`.claude/commands/$full.md\`" "/$short forwards to .claude/commands/$full.md"
  assert_file_exists "$CMDS_DIR/$full.md" "/$short's target /$full exists"
  assert_eq "description: \"Short for /$full: " "$(front "$f" | grep -o "^description: \"Short for /$full: " || true)" \
    "/$short's description starts 'Short for /$full:'"
  # Claude Code replaces every \$ARGUMENTS in a command body with the user's text, so a
  # second one, meant to name the target's placeholder, would arrive as that text instead.
  assert_eq "1" "$(grep -o '\$ARGUMENTS' "$f" 2>/dev/null | wc -l | tr -d ' ')" "/$short uses \$ARGUMENTS exactly once"
done
for name in adv par rep res exp explore; do
  assert_eq "disable-model-invocation: true" "$(front "$CMDS_DIR/$name.md" | grep -x 'disable-model-invocation:[[:space:]]*true' || true)" \
    "/$name is user-only (disable-model-invocation: true in its frontmatter)"
  assert_eq "" "$(front "$CMDS_DIR/$name.md" | grep '^model:' || true)" "/$name sets no model: line"
done
EXPLORE="$CMDS_DIR/explore.md"
for label in adversarial parallel serial user; do
  assert_cmd_success "grep -qx -e '- \*\*$label\*\*: .*' '$EXPLORE'" "explore.md's triage rubric defines the $label label"
done
assert_file_not_contains "$EXPLORE" "**single**" "explore.md's rubric says serial, not the calibration run's single"
assert_file_contains "$EXPLORE" "## Triage rubric" "explore.md keeps the rubric under the heading its Triage section names"
assert_file_contains "$EXPLORE" 'model: "sonnet"' "explore.md runs the triage on Sonnet"
for f in research.md plan-work.md review-round.md; do
  assert_file_contains "$CMDS_DIR/$f" "(explore.md#triage)" "$f triages its items with /explore's rubric before the adversarial pass"
done
assert_file_contains "$CMDS_DIR/parallel.md" "## Composition" "parallel.md carries the composition rules"
assert_file_contains "$CMDS_DIR/adversarial.md" "(parallel.md#composition)" "adversarial.md points at /parallel's composition rules"
for f in parallel.md adversarial.md; do
  assert_file_not_contains "$CMDS_DIR/$f" "that command did not load" "$f runs a call that did not load instead of skipping it"
done

echo ""
echo "[test_commands] Checking setup-mcp.md covers every .env.example key..."

ENV_EXAMPLE="$REPO_ROOT/.env.example"
SETUP_MCP="$CMDS_DIR/setup-mcp.md"

if [ -f "$ENV_EXAMPLE" ] && [ -f "$SETUP_MCP" ]; then
  # Counted, then asserted non-zero. Both files existing is not the same as the producer
  # finding keys in one of them: the grep is anchored on `^KEY=`, so .env.example moving to
  # the `export KEY=` form (or any other style change) empties the loop and every key is
  # reported as covered without one being read. Demonstrated by rewriting .env.example to
  # `export KEY=` with HELIUS_API_KEY stripped out of setup-mcp.md: 62 checks became 52
  # and the suite stayed green.
  ENV_KEYS=0
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    ENV_KEYS=$((ENV_KEYS + 1))
    assert_file_contains "$SETUP_MCP" "$key" "setup-mcp.md mentions .env.example key: $key"
  done < <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$ENV_EXAMPLE" | sed 's/=$//')
  assert_cmd_success "[ $ENV_KEYS -gt 0 ]" ".env.example has KEY= lines for the coverage check to read ($ENV_KEYS found)"
else
  assert_eq "0" "1" ".env.example and setup-mcp.md both exist for drift check"
fi

echo ""
echo "[test_commands] Checking /dream and /diff-review write to the Project Learnings subsections in CLAUDE-solana.md..."
for sub in "### Recurring Issues" "### Fix Patterns" "### Config Conventions"; do
  assert_file_contains "$REPO_ROOT/CLAUDE-solana.md" "$sub" "CLAUDE-solana.md has '$sub'"
  assert_file_contains "$CMDS_DIR/dream.md" "\`$sub\`" "dream.md names '$sub'"
done
assert_file_contains "$CMDS_DIR/diff-review.md" '`### Recurring Issues`' "diff-review.md files repeated mistakes under ### Recurring Issues"
assert_file_contains "$CMDS_DIR/diff-review.md" '`### Config Conventions`' "diff-review.md files confirmed conventions under ### Config Conventions"
assert_file_contains "$CMDS_DIR/dream.md" "if it is missing (never a differently named one)" "dream.md creates a missing subsection instead of inventing one"

echo ""
echo "[test_commands] Checking --agents install-mode support..."
assert_file_contains "$CMDS_DIR/resync.md" ".agents/bin" "resync.md supports --agents installs (.agents/bin)"
assert_file_contains "$CMDS_DIR/update.md" ".agents/bin" "update.md supports --agents installs (.agents/bin)"

echo ""
echo "[test_commands] Checking Anchor error codes are decoded by discriminant, not declaration order..."
for f in test-rust.md test-ts.md test-and-fix.md; do
  assert_file_contains "$CMDS_DIR/$f" '`offset` (default 6000) + discriminant' "$f decodes #[error_code] ids as offset + discriminant"
  assert_file_not_contains "$CMDS_DIR/$f" "declaration order" "$f does not claim declaration order"
done

print_summary
