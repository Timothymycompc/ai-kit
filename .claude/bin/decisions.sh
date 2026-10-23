#!/usr/bin/env bash
# decisions.sh — the decision record: the user's decisions, principles and standing
# orders, one markdown file per entry under $(git rev-parse --git-common-dir)/decisions/.
#
# Why there: every linked worktree of a clone shares the git common directory, so an
# entry recorded in one pane is live in all of them at once, where a tracked file would
# be stale in every branch. Nothing under .git/ is cloned, committed or pushed, so the
# record stays private, and no cloned repo, fork or pull request can plant an entry.
#
# Why a script: Claude Code treats a Write or Edit into .git/ as a sensitive-file write
# and asks before any allow rule applies, so entries are written here, with literal
# arguments, under the one allow rule Bash(bash .claude/bin/decisions.sh *). Only the
# user's main session writes, which hooks/decisions-guard.sh enforces by refusing a
# subagent `add` and `supersede`; subagents propose entries in their reports.
#
# Files in the record directory:
#   <D|P|S>-<date>-<slug>.md   one entry: YAML front matter, every key always present
#   in-force.md                one line per entry in force, oldest first, kept under
#                              about 1.5K tokens; the hooks inject it into every agent
#   in-force.sha               the git blob id of in-force.md, which the hooks compare
#                              to see what changed
# add and supersede regenerate the last two; in-force and hash do too when an entry
# changed since. Anything else in the directory is left alone, so keep other state in
# a subdirectory.
#
# The record never holds secrets: a field that looks like a credential is refused, and
# no message here ever prints a field's value.
#
# Usage: decisions.sh <add|supersede|in-force|hash|export|path|help>   (see: help)
# Exit:  0 done; 1 refused or failed; 2 bad usage.
set -euo pipefail
export LC_ALL=C      # byte semantics everywhere: sizes, truncation, slugs, patterns
shopt -s nullglob
umask 077            # the record is private to this user

usage() {
  cat <<'USAGE'
Usage: decisions.sh <command> [options]

  add --kind K --decision D --words W [--question Q] [options]
             Record an entry and print its id.
  supersede <id> --decision D --words W [options]
             Mark <id> superseded, record its replacement and print the new id.
             --kind, --question and the slug default to those of <id>.
  in-force   Regenerate and print in-force.md: one line per entry in force.
  hash       Print the hash of in-force.md, as stored in in-force.sha.
  export [--handoff]
             Print every entry, oldest first; --handoff prints a readable digest
             for a teammate or the next session.
  path       Print the record directory.

Options for add and supersede:
  --kind K          decision | principle | standing-order (or D | P | S)
  --question Q      what was asked; required for a decision
  --decision D      what was decided, in a line
  --words W         the words it rests on, verbatim, never paraphrased
  --premises P      each marked [verified] or [assumed]
  --enforced-by E   the test or hook that proves it (default: none yet)
  --covers C        what a standing order covers; required for one
  --requires R      what it needs first, such as CI green on the head SHA
  --expires X       when it lapses; required for a standing order
  --by B            you | panel | agent (default: you)
  --status S        in-force | provisional | proposed (default: in-force)
  --slug S          the name part of the id (default: from the question or decision)
  --date YYYY-MM-DD the day it was decided (default: $DECISIONS_DATE, else today)
  --stdin           also read fields from stdin, one "name: value" per line, an
                    indented line continuing the value above it. Use it, through a
                    quoted heredoc whose delimiter no line of the text equals
                    (<<'DECISION_END'), for multi-line words, for text with quotes,
                    and for any text that names a credential path: on the command
                    line a guard hook can take such a path for a file argument and
                    block the call.

A decision the user made is superseded only with --by you and status in-force.
A field that looks like a credential is refused: the record never holds secrets.
USAGE
}

die() { echo "decisions.sh: $*" >&2; exit 1; }
warn() { echo "decisions.sh: $*" >&2; }
usage_die() { echo "decisions.sh: $*" >&2; echo "Run: decisions.sh help" >&2; exit 2; }

# The record is the one of the repository this runs in, as with git: run it from the
# project, and from a hook after cd "$CLAUDE_PROJECT_DIR". Where the script itself lives
# does not count, so running one checkout's copy by its path from a temp repository
# writes the temp repository's record, never that checkout's.

ID_RE='^[DPS]-[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$'
BUDGET=6000          # bytes of in-force.md, about 1.5K tokens
COLLAPSE=9000        # near the 10,000 characters past which a hook's context collapses
FIELD_MAX=4000       # bytes per field: a summary and a pointer, never a pasted file
DIR=""
TMP_A=""
TMP_B=""
trap 'rm -f "${TMP_A:-}" "${TMP_B:-}" 2>/dev/null || true' EXIT

# resolve — set DIR to the record directory; 1 outside a git repository. Absolute and
# symlink-free, so the main checkout and every linked worktree name the same path.
# Plain cd and $PWD rather than $(cd …; pwd): `hash` may run on every tool call, and
# each subshell is a fork.
resolve() {
  local here="$PWD" common=""
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
  common="${common##*$'\n'}"   # git older than 2.31 echoes the flag it does not know
  case "$common" in
    /*) ;;
    *) common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1 ;;
  esac
  [ -n "$common" ] || return 1
  CDPATH= cd -P -- "$common" 2>/dev/null || return 1
  DIR="$PWD/decisions"
  cd -- "$here"
}

# --- Credentials -----------------------------------------------------------------------
# Each pattern runs on a field with its newlines flattened, so a key pasted as a
# pretty-printed array is caught too. A false positive costs a rephrase; a miss puts a
# secret in a file every agent is shown.
B58='1-9A-HJ-NP-Za-km-z'
SECRET_LABELS=()
SECRET_ARGS=()
secret() { SECRET_LABELS[${#SECRET_LABELS[@]}]="$1"; SECRET_ARGS[${#SECRET_ARGS[@]}]="-e"; SECRET_ARGS[${#SECRET_ARGS[@]}]="$2"; }
secret "a PEM key or certificate block" '-----BEGIN'
secret "a keypair byte array"           '\[[[:space:]]*([0-9]{1,3}[[:space:]]*,[[:space:]]*){31,}[0-9]{1,3}'
secret "a base58 64-byte secret key"    "(^|[^$B58])[$B58]{85,90}([^$B58]|\$)"
secret "a GitHub token"                 '(^|[^A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})'
secret "an sk- API key"                 '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}'
secret "a Slack token"                  '(^|[^A-Za-z0-9_-])(xox[abposr]-[A-Za-z0-9-]{10,}|xapp-[0-9]-[A-Za-z0-9-]{10,})'
secret "an AWS access key id"           '(^|[^A-Z0-9])(AKIA|ASIA)[A-Z0-9]{16}([^A-Z0-9]|$)'
secret "a Google API key"               'AIza[0-9A-Za-z_-]{35}'
secret "a Stripe key"                   '(sk|rk)_(live|test)_[A-Za-z0-9]{16,}'
secret "an npm token"                   '(^|[^A-Za-z0-9_])npm_[A-Za-z0-9]{36}'
secret "a PyPI token"                   'pypi-[A-Za-z0-9_-]{50,}'
secret "a GitLab token"                 'glpat-[A-Za-z0-9_-]{20,}'
secret "a Hugging Face token"           '(^|[^A-Za-z0-9_])hf_[A-Za-z0-9]{30,}'
secret "a JWT"                          'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
secret "a URL with a password"          '[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]+@'
secret "a key in a URL query"           '[?&](api[-_]?key|apikey|access[-_]?token|auth[-_]?token|token|secret|password|key)=[^&[:space:]]{12,}'
secret "a credential assignment"        "(^|[^A-Za-z0-9_])[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Z0-9_]*[[:space:]]*=[[:space:]]*[\"']?[^[:space:]\"'\$<{]{8,}"

# C0 controls and DEL, less tab, newline and carriage return: an escape sequence in a
# field would reach every terminal the record is printed to.
CTRL=$'\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177'

# flatten <value> — set FLAT to the value with its line breaks and tabs as spaces.
flatten() { FLAT="${1//$'\n'/ }"; FLAT="${FLAT//$'\r'/ }"; FLAT="${FLAT//$'\t'/ }"; }

# grep_secret <text> — 0 when it matches a credential pattern, 1 when not; any other
# grep failure refuses rather than passing. Run without pipefail: grep -q may stop
# reading early, and the writer's SIGPIPE must not read as "no match".
grep_secret() { grep_secret_one "$1" "${SECRET_ARGS[@]}"; }
grep_secret_one() {
  local text="$1" rc=0
  shift
  [ "${1:-}" = -e ] || set -- -e "$1"
  set +o pipefail
  printf '%s\n' "$text" | grep -Eq "$@" || rc=$?
  set -o pipefail
  case "$rc" in
    0|1) return "$rc" ;;
    *) die "could not check the fields for credentials (grep exited $rc); nothing was recorded" ;;
  esac
}

# check_fields <option> <value> ... — refuse oversized fields, control characters and
# anything credential-shaped, naming the option and never the value.
check_fields() {
  local all="" opt="" arg val i label
  for arg in "$@"; do
    if [ -z "$opt" ]; then opt="$arg"; continue; fi
    val="$arg"
    if [ -n "$val" ]; then
      [ "${#val}" -le "$FIELD_MAX" ] || die "refusing $opt: ${#val} bytes, over $FIELD_MAX; record a summary and where the full text lives"
      case "$val" in *["$CTRL"]*) die "refusing $opt: it holds a control character" ;; esac
      flatten "$val"
      all="$all$FLAT"$'\n'
    fi
    opt=""
  done
  grep_secret "$all" || return 0
  # Something matched: name the option and the kind of credential, so the fix is clear.
  for arg in "$@"; do
    if [ -z "$opt" ]; then opt="$arg"; continue; fi
    flatten "$arg"
    val="$FLAT"
    if [ -n "$val" ] && grep_secret "$val"; then
      label="a credential" i=0
      while [ "$i" -lt "${#SECRET_LABELS[@]}" ]; do
        if grep_secret_one "$val" "${SECRET_ARGS[$((i * 2 + 1))]}"; then label="${SECRET_LABELS[$i]}"; break; fi
        i=$((i + 1))
      done
      die "refusing $opt: it looks like $label. The record never holds secrets: quote the rest and write [redacted] in its place."
    fi
    opt=""
  done
  die "refusing: a field looks like a credential"
}

# --- awk -------------------------------------------------------------------------------
# Every value is written double-quoted with \\ \" \n \t escapes, so quotes, newlines and
# any UTF-8 survive verbatim. Values travel to awk through the environment: -v would
# apply escape processing to them.
AWK_WRITE='
function q(s,   out, i, n, c) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\n") out = out "\\n"
    else if (c == "\t") out = out "\\t"
    else if (c != "\r") out = out c
  }
  return "\"" out "\""
}
function opt(s) { return s == "" ? "—" : q(s) }
BEGIN {
  printf "---\n"
  printf "id: %s\n", ENVIRON["DEC_ID"]
  printf "kind: %s\n", ENVIRON["DEC_KIND"]
  printf "status: %s\n", ENVIRON["DEC_STATUS"]
  printf "decided-by: %s\n", ENVIRON["DEC_BY"]
  printf "date: %s\n", ENVIRON["DEC_DATE"]
  printf "question: %s\n", opt(ENVIRON["DEC_QUESTION"])
  printf "decision: %s\n", q(ENVIRON["DEC_DECISION"])
  printf "your-words: %s\n", q(ENVIRON["DEC_WORDS"])
  printf "premises: %s\n", opt(ENVIRON["DEC_PREMISES"])
  printf "enforced-by: %s\n", q(ENVIRON["DEC_ENFORCED"])
  printf "supersedes: %s\n", (ENVIRON["DEC_SUPERSEDES"] == "" ? "—" : ENVIRON["DEC_SUPERSEDES"])
  printf "covers: %s\n", opt(ENVIRON["DEC_COVERS"])
  printf "requires: %s\n", opt(ENVIRON["DEC_REQUIRES"])
  printf "expires: %s\n", opt(ENVIRON["DEC_EXPIRES"])
  printf "---\n"
}'

# The slug: lowercase ASCII words, stop words dropped, at most 6 words and 40 bytes.
AWK_SLUG='
BEGIN {
  split("a an the of to in on at by for from with and or but is are was be been do does did should would could can will shall may might must we you i it its this that these those what when where which who whom whose how why there here our your my me us them they he she his her if as so than then", w, " ")
  for (i in w) STOP[w[i]] = 1
  s = tolower(ENVIRON["DEC_SLUGSRC"]); gsub(/[^a-z0-9]+/, " ", s)
  n = split(s, words, " "); out = ""; cnt = 0; first = ""
  for (i = 1; i <= n; i++) {
    if (words[i] == "") continue
    if (first == "") first = words[i]
    if (drop && (words[i] in STOP)) continue
    if (length(out) + length(words[i]) + (out == "" ? 0 : 1) > 40) break
    out = (out == "" ? words[i] : out "-" words[i])
    if (++cnt == 6) break
  }
  if (out == "") out = substr(first, 1, 40)
  print out
}'

# Reads entry files: decodes the front matter written above (or a hand edit using
# bare or single-quoted values), then prints by mode. A file whose front matter never
# closes is a write in progress or not an entry, and is skipped.
AWK_READ='
function unq(v,   c, out, i, n) {
  QUOTED = 0; c = substr(v, 1, 1)
  if (c == "\"") {
    QUOTED = 1; out = ""; n = length(v)
    for (i = 2; i <= n; i++) {
      c = substr(v, i, 1)
      if (c == "\\") {
        i++; c = substr(v, i, 1)
        if (c == "n") out = out "\n"
        else if (c == "t") out = out "\t"
        else if (c == "r") out = out "\r"
        else if (c == "\"" || c == "\\" || c == "/") out = out c
        else out = out "\\" c
      } else if (c == "\"") break
      else out = out c
    }
    return out
  }
  if (c == "\047") {
    QUOTED = 1; out = ""; n = length(v)
    for (i = 2; i <= n; i++) {
      c = substr(v, i, 1)
      if (c != "\047") out = out c
      else if (substr(v, i + 1, 1) == "\047") { out = out c; i++ }
      else break
    }
    return out
  }
  sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
  return v
}
function isset(i, k,   v) {
  if (!((i, k) in F)) return 0
  if (Q[i, k]) return 1
  v = F[i, k]
  return !(v == "" || v == "—" || v == "-" || v == "~" || v == "null")
}
function get(i, k) { return isset(i, k) ? F[i, k] : "" }
function flat(s) { gsub(/[\t\r\n]+/, " ", s); gsub(/  +/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
# cut: at most n bytes, never splitting a UTF-8 sequence, marked with an ellipsis.
function cut(s, n,   t, i, c, need) {
  if (length(s) <= n) return s
  t = substr(s, 1, n)
  for (i = length(t); i > 0 && i > length(t) - 4; i--) {
    c = substr(t, i, 1)
    if (c < "\200") break
    if (c >= "\300") {
      need = (c >= "\360") ? 4 : (c >= "\340") ? 3 : 2
      if (length(t) - i + 1 < need) t = substr(t, 1, i - 1)
      break
    }
  }
  sub(/ +$/, "", t); TRUNC = 1
  return t "…"
}
function close_file() { if (N > 0) OK[N] = (ST == 2) }
FNR == 1 {
  close_file(); N++; ST = (($0 ~ /^---[ \t\r]*$/) ? 1 : -1)
  b = FILENAME; sub(/.*\//, "", b); sub(/\.md$/, "", b); ID[N] = b; RAW[N] = ""
}
{ line = $0; sub(/\r$/, "", line); RAW[N] = RAW[N] line "\n" }
FNR > 1 && ST == 1 {
  if (line ~ /^---[ \t]*$/) { ST = 2; next }
  if (match(line, /^[a-z][a-z-]*:/)) {
    k = substr(line, 1, RLENGTH - 1); v = substr(line, RLENGTH + 1); sub(/^[ \t]+/, "", v)
    if (!((N, k) in F)) { F[N, k] = unq(v); Q[N, k] = QUOTED }
  }
}
# order: the readable entries by date, then id, into ORD[1..M]; EFF[i] is the status
# that counts, with an entry that an in-force entry supersedes counted as superseded
# whatever its own file still says.
function order(   i, j, t, x) {
  M = 0
  for (i = 1; i <= N; i++) if (OK[i]) { ORD[++M] = i; KEY[i] = get(i, "date") "\t" ID[i] }
  for (i = 2; i <= M; i++) {
    t = ORD[i]; j = i - 1
    while (j > 0 && KEY[ORD[j]] > KEY[t]) { ORD[j + 1] = ORD[j]; j-- }
    ORD[j + 1] = t
  }
  for (x = 1; x <= M; x++) { i = ORD[x]; if (get(i, "status") == "in-force" && isset(i, "supersedes")) GONE[get(i, "supersedes")] = 1 }
  for (x = 1; x <= M; x++) { i = ORD[x]; EFF[i] = get(i, "status"); if (EFF[i] == "in-force" && (ID[i] in GONE)) EFF[i] = "superseded" }
}
function line_for(i, cd, cw, cb,   s, by, b) {
  s = "- " ID[i]; by = get(i, "decided-by")
  if (by != "you") s = s " [" (by == "" ? "decided-by unset" : by) "]"
  s = s ":"
  if (isset(i, "decision")) s = s " " cut(flat(get(i, "decision")), cd)
  if (isset(i, "your-words")) s = s " — \"" cut(flat(get(i, "your-words")), cw) "\""
  if (isset(i, "date")) s = s " (" get(i, "date") ")"
  b = ""
  if (isset(i, "covers")) b = b (b == "" ? "" : "; ") "covers: " cut(flat(get(i, "covers")), cb)
  if (isset(i, "requires")) b = b (b == "" ? "" : "; ") "requires: " cut(flat(get(i, "requires")), cb)
  if (isset(i, "expires")) b = b (b == "" ? "" : "; ") "expires: " cut(flat(get(i, "expires")), cb)
  if (b != "") s = s " [" b "]"
  return s
}
function in_force(cd, cw, cb,   x, i, out) {
  out = ""; TRUNC = 0
  for (x = 1; x <= M; x++) { i = ORD[x]; if (EFF[i] == "in-force") out = out line_for(i, cd, cw, cb) "\n" }
  if (TRUNC) out = out "(… marks text cut to fit; decisions.sh export prints the full entries)\n"
  return out
}
function item(label, v) { if (v != "") print "- " label ": " flat(v) }
function section(title, status,   x, i, n, w, by, rest, nl) {
  n = 0
  for (x = 1; x <= M; x++) if (EFF[ORD[x]] == status) n++
  if (n == 0) return
  print ""; print "## " title " (" n ")"
  for (x = 1; x <= M; x++) {
    i = ORD[x]; if (EFF[i] != status) continue
    print ""; print "### " ID[i]
    item("Question", get(i, "question")); item("Decision", get(i, "decision"))
    by = get(i, "decided-by"); w = get(i, "your-words")
    if (w != "") {
      gsub(/\r/, "", w)
      if (index(w, "\n") == 0) print "- " (by == "you" ? "The user\047s words" : "Words cited") " (" get(i, "date") "): \"" w "\""
      else {
        print "- " (by == "you" ? "The user\047s words" : "Words cited") " (" get(i, "date") "):"
        rest = w
        while ((nl = index(rest, "\n")) > 0) { print "  > " substr(rest, 1, nl - 1); rest = substr(rest, nl + 1) }
        print "  > " rest
      }
    }
    item("Decided by", by); item("Premises", get(i, "premises")); item("Enforced by", get(i, "enforced-by"))
    item("Supersedes", get(i, "supersedes")); item("Superseded by", SUCC[ID[i]])
    item("Covers", get(i, "covers")); item("Requires", get(i, "requires")); item("Expires", get(i, "expires"))
  }
}
END {
  close_file()
  if (mode == "get") { if (!OK[1]) exit 3; printf "%s", get(1, key); exit 0 }
  order()
  if (mode == "inforce") {
    out = in_force(200, 240, 80)
    if (length(out) > budget) out = in_force(100, 120, 60)
    printf "%s", out
  } else if (mode == "raw") {
    for (x = 1; x <= M; x++) printf "%s%s", (x > 1 ? "\n" : ""), RAW[ORD[x]]
  } else if (mode == "handoff") {
    if (M == 0) exit 0
    for (x = 1; x <= M; x++) {
      i = ORD[x]; if (!isset(i, "supersedes")) continue
      s = get(i, "supersedes"); SUCC[s] = ((s in SUCC) ? SUCC[s] ", " : "") ID[i]
    }
    print "# Decision record, exported " today
    print ""
    print "Kept under the repository\047s git directory and never committed. Words are quoted verbatim."
    section("In force", "in-force"); section("Provisional", "provisional")
    section("Proposed", "proposed"); section("Superseded", "superseded")
    for (x = 1; x <= M; x++) { s = EFF[ORD[x]]; if (s != "in-force" && s != "provisional" && s != "proposed" && s != "superseded" && !(s in SEEN)) { SEEN[s] = 1; section("Status " (s == "" ? "unset" : s), s) } }
  }
}'

# Marks an entry superseded in place: the status line inside the front matter (added
# before its closing line if missing), plus a note naming the replacement.
AWK_RETIRE='
NR == 1 && /^---[ \t\r]*$/ { fm = 1; print; next }
fm == 1 && /^---[ \t\r]*$/ { if (!done) print "status: superseded"; fm = 2; print; next }
fm == 1 && !done && /^status:/ { print "status: superseded"; done = 1; next }
{ print }
END { printf "\nSuperseded by %s (%s).\n", newid, when }'

# --- record files ----------------------------------------------------------------------

# collect — the entry files, by name, into FILES[0..NFILES-1]. Symlinks and names that
# are not ids are skipped: an entry is a regular file this script could have written.
collect() {
  local f b
  FILES=() NFILES=0
  for f in "$DIR"/[DPS]-*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    b="${f##*/}"; b="${b%.md}"
    [[ $b =~ $ID_RE ]] || continue
    FILES[$NFILES]="$f"; NFILES=$((NFILES + 1))
  done
}

# render <mode> — print the record in that mode (inforce | raw | handoff).
render() {
  collect
  [ "$NFILES" -gt 0 ] || return 0
  awk -v mode="$1" -v budget="$BUDGET" -v today="${TODAY:-}" "$AWK_READ" "${FILES[@]}"
}

# field <file> <key> — one decoded front-matter value; 1 when the file is not an entry.
field() {
  local out rc=0
  out="$(awk -v mode=get -v key="$2" "$AWK_READ" "$1"; printf x)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "${out%x}"
}

# regenerate — bring in-force.md and in-force.sha up to date with the entries. A write
# that raced another pane's is caught by rendering again until disk and render agree.
# 1 when the directory cannot be written.
regenerate() {
  local pass=0 sha stored=""
  [ -d "$DIR" ] || return 0
  while [ "$pass" -lt 5 ]; do
    pass=$((pass + 1))
    TMP_A="$(mktemp "$DIR/.tmp.XXXXXX" 2>/dev/null)" || return 1
    render inforce > "$TMP_A" || return 1
    stored=""
    [ -f "$DIR/in-force.sha" ] && IFS= read -r stored < "$DIR/in-force.sha" || true
    if [ -f "$DIR/in-force.md" ] && cmp -s "$TMP_A" "$DIR/in-force.md" \
      && [ -n "$stored" ] && [ "$(git hash-object --stdin < "$DIR/in-force.md")" = "$stored" ]; then
      rm -f "$TMP_A"
      # Newer than the directory and every entry, which is how `hash` knows it is current.
      touch "$DIR/in-force.sha" 2>/dev/null || true
      return 0
    fi
    sha="$(git hash-object --stdin < "$TMP_A")" || return 1
    mv -f "$TMP_A" "$DIR/in-force.md" || return 1
    TMP_A="$(mktemp "$DIR/.tmp.XXXXXX" 2>/dev/null)" || return 1
    printf '%s\n' "$sha" > "$TMP_A" && mv -f "$TMP_A" "$DIR/in-force.sha" || return 1
  done
  warn "in-force.md kept changing while it was regenerated; run: decisions.sh in-force"
}

# stale — in-force.sha is missing, or older than the directory or any entry (an entry
# edited or deleted by hand since the last regeneration).
stale() {
  local f
  [ -f "$DIR/in-force.sha" ] || return 0
  [ "$DIR" -nt "$DIR/in-force.sha" ] && return 0
  for f in "$DIR"/[DPS]-*.md; do [ "$f" -nt "$DIR/in-force.sha" ] && return 0; done
  return 1
}

budget_check() {
  local size
  [ -f "$DIR/in-force.md" ] || return 0
  size="$(wc -c < "$DIR/in-force.md" | tr -d ' ')"
  if [ "$size" -gt "$COLLAPSE" ]; then
    warn "in-force.md is $size bytes: past about 10,000 characters a hook's injection collapses to a preview. Supersede entries that no longer apply."
  elif [ "$size" -gt "$BUDGET" ]; then
    warn "in-force.md is $size bytes (about $((size / 4)) tokens), over its 1.5K-token budget. Supersede entries that no longer apply."
  fi
}

valid_date() {
  case "$1" in [0-9][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]) ;; *) return 1 ;; esac
  [ "${1:5:2}" -ge 1 ] && [ "${1:5:2}" -le 12 ] && [ "${1:8:2}" -ge 1 ] && [ "${1:8:2}" -le 31 ]
}

# --- add / supersede -------------------------------------------------------------------

# set_opt <--name> <value> — one field, from the command line or from --stdin; a field
# given twice is refused rather than one copy silently winning.
set_opt() {
  case "$1" in
    --kind)        [ -z "${O_KIND+x}" ] || usage_die "$1 given twice"; O_KIND="$2" ;;
    --question)    [ -z "${O_QUESTION+x}" ] || usage_die "$1 given twice"; O_QUESTION="$2" ;;
    --decision)    [ -z "${O_DECISION+x}" ] || usage_die "$1 given twice"; O_DECISION="$2" ;;
    --words|--your-words)
                   [ -z "${O_WORDS+x}" ] || usage_die "$1 given twice"; O_WORDS="$2" ;;
    --premises)    [ -z "${O_PREMISES+x}" ] || usage_die "$1 given twice"; O_PREMISES="$2" ;;
    --enforced-by) [ -z "${O_ENFORCED+x}" ] || usage_die "$1 given twice"; O_ENFORCED="$2" ;;
    --covers)      [ -z "${O_COVERS+x}" ] || usage_die "$1 given twice"; O_COVERS="$2" ;;
    --requires)    [ -z "${O_REQUIRES+x}" ] || usage_die "$1 given twice"; O_REQUIRES="$2" ;;
    --expires)     [ -z "${O_EXPIRES+x}" ] || usage_die "$1 given twice"; O_EXPIRES="$2" ;;
    --by)          [ -z "${O_BY+x}" ] || usage_die "$1 given twice"; O_BY="$2" ;;
    --status)      [ -z "${O_STATUS+x}" ] || usage_die "$1 given twice"; O_STATUS="$2" ;;
    --slug)        [ -z "${O_SLUG+x}" ] || usage_die "$1 given twice"; O_SLUG="$2" ;;
    --date)        [ -z "${O_DATE+x}" ] || usage_die "$1 given twice"; O_DATE="$2" ;;
    *) usage_die "unknown option: $1" ;;
  esac
}

parse_opts() {
  local opt val stdin=0
  while [ $# -gt 0 ]; do
    opt="$1"
    case "$opt" in
      --stdin) stdin=1; shift; continue ;;
      --*=*) val="${opt#*=}"; opt="${opt%%=*}" ;;
      --*) [ $# -ge 2 ] || usage_die "$opt needs a value"; val="$2"; shift ;;
      *) usage_die "a value with no --option before it (not printed: it may be a field)" ;;
    esac
    shift
    set_opt "$opt" "$val"
  done
  [ "$stdin" -eq 0 ] || read_stdin
}

# read_stdin — fields as "name: value" lines, names as the options spell them. A line
# that is indented, or blank, continues the value above it, so the user's words keep
# their line breaks; lines starting with # are comments. Text fed this way never sits
# on the command line, where a guard hook can take a word naming a credential path for
# a file argument; through a quoted heredoc it reaches this script as data.
read_stdin() {
  local line name="" val=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      "#"*) continue ;;
      "" | [[:space:]]*)
        [ -n "$name" ] || { [ -z "$line" ] && continue; usage_die "--stdin: an indented line before any field"; }
        case "$line" in "  "*) line="${line#  }" ;; [[:space:]]*) line="${line#?}" ;; esac
        if [ -z "$val" ]; then val="$line"; else val="$val"$'\n'"$line"; fi
        continue ;;
    esac
    [ -z "$name" ] || stdin_field "$name" "$val"
    case "$line" in *:*) ;; *) usage_die "--stdin: expected name: value, got a line with no colon" ;; esac
    name="${line%%:*}" val="${line#*:}"
    val="${val# }"
  done
  [ -z "$name" ] || stdin_field "$name" "$val"
}
stdin_field() {
  local v="$2"
  while [ "${v%$'\n'}" != "$v" ]; do v="${v%$'\n'}"; done   # blank lines before the next field
  case "$1" in *[!a-z-]* | "") usage_die "--stdin: a field name is lowercase letters and dashes" ;; esac
  set_opt "--$1" "$v"
}

# prepare — validate the options into the K_* values an entry is written from.
prepare() {
  case "$(printf '%s' "${O_KIND:-}" | tr '[:upper:]' '[:lower:]')" in
    decision|d) K_KIND=decision K_LETTER=D ;;
    principle|p) K_KIND=principle K_LETTER=P ;;
    standing-order|s) K_KIND=standing-order K_LETTER=S ;;
    "") usage_die "--kind is required (decision, principle or standing-order)" ;;
    *) usage_die "--kind must be decision, principle or standing-order" ;;
  esac
  K_BY="${O_BY:-you}"
  case "$K_BY" in you|panel|agent) ;; *) usage_die "--by must be you, panel or agent" ;; esac
  K_STATUS="${O_STATUS:-in-force}"
  case "$K_STATUS" in in-force|provisional|proposed) ;; *) usage_die "--status must be in-force, provisional or proposed" ;; esac
  [ -n "${O_DECISION:-}" ] || usage_die "--decision is required"
  [ -n "${O_WORDS:-}" ] || usage_die "--words is required: the words the entry rests on, verbatim"
  [ "$K_KIND" != decision ] || [ -n "${O_QUESTION:-}" ] || usage_die "--question is required for a decision"
  if [ "$K_KIND" = standing-order ]; then
    [ -n "${O_COVERS:-}" ] || usage_die "--covers is required for a standing order: what it covers, and nothing else"
    [ -n "${O_EXPIRES:-}" ] || usage_die "--expires is required for a standing order"
  fi
  K_DATE="${O_DATE:-${DECISIONS_DATE:-}}"
  if [ -n "$K_DATE" ]; then
    valid_date "$K_DATE" || usage_die "the date must be YYYY-MM-DD (from --date or DECISIONS_DATE)"
  else
    K_DATE="$(date +%Y-%m-%d)"
  fi
  check_fields --question "${O_QUESTION:-}" --decision "$O_DECISION" --words "$O_WORDS" \
    --premises "${O_PREMISES:-}" --enforced-by "${O_ENFORCED:-}" --covers "${O_COVERS:-}" \
    --requires "${O_REQUIRES:-}" --expires "${O_EXPIRES:-}" --slug "${O_SLUG:-}"
  if [ -n "${O_SLUG:-}" ]; then
    K_SLUG="$(DEC_SLUGSRC="$O_SLUG" awk -v drop=0 "$AWK_SLUG")"
    [ -n "$K_SLUG" ] || usage_die "--slug needs letters or digits"
  else
    K_SLUG="$(DEC_SLUGSRC="${O_QUESTION:-$O_DECISION}" awk -v drop=1 "$AWK_SLUG")"
    [ -n "$K_SLUG" ] || K_SLUG=entry
  fi
}

# write_entry [supersedes] — write the entry under a fresh id (a -2, -3 ... suffix when
# the name is taken) and set NEW_ID. Linking a finished temp file into place makes the
# entry appear whole, and fail instead of overwriting when another pane took the name.
write_entry() {
  local base="$K_LETTER-$K_DATE-$K_SLUG" n=1 id
  mkdir -p "$DIR" || die "cannot create $DIR"
  TMP_B="$(mktemp "$DIR/.tmp.XXXXXX" 2>/dev/null)" || die "cannot write in $DIR"
  while :; do
    if [ "$n" -eq 1 ]; then id="$base"; else id="$base-$n"; fi
    DEC_ID="$id" DEC_KIND="$K_KIND" DEC_STATUS="$K_STATUS" DEC_BY="$K_BY" DEC_DATE="$K_DATE" \
      DEC_QUESTION="${O_QUESTION:-}" DEC_DECISION="$O_DECISION" DEC_WORDS="$O_WORDS" \
      DEC_PREMISES="${O_PREMISES:-}" DEC_ENFORCED="${O_ENFORCED:-none yet}" DEC_SUPERSEDES="${1:-}" \
      DEC_COVERS="${O_COVERS:-}" DEC_REQUIRES="${O_REQUIRES:-}" DEC_EXPIRES="${O_EXPIRES:-}" \
      awk "$AWK_WRITE" > "$TMP_B" || die "cannot write in $DIR"
    if ln "$TMP_B" "$DIR/$id.md" 2>/dev/null; then break; fi
    # No hard links on this filesystem: an exclusive create does the same job.
    if [ ! -e "$DIR/$id.md" ] && ( set -C; cat "$TMP_B" > "$DIR/$id.md" ) 2>/dev/null; then break; fi
    [ -e "$DIR/$id.md" ] || die "cannot write $DIR/$id.md"
    n=$((n + 1))
    [ "$n" -le 99 ] || die "99 entries named $base already; pass --slug"
  done
  rm -f "$TMP_B"
  NEW_ID="$id"
}

finish() {
  regenerate || warn "in-force.md was not regenerated ($DIR is not writable); run: decisions.sh in-force"
  budget_check
  printf '%s\n' "$NEW_ID"
}

cmd_add() {
  parse_opts "$@"
  prepare
  resolve || die "not inside a git repository: the record lives under its git directory"
  write_entry
  finish
}

cmd_supersede() {
  local old="${1:-}" file st by kind
  [ -n "$old" ] && [ "${old#--}" = "$old" ] || usage_die "supersede needs the id of the entry it replaces first"
  shift
  old="${old%.md}"
  [[ $old =~ $ID_RE ]] || die "not an entry id: ids look like D-2026-10-22-some-slug"
  parse_opts "$@"
  resolve || die "not inside a git repository: the record lives under its git directory"
  file="$DIR/$old.md"
  [ -f "$file" ] && [ ! -L "$file" ] || die "no entry $old in $DIR"
  st="$(field "$file" status)" || die "$old has no readable front matter; fix it by hand first"
  by="$(field "$file" decided-by)"
  [ "$st" != superseded ] || die "$old is already superseded; supersede the entry in force instead"
  if [ -z "${O_KIND+x}" ]; then
    kind="$(field "$file" kind)"
    case "$kind" in decision|principle|standing-order) O_KIND="$kind" ;; *) usage_die "$old has no kind; pass --kind" ;; esac
  fi
  [ -n "${O_QUESTION+x}" ] || O_QUESTION="$(field "$file" question)"
  [ -n "${O_SLUG+x}" ] || O_SLUG="${old#?-????-??-??-}"
  prepare
  [ "$K_STATUS" != proposed ] || usage_die "a proposal supersedes nothing: record it with add --status proposed"
  # Authority comes only from the user: no panel, agent or provisional call replaces
  # a decision they made. An entry with no decided-by counts as theirs.
  if [ "${by:-you}" = you ] && { [ "$K_BY" != you ] || [ "$K_STATUS" != in-force ]; }; then
    die "$old is the user's decision: only the user supersedes it (--by you, status in-force)"
  fi
  write_entry "$old"
  TMP_A="$(mktemp "$DIR/.tmp.XXXXXX" 2>/dev/null)" \
    && awk -v newid="$NEW_ID" -v when="$K_DATE" "$AWK_RETIRE" "$file" > "$TMP_A" \
    && mv -f "$TMP_A" "$file" \
    || warn "could not mark $old superseded in its file; $NEW_ID supersedes it all the same"
  finish
}

# The readers stay quiet outside a repository or before the first entry: there is
# simply nothing in force, and a hook calling them should inject nothing.
cmd_in_force() {
  [ $# -eq 0 ] || usage_die "in-force takes no arguments"
  resolve || return 0
  [ -d "$DIR" ] || return 0
  if regenerate; then
    budget_check
    cat "$DIR/in-force.md"
  else
    warn "$DIR is not writable: printing the entries in force without saving in-force.md"
    render inforce
  fi
}

cmd_hash() {
  local h=""
  [ $# -eq 0 ] || usage_die "hash takes no arguments"
  resolve || return 0
  [ -d "$DIR" ] || return 0
  if stale; then regenerate || true; fi
  [ -f "$DIR/in-force.sha" ] || return 0
  IFS= read -r h < "$DIR/in-force.sha" || true
  [ -z "$h" ] || printf '%s\n' "$h"
}

cmd_export() {
  local mode=raw
  case "${1:-}" in
    "") ;;
    --handoff) mode=handoff; shift ;;
    *) usage_die "export takes only --handoff" ;;
  esac
  [ $# -eq 0 ] || usage_die "export takes only --handoff"
  resolve || return 0
  [ -d "$DIR" ] || return 0
  TODAY="${DECISIONS_DATE:-$(date +%Y-%m-%d)}"
  render "$mode"
}

cmd_path() {
  [ $# -eq 0 ] || usage_die "path takes no arguments"
  resolve || die "not inside a git repository: the record lives under its git directory"
  printf '%s\n' "$DIR"
}

CMD="${1:-}"
[ $# -eq 0 ] || shift
case "$CMD" in
  add) cmd_add "$@" ;;
  supersede) cmd_supersede "$@" ;;
  in-force) cmd_in_force "$@" ;;
  hash) cmd_hash "$@" ;;
  export) cmd_export "$@" ;;
  path) cmd_path "$@" ;;
  help|-h|--help) usage ;;
  "") usage >&2; exit 2 ;;
  *) usage_die "unknown command: $CMD" ;;
esac
