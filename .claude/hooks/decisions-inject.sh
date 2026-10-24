#!/bin/sh
# decisions-inject.sh — SessionStart and SubagentStart: hand the session, and every
# subagent it spawns, resumes or messages, the user's decisions in force.
#
# The record is private to the clone: $(git rev-parse --git-common-dir)/decisions/,
# written through .claude/bin/decisions.sh. Every worktree of the clone reads the same
# live copy, and nothing a clone, a fork or a pull request carries can add to it.
# Pushing the list beats asking agents to pull it: a brief is frozen when it is written,
# so a decision left out of it, or made after it, never reaches the agent otherwise.
# SubagentStart reaches Explore and Plan too, which load none of the project's
# instruction files (checked live on Claude Code 2.1.304 for general-purpose and Explore
# agents).
#
# A project with no record gets nothing: no output, exit 0. The registration's wrapper
# exits 0 whatever this script does, because a hook that only adds context must never
# be able to block a session or fail one.
#
# It also marks the agent, or for SessionStart the session, as having seen this version
# of the list, so decisions-push.sh stays quiet at its first tool call instead of
# handing over the same list a second time.
#
# stdin: SessionStart or SubagentStart JSON. stdout: hookSpecificOutput JSON, or nothing.

INPUT=$(cat)

# Next to a full install, which registers its own copy, the plugin's copy steps aside,
# the way the plugin's SessionStart banner does, so the list is not given twice.
case ${CLAUDE_PLUGIN_ROOT-} in
  ?*) [ "$0" = "$CLAUDE_PLUGIN_ROOT/hooks/decisions-inject.sh" ] \
        && [ -f "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/decisions-inject.sh" ] && exit 0 ;;
esac

# ---- decision record: lookup and output (identical in decisions-inject.sh and decisions-push.sh)
LEAD="The user's decisions in force, from this clone's decision record: never contradict one; report a conflict instead"

# common_dir — the clone's git common directory, in G.
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

# record — the record's directory in R and the version of its in-force list in S, or
# false when this project keeps no record. A link in place of the directory or the
# list is refused: it would let a tracked file speak as the user. The version is the
# first word of in-force.sha, which decisions.sh rewrites with the list. A list without
# a usable one is still read, under the fixed version "unversioned" rather than a
# checksum, which would read the whole list on every tool call: each agent gets such a
# list once, and a change to it reaches running agents when the helper next writes
# the version (decisions.sh in-force).
record() {
  common_dir || return 1
  R=$G/decisions
  [ -d "$R" ] && [ ! -L "$R" ] && [ -f "$R/in-force.md" ] && [ ! -L "$R/in-force.md" ] \
    && [ -s "$R/in-force.md" ] && [ -r "$R/in-force.md" ] || return 1
  S=
  if [ -f "$R/in-force.sha" ] && [ ! -L "$R/in-force.sha" ]; then
    IFS= read -r S < "$R/in-force.sha" || :
    S=${S%% *}
  fi
  case $S in '' | *[!0-9A-Fa-f]*) S=unversioned ;; esac
  [ ${#S} -le 128 ]
}

# json_str <key> — the string value of a top-level "<key>" in the payload, in V.
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

# key — whose context this is, in K: the subagent or teammate the hook fires in, else
# the main session. Grok Build's camelCase spellings are read too. False, with K empty,
# when the id is missing or not safe to use as a file name.
key() {
  K=
  case $INPUT in
    *'"agent_id"'* | *'"agentId"'*) json_str agent_id || json_str agentId || return 1 ;;
    *) json_str session_id || json_str sessionId || return 1 ;;
  esac
  case $V in .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ ${#V} -le 128 ] || return 1
  K=$V
}

# emit <event> <lead> — print the hook's JSON: <lead>, then the in-force list.
#
# additionalContext is capped at 10,000 characters; past the cap Claude gets a file
# path and a 2,000-character preview it is not asked to read, so most of the list would
# vanish without a word. The list is cut at a line boundary inside the cap instead, and
# the cut says where the rest is. LC_ALL=C makes length() count bytes, never fewer than
# the characters Claude Code counts. Every replacement goes through index(), not gsub:
# awks disagree on backslashes in a replacement, and on a lone backslash as a separator.
emit() {
  KIT_LEAD=$2 KIT_PATH=$R/in-force.md LC_ALL=C awk -v ev="$1" '
    function rep(s, a, b,   r, p) {
      r = ""
      while ((p = index(s, a)) > 0) { r = r substr(s, 1, p - 1) b; s = substr(s, p + length(a)) }
      return r s
    }
    function esc(s) {
      s = rep(s, "\\", "\\\\"); s = rep(s, "\"", "\\\""); s = rep(s, "\t", "\\t"); s = rep(s, "\n", "\\n")
      gsub(CTL, "", s)
      return s
    }
    BEGIN {
      CTL = "["; for (i = 1; i < 32; i++) if (i != 9 && i != 10) CTL = CTL sprintf("%c", i); CTL = CTL "]"
      out = esc(ENVIRON["KIT_LEAD"]); n = length(ENVIRON["KIT_LEAD"])
    }
    !cut && n + length($0) + 1 <= 9000 { out = out "\\n" esc($0); n += length($0) + 1; next }
    { cut = 1 }
    END {
      if (cut) out = out "\\n\\n" esc("The list is longer than fits here. The rest is in " ENVIRON["KIT_PATH"] ": read it before deciding.")
      printf "{\"hookSpecificOutput\":{\"hookEventName\":\"%s\",\"additionalContext\":\"%s\"}}\n", ev, out
    }' "$R/in-force.md"
}
# ---- end decision record

record || exit 0

# The event this runs for names the output. A payload that does not say is read as
# SubagentStart when it names an agent, the only difference between the two.
EV=
if json_str hook_event_name || json_str hookEventName; then
  case $V in *[!A-Za-z]*) ;; *) EV=$V ;; esac
fi
if [ -z "$EV" ]; then
  case $INPUT in *'"agent_id"'* | *'"agentId"'*) EV=SubagentStart ;; *) EV=SessionStart ;; esac
fi

emit "$EV" "$LEAD
"

# Seen: an empty directory per id and version, made with mkdir because mkdir never
# follows a link planted at the name, and this hook runs outside the sandbox. Private
# to the user, like the rest of the record.
if key && [ ! -L "$R/seen" ]; then
  umask 077
  mkdir -p "$R/seen/$K.$S" 2>/dev/null
fi

# Markers outlive their agents. A session start is a cheap moment to drop the ones no
# session has touched in a week; one that comes back is handed the list again.
if [ "$EV" = SessionStart ] && [ -d "$R/seen" ] && [ ! -L "$R/seen" ]; then
  find "$R/seen" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rmdir {} + 2>/dev/null
fi
exit 0
