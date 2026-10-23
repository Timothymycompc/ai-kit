#!/bin/sh
# decisions-guard.sh — PreToolUse: only the user's main session writes the decision
# record. A subagent that runs `decisions.sh add` or `supersede`, or points Write, Edit,
# MultiEdit or NotebookEdit into the record directory, is refused (exit 2).
#
# Whatever the record holds is handed to every agent as the user's decision
# (decisions-inject.sh, decisions-push.sh), so an entry an agent wrote would speak for
# the user to every agent after it. An agent testing the helper by hand once wrote six
# entries into a real record, a standing order among them. Subagents propose instead:
# their reports carry Decisions made and Decisions needed, and the main session records
# what the user confirms.
#
# A subagent is told apart by its payload: Claude Code adds agent_id to a hook that
# fires inside a subagent or an in-process teammate, never to the main session's, so
# the main session passes before anything else is read. Reading the record, and the
# helper's readers (in-force, hash, export, path), stay open to every agent. Active at
# every tier, Off included: who may speak for the user does not vary with the firewall.
#
# It reads the helper's command line the way the firewall guards read theirs, through
# lib-tokenize.awk, so prose that names the helper (a grep, a commit message, a heredoc
# document) is not a call. A file tool's path is resolved first, `..` and linked
# directories included, and compared without case, since a filesystem that folds case
# opens the same directory either way. It guards the expected routes, not every route:
# it is not a sandbox.
#
# stdin: PreToolUse JSON.  Exit 0 = silent, exit 2 = blocked.

CDPATH=
START=$PWD
INPUT=$(cat)

case $INPUT in
  *'"agent_id"'* | *'"agentId"'*) ;;
  *) exit 0 ;;
esac

# json_str <key> — the string value of a top-level "<key>" in the payload, in V.
# (Identical in decisions-inject.sh and decisions-push.sh; tests/test_decisions_guard.sh checks.)
#
# The values read here are ids and names, so a value runs to its closing quote with no
# escapes to decode, and plain parameter expansion reads it without spawning anything.
# A key the payload names twice is ambiguous, since a tool's input can carry the same
# word, and goes to jq; without jq it reads as absent.
json_str() {
  case $INPUT in
    *"\"$1\""*"\"$1\""*)
      command -v jq >/dev/null 2>&1 || return 1
      V=$(printf '%s' "$INPUT" | jq -r --arg k "$1" '.[$k] // empty | strings' 2>/dev/null)
      [ -n "$V" ]
      return ;;
    *"\"$1\""*) V=${INPUT#*\"$1\"} ;;
    *) return 1 ;;
  esac
  V=${V#"${V%%[! ]*}"}
  case $V in :*) V=${V#:} ;; *) return 1 ;; esac
  V=${V#"${V%%[! ]*}"}
  case $V in \"*) V=${V#\"}; V=${V%%\"*} ;; *) return 1 ;; esac
  [ -n "$V" ]
}

# common_dir — the clone's git common directory, in G.
# (Identical in decisions-inject.sh and decisions-push.sh; tests/test_decisions_guard.sh checks.)
#
# Found without running git for the two usual layouts, a checkout's .git directory and
# a linked worktree's .git file, because decisions-push.sh does this on every tool call
# and git rev-parse costs more than the rest of that hook together. Walks up from the
# project root, as git does. GIT_DIR and GIT_COMMON_DIR are git's to interpret.
common_dir() {
  if [ -n "${GIT_DIR-}${GIT_COMMON_DIR-}" ]; then
    G=$(cd -- "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null \
      && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    [ -n "$G" ]
    return
  fi
  D=${CLAUDE_PROJECT_DIR:-$PWD}
  while :; do
    if [ -d "$D/.git" ]; then G=$D/.git; break; fi
    if [ -f "$D/.git" ]; then
      G=; IFS= read -r G < "$D/.git" || [ -n "$G" ] || return 1
      G=${G#gitdir: }
      case $G in /*) ;; *) G=$D/$G ;; esac
      break
    fi
    case $D in */*[!/]*) D=${D%/*}; [ -n "$D" ] || D=/ ;; *) return 1 ;; esac
  done
  if [ -f "$G/commondir" ]; then
    C=; IFS= read -r C < "$G/commondir" || [ -n "$C" ] || return 1
    case $C in /*) G=$C; C= ;; esac
    # git writes it as ../.. from the worktree's own directory: walk up rather than
    # append, so a path quoted to an agent reads plainly.
    while :; do
      case $C in
        ../*) C=${C#../}; G=${G%/*} ;;
        ..) C=; G=${G%/*} ;;
        *) break ;;
      esac
    done
    [ -z "$C" ] || G=$G/$C
  fi
}

# lib — source lib-headless.sh once, for kit_parse, kit_field and kit_deny. Only a
# call that may be refused gets this far, so its cost stays off every other one.
lib() {
  [ -z "${HOOK_DIR-}" ] || return 0
  case $0 in /*) HOOK_DIR=$0 ;; *) HOOK_DIR=$START/$0 ;; esac
  HOOK_DIR=${HOOK_DIR%/*}
  [ -f "$HOOK_DIR/lib-headless.sh" ] || { HOOK_DIR=; return 1; }
  . "$HOOK_DIR/lib-headless.sh"
  KIT_INPUT=$INPUT
  command -v jq >/dev/null 2>&1 && KIT_HAVE_JQ=1 || KIT_HAVE_JQ=
}

deny() {
  if lib; then kit_deny "$1"; fi
  printf '%s\n' "🛑 Blocked: $1" >&2
  exit 2
}

REPORT="Put it in your report under Decisions made or Decisions needed, and the main session records what the user confirms."

# physical <path> — <path> made absolute from the session's directory, `.` and `..`
# folded the way a path library folds them, then its longest existing directory
# resolved through the filesystem (cd -P, so links and /tmp -> /private/tmp), in Q.
physical() {
  _i=$1 Q=
  case $_i in /*) ;; *) _i=$START/$_i ;; esac
  while [ -n "$_i" ]; do
    case $_i in */*) _c=${_i%%/*}; _i=${_i#*/} ;; *) _c=$_i; _i= ;; esac
    case $_c in '' | .) ;; ..) Q=${Q%/*} ;; *) Q=$Q/$_c ;; esac
  done
  _d=$Q _r=
  while [ -n "$_d" ]; do
    if cd -P -- "$_d" 2>/dev/null; then
      case $PWD in /) Q=${_r:-/} ;; *) Q=$PWD$_r ;; esac
      return 0
    fi
    _r=/${_d##*/}$_r
    _d=${_d%/*}
  done
  Q=${_r:-/}
}

# edit_target — Write, Edit, MultiEdit, NotebookEdit: refuse a path inside the record.
# The path is read where the payload first names its key, which for these tools is
# their input: text inside a string carries its quotes escaped, so "<key>" with its
# own quotes only ever stands for a key. A path holding an escape is decoded by
# lib-headless.sh instead. Paths that never name the directory pass at once.
edit_target() {
  P=
  for _k in file_path notebook_path filePath notebookPath; do
    case $INPUT in *"\"$_k\""*) ;; *) continue ;; esac
    _v=${INPUT#*\"$_k\"}
    _v=${_v#"${_v%%[! ]*}"}
    case $_v in :*) _v=${_v#:} ;; *) continue ;; esac
    _v=${_v#"${_v%%[! ]*}"}
    case $_v in \"*) _v=${_v#\"} ;; *) continue ;; esac
    case ${_v%%\"*} in
      *\\*) lib && P=$(kit_field "$_k") || P= ;;
      *) P=${_v%%\"*} ;;
    esac
    [ -z "$P" ] || break
  done
  case $P in *[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn][Ss]*) ;; *) return 0 ;; esac
  common_dir || return 0
  physical "$G"
  REC=$Q/decisions
  physical "$P"
  KIT_A=$Q KIT_B=$REC LC_ALL=C awk 'BEGIN {
    a = tolower(ENVIRON["KIT_A"]); b = tolower(ENVIRON["KIT_B"])
    exit !(a == b || index(a, b "/") == 1) }' || return 0
  deny "$P is in the decision record, which only the user's main session writes. $REPORT"
}

# helper_call — Bash, and context-mode's tools: refuse decisions.sh add or supersede.
# A call that never names the helper passes before jq or awk is spent on it.
helper_call() {
  case $INPUT in *[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn][Ss].[Ss][Hh]*) ;; *) return 0 ;; esac
  lib || return 0
  kit_parse
  [ -n "$KIT_CMD" ] || return 0
  [ -f "$HOOK_DIR/lib-tokenize.awk" ] && [ -f "$HOOK_DIR/decisions-guard.awk" ] || return 0
  VERDICT=$(printf '%s\n' "$KIT_CMD" |
    awk -f "$HOOK_DIR/lib-tokenize.awk" -f "$HOOK_DIR/decisions-guard.awk" 2>/dev/null) || return 0
  case $VERDICT in
    WRITE*) deny "decisions.sh ${VERDICT#WRITE } writes the decision record, which only the user's main session writes. $REPORT" ;;
  esac
}

json_str tool_name || json_str toolName || exit 0
case $V in
  Write | Edit | MultiEdit | NotebookEdit) edit_target ;;
  Bash | mcp__context-mode__*) helper_call ;;
esac
exit 0
