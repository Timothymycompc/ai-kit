#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

echo "[test_onchain_guard] localnet silent at Relaxed, exact hosts only (D-C8/item 6)"

GUARD="$REPO_ROOT/.claude/hooks/onchain-guard.sh"
assert_file_exists "$GUARD" "the guard ships"
assert_file_exists "$REPO_ROOT/.claude/hooks/onchain-guard.awk" "the decision awk ships"

# verdict <tier> <command> -> deny | ask | silent
# Headless forced off so an interactive `ask` is visible; the write gates go silent
# headless by design, which is a different property (covered in test_hooks.sh).
verdict() {
  local pay out
  pay="$(python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$2")"
  out="$(cd "$REPO_ROOT" && printf '%s' "$pay" | CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    KIT_FIREWALL_TIER="$1" KIT_FIREWALL_HEADLESS=0 sh "$GUARD" 2>/dev/null)"
  case "$out" in *'"deny"'*) echo deny ;; *'"ask"'*) echo ask ;; *) echo silent ;; esac
}
want() {
  local got; got="$(verdict "$1" "$4")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$2" ]; then echo "  PASS: [$1] $2  $3"; PASS=$((PASS + 1))
  else echo "  FAIL: [$1] want $2, got $got  $3  ::  $4"; FAIL=$((FAIL + 1)); fi
}

# ── exact local hosts: silent at Relaxed, ask at Medium and High ────────────
# A local validator is day-to-day work, so Relaxed must not prompt on it. Medium and
# High still ask (an interactive prompt, ignored headless), so the exact-host test is
# what this change turns on. Hosts: localhost, 127.0.0.1, ::1, 0.0.0.0 (with or without
# a port), and the solana CLI's own `l` / `localnet` shorthands.
echo "[exact local hosts: silent at Relaxed]"
LOCAL=(
  "solana program deploy --url http://localhost:8899 p.so"
  "solana program deploy --url http://127.0.0.1:8899 p.so"
  "solana program deploy --url http://[::1]:8899 p.so"
  "solana program deploy --url http://0.0.0.0:8899 p.so"
  "solana program deploy --url http://localhost p.so"
  "solana program deploy --url https://127.0.0.1 p.so"
  "solana program deploy --url localhost p.so"
  "solana program deploy -ul p.so"
  "solana program deploy --url l p.so"
  "anchor deploy --provider.cluster localnet"
  "solana program deploy --url http://LOCALHOST:8899 p.so"
)
for C in "${LOCAL[@]}"; do
  want relaxed silent "a loopback the agent runs itself" "$C"
  want medium  ask    "Medium still prompts on a local write"   "$C"
  want high    ask    "High still prompts on a local write"     "$C"
done

# ── the *localhost* mislabel is closed ──────────────────────────────────────
# The old glob matched any host CONTAINING "localhost"/"127.0.0.1", so an
# attacker-controlled host was labelled localnet and (post-change) would be waved
# through silently at Relaxed. These are NOT exact local hosts, so they fall to the
# possibly-mainnet branch, which ASKS at every tier — never silent at Relaxed.
echo "[attacker hosts that merely contain a loopback string: not localnet]"
ATTACKER=(
  "solana program deploy --url https://localhost.attacker.example p.so"
  "solana program deploy --url http://127.0.0.1.attacker.example p.so"
  "solana program deploy --url http://localhost@evil.example p.so"
  "solana program deploy --url http://evil.example/localhost p.so"
  "solana program deploy --url http://localhost.evil.example:8899 p.so"
)
for C in "${ATTACKER[@]}"; do
  want relaxed ask "an external host is possibly-mainnet, not localnet" "$C"
done

# ── the rest of the matrix is unchanged by this item ────────────────────────
# A mainnet write still gates (ask below High, deny at High); devnet/testnet still
# ask; the irreversible set still denies. Spot-checks so a localnet change that
# leaked into these shows here.
echo "[the rest of the on-chain matrix is untouched]"
want relaxed ask  "mainnet asks at Relaxed"       "solana program deploy --url https://api.mainnet-beta.solana.com p.so"
want high    deny "mainnet denied at High"        "solana program deploy --url https://api.mainnet-beta.solana.com p.so"
want relaxed ask  "devnet asks"                   "solana program deploy --url https://api.devnet.solana.com p.so"
want relaxed deny "the irreversible set denies"   "solana program deploy --url http://localhost:8899 --final p.so"

# A command that names no on-chain write stays silent (the guard's prefilter).
echo "[no on-chain verb: silent]"
want relaxed silent "a local build is not an on-chain write" "cargo build-sbf"
want relaxed silent "a solana query is not a write"          "solana balance --url http://localhost:8899"

# ── an MCP call's own tool_name or command argument changes nothing ─────────
# kit_parse reads the tool name from the payload's top level and always rebuilds an
# MCP call's command from the fields the tool runs. A context-mode call carrying a
# tool_name or command argument of its own skipped that rebuild, and a mainnet deploy
# in its code met no gate at any tier.
echo "[an MCP call's own tool_name or command argument: the mainnet gate still holds]"
# raw <tier> <headless> <payload> -> deny | ask | silent
raw() {
  local out
  out="$(cd "$REPO_ROOT" && printf '%s' "$3" | CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    KIT_FIREWALL_TIER="$1" KIT_FIREWALL_HEADLESS="$2" sh "$GUARD" 2>/dev/null)"
  case "$out" in *'"deny"'*) echo deny ;; *'"ask"'*) echo ask ;; *) echo silent ;; esac
}
# mcp_pay <code> <extra tool_input JSON> [tool_input first: 1]
mcp_pay() {
  python3 -c '
import json, sys
ti = {"language": "shell", "code": sys.argv[1]}; ti.update(json.loads(sys.argv[2]))
top = [("hook_event_name", "PreToolUse"), ("tool_name", "mcp__context-mode__ctx_execute")]
pairs = [("tool_input", ti)] + top if sys.argv[3] == "1" else top + [("tool_input", ti)]
print(json.dumps(dict(pairs)))' "$1" "$2" "${3:-0}"
}
DEPLOY="solana program deploy --url mainnet-beta x.so"
for EXTRA in '{}' '{"tool_name":"x"}' '{"tool_name":"Bash"}' '{"command":"ls"}'; do
  for FIRST in 0 1; do
    P="$(mcp_pay "$DEPLOY" "$EXTRA" "$FIRST")"
    assert_eq deny "$(raw relaxed 1 "$P")" "headless Relaxed denies a mainnet deploy in ctx_execute carrying $EXTRA (tool_input first: $FIRST)"
    assert_eq ask  "$(raw relaxed 0 "$P")" "interactive Relaxed asks on it (tool_input first: $FIRST, $EXTRA)"
    assert_eq deny "$(raw high 0 "$P")" "High denies it (tool_input first: $FIRST, $EXTRA)"
  done
done

print_summary
