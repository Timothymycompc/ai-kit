#!/bin/sh
# secrets-guard.sh — PreToolUse(Bash): block reads of credential stores, key
# material and wallet vaults.  Active at every tier, including Off, because the
# never-allowed set does not vary by tier.
#
# The invariant, and the whole reason this file replaced an inline grep:
#
#   a rule may match only a path in ARGUMENT POSITION of a command that would
#   touch that path — never the command's prose.
#
# Writing documentation, a commit message, an issue body or a test corpus that
# names a protected path is not access to it and must never be blocked.  The
# inline predecessor grepped the whole command string and produced five
# independent false positives in one session (a diagnostic `ls -l` on a wallet,
# a `gh issue create` body, the firewall spec itself, two test corpora), to the
# point where two shipped commands documented workarounds.
#
# Decisions come from an awk pass that quote-aware splits the command into
# statements and pipeline stages, strips heredoc bodies, finds each stage's real
# command word past env assignments and wrappers, and only then looks at that
# command's arguments.  The splitter now lives in lib-tokenize.awk, shared with
# the other guards (issue #138); the decision logic is secrets-guard.awk.
#
# stdin: PreToolUse JSON.  Exit 0 = silent, exit 2 = blocked.

set -u
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HOOK_DIR/lib-headless.sh"

KIT_INPUT=$(cat)
kit_parse
[ -n "$KIT_CMD" ] || exit 0

# ---- Shell -c: a hard block, and the one line it lets through.
#
# Every `bash|sh|zsh|dash|ksh -c` is denied below (SHELLC) at every tier, Off
# included: a -c string is a program no permission rule can read.  In a full install
# the permission layer denies `sh -c *`, `bash -c *`, `bash -lc *` and `zsh -c *` at
# every tier too (DENY_WRAPPERS in firewall.sh), so there this block is a second
# layer; in a plugin install, which carries no permission rules, it is the only one.
#
# The one exception is memsearch's memory-recall collection-derivation line, matched
# WHOLE: not a prefix, not a pattern, nothing prepended or appended, so nothing can
# ride a second command in behind it.  The string is memory-recall/SKILL.md's inline
# command verbatim, with `${CLAUDE_PLUGIN_ROOT}` and `$MEMSEARCH_DIR` left as written;
# tests/test_secrets_guard.sh pins it and the near-misses.  It does not make recall
# work where the permission rules are in force: Claude Code checks a skill's inline
# command against them, and evaluates deny rules whatever a hook returns, so
# `Bash(bash -c *)` still stops the skill there.  That needs a change on memsearch's
# side.  kit_allow rather than a silent exit, because a silent exit hands the call to
# the normal permission flow, which prompts for it wherever no rule decides.
MEMSEARCH_CMD=$(cat <<'KIT_MEMSEARCH_EOF'
bash -c 'if [ -n "${MEMSEARCH_DIR:-}" ]; then bash "${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh" "$MEMSEARCH_DIR"; else root=$(git rev-parse --show-toplevel 2>/dev/null || true); if [ -n "$root" ]; then bash "${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh" "$root"; else bash "${CLAUDE_PLUGIN_ROOT}/scripts/derive-collection.sh"; fi; fi'
KIT_MEMSEARCH_EOF
)
if [ "$KIT_CMD" = "$MEMSEARCH_CMD" ]; then
  kit_allow "memsearch memory-recall collection-derivation line (the one shell -c this guard lets through)."
fi

[ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/secrets-guard.awk" ] || exit 0

# The regex travels in the environment, not through -v: awk processes escape
# sequences in -v assignments, which mangles \. and \( differently per awk.
VERDICT=$(printf '%s\n' "$KIT_CMD" | KIT_VAULT_RE="$(kit_vault_re)" KIT_LANG="${KIT_LANG-}" \
  awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/secrets-guard.awk" 2>/dev/null) || exit 0

case $VERDICT in
  DEEP*)
    # Fail closed, like the size cap: a command whose code strings nest deeper than
    # the hooks can read in time is refused, not read in part and let through.
    kit_deny_deep
    ;;
  SHELLC*)
    kit_deny "runs a shell with -c (bash, sh, zsh, dash or ksh), which executes an arbitrary program the firewall cannot inspect. It is denied at every tier. Run the command directly instead of wrapping it in a shell -c."
    ;;
  WIPE*)
    # Destroying key material, not reading it, so the "use solana address instead"
    # trailer would be nonsense here. The route around is the flag, not the command.
    kit_deny "${VERDICT#WIPE } overwrites the default wallet keypair at ~/.config/solana/id.json, and a Solana keypair cannot be recovered without its seed phrase. Drop --force to keep the existing wallet (solana-keygen refuses to overwrite one without it, so the command works unchanged where no wallet exists yet), or pass -o <path> to write somewhere else. If the user really means to replace their default wallet, they run it themselves."
    ;;
  DENY*)
    kit_deny "${VERDICT#DENY } — reading private keys, wallet vaults or credentials is not allowed. Use \`solana address\` for the pubkey; ask the user to run anything that needs the secret."
    ;;
esac
exit 0
