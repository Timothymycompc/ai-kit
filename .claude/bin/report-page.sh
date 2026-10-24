#!/usr/bin/env bash
# Render a page's JSON as a local HTML page in the project's reports folder: a decision
# sheet for /decide (a card per decision, its options as buttons, a notes box, a Copy
# answers button whose text the user pastes back, and the calls the run decided) or a
# report for /report (a TL;DR, sections of items with a status and links, and numbered
# Done / Warnings / Open lists).
#
# Usage: bash .claude/bin/report-page.sh <decisions|report> <file.json>
#
# Prints the page's absolute path on stdout and how to open it on stderr; it never opens
# it. The page goes to .claude/reports/ at the project root: the git top-level, else the
# current directory (.agents/reports/ when the script runs from an --agents install). Where
# that folder can't be written, it goes to ${TMPDIR:-/tmp}/kit-reports/, or to a private
# kit-reports.XXXXXX beside it when that one is another user's or others can write in it,
# and stderr says so. A .claude that is a link is followed, and so is git's core.worktree:
# whoever can change either already controls more than this script.
#
# Per page the folder holds <YYYY-MM-DD>-<HHMMSS>-<kind>-<slug>.html and, under the same
# name with .json, the JSON it was rendered from. The time is UTC, so the names sort in the
# order the pages were made whatever the session's time zone, and two runs that pick one
# name get -2, -3 and so on. index.json lists them (sequence, kind, title, date, file), and
# a .gitignore of "*" keeps them all out of git whatever the project's own .gitignore says,
# since a page can hold private decisions; stderr warns when git would still see a page.
# Every page carries a navigation bar listing every page in the folder, and making a page
# re-renders each earlier one from its saved JSON, so every bar stays current; a sheet's
# drafts are kept per page path, so a re-render keeps them. Nothing is pruned and each run
# rewrites every page, so a run's cost grows with the folder (measured on macOS: 1.7 s at
# 150 pages; 13 s, and 232 MB on disk, at 1000); stderr says so past 500 pages.
# REPORT_STAMP=YYYY-MM-DD-HHMMSS, in UTC, sets the time a page is stamped with.
#
# The JSON is embedded verbatim, every "<" written as \u003c so no string can close the
# script element, and the page renders every string with textContent, since the text can
# come from PRs, issues or agents. Only an https URL with no "." or ".." path segment, or a
# repo-relative path (an optional :line kept in its label) that names no dotfile and stays
# out of .git, becomes a link, the path resolved from the page so it opens from the folder;
# anything else shows as text. A GitHub pull request, issue or commit is labelled
# owner/repo#n or owner/repo@sha from the URL's own path, and a label in the data that names
# a URL or such a reference is not used. In the Copy answers text a line holds only the
# page's own delimiters: inside a field the arrow, "|", "[" and "]" are written "->", "/",
# "(" and ")", and line breaks, controls, zero-width and bidi characters become a space or
# go. The page fetches nothing (system fonts, and a CSP of default-src 'none'), because it
# can hold private decisions.
#
# The input checks are strict because the firewall allows this script without a prompt:
# it must not become a way to copy any file somewhere readable. It reads one regular file,
# once and at most 1 MiB of it, and goes on only if that is shaped like a page's JSON (an
# object naming "title" and "decisions", or "title" and "summary"), which a keypair, a JSON
# array, never is. An earlier page is re-rendered only from a regular file in the folder
# that passes the same shape check, when its page is this script's own or index.json lists
# it, and never from a file git tracks. Only a page this script wrote is ever replaced, and
# always by renaming a new file over it, so a link put in its place is replaced, never
# followed.
#
# python3, else node, checks the full shape and stops at the first problem, refusing a link
# that holds a line break or another control character; a validator that fails on the data
# refuses it. With neither interpreter, the page shows any parse error instead.
#   decisions: {"title": str, "date": str?, "intro": str?, "decisions": [{"id": str,
#     "number": int|str, "question": str, "why": str?, "recommended": <option value>?,
#     "options": [{"value": str, "label": str, "detail": str?}], "context": [str]?,
#     "premises": str?, "reversible": bool?, "blocks": str?, "links": [<link>]?}],
#     "decided": [<item>]?}
#   report: {"title": str, "date": str?, "summary": str | [str], "sections": [{"heading":
#     str, "items": [<item>]}]?, "done": [<item>]?, "warnings": [<item>]?, "open": [<item>]?}
#   <item>: str | {"text": str, "status": "PASS" | "NEEDS-FIX" | "REFUTED" | "UNVERIFIED"?,
#     "links": [<link>]?}
#   <link>: str | {"href": str, "label": str?}, where the string or href is an https URL or
#     a path from the project root, such as "src/lib.rs:42"
#
# Exit: 0 written; 1 the input or the folder was refused (why, on stderr); 2 usage.
set -euo pipefail
umask 077

ME="report-page"
MAX_BYTES=1048576
# Marks a page as this script's output: only a file that carries it is ever replaced.
MARKER='<meta name="generator" content="solana-ai-kit report-page">'
# A page's name without its extension: when it was made, its kind, and a slug of its title.
STEM_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-(decisions|report)-[a-z0-9]+(-[a-z0-9]+)*'
TAB="$(printf '\t')"

usage() {
  echo "Usage: bash .claude/bin/report-page.sh <decisions|report> <file.json>"
  echo "Writes a local HTML page to the project's reports folder and prints its path. The JSON shapes are in this script's header."
}
die() {
  echo "$ME: $*" >&2
  exit 1
}

NPOS=0
KIND=""
IN=""
positional() {
  NPOS=$((NPOS + 1))
  case "$NPOS" in
    1) KIND="$1" ;;
    2) IN="$1" ;;
  esac
}
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --)
      shift
      while [ $# -gt 0 ]; do positional "$1"; shift; done
      ;;
    -?*) echo "$ME: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) positional "$1"; shift ;;
  esac
done
[ "$NPOS" -eq 2 ] || { usage >&2; exit 2; }
case "$KIND" in
  decisions | report) ;;
  *) echo "$ME: the kind is decisions or report, not: $KIND" >&2; usage >&2; exit 2 ;;
esac
STAMP="${REPORT_STAMP:-}"
case "$STAMP" in
  '' | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) die "REPORT_STAMP must be YYYY-MM-DD-HHMMSS, got: $STAMP" ;;
esac

# --- awk helpers, shared by the input check and the folder's index ----------------------
# Run under LC_ALL=C, so lengths and comparisons are in bytes and UTF-8 passes through.
awk_lib() {
  cat <<'AWK'
# shaped(f, kind): f holds at most max bytes and is shaped like a page's JSON: its first
# non-blank character "{" (after an optional UTF-8 byte-order mark), naming "title" and the
# kind's key, "decisions" or, for a report, "summary".
function shaped(f, kind,    l, n, bytes, first, s, t, k, key) {
  key = (kind == "decisions") ? "\"decisions\"" : "\"summary\""
  n = 0; bytes = 0; first = ""; t = 0; k = 0
  while ((getline l < f) > 0) {
    if (++n == 1 && substr(l, 1, 3) == "\357\273\277") l = substr(l, 4)
    bytes += length(l) + 1
    if (bytes > max + 1) break
    if (first == "") { s = l; gsub(/[ \t\r]/, "", s); if (s != "") first = substr(s, 1, 1) }
    if (!t && l ~ /"title"[ \t\r]*:/) t = 1
    if (!k && index(l, key) && l ~ (key "[ \t\r]*:")) k = 1
  }
  close(f)
  return (n > 0 && bytes <= max + 1 && first == "{" && t && k)
}
# clean(t): t made a valid JSON string body. The escapes JSON allows stay, any other
# backslash is dropped, a bare quote is escaped, and a raw control character becomes a space.
function clean(t,    o, i, c, n, h) {
  o = ""
  for (i = 1; i <= length(t); i++) {
    c = substr(t, i, 1)
    if (c == "\\") {
      n = substr(t, i + 1, 1)
      h = substr(t, i + 2, 4)
      if (n != "" && index("\"\\/bfnrt", n)) { o = o c n; i++ }
      else if (n == "u" && h ~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) { o = o c n h; i += 5 }
      continue
    }
    if (c == "\"") { o = o "\\\""; continue }
    if (c < " ") c = " "
    o = o c
  }
  return o
}
# plain(t): a clean body as text; a \u escape outside printable ASCII becomes a space.
function plain(t,    o, i, c, n, h) {
  o = ""
  for (i = 1; i <= length(t); i++) {
    c = substr(t, i, 1)
    if (c != "\\") { o = o c; continue }
    n = substr(t, ++i, 1)
    if (n == "u") { h = hexnum(substr(t, i + 1, 4)); i += 4; o = o ((h >= 32 && h < 127) ? sprintf("%c", h) : " ") }
    else if (n == "\"" || n == "\\" || n == "/") o = o n
    else o = o " "
  }
  return o
}
function hexnum(h,    i, v) {
  v = 0
  h = tolower(h)
  for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
  return v
}
function html(t) {
  gsub(/&/, "\\&amp;", t)
  gsub(/</, "\\&lt;", t)
  gsub(/>/, "\\&gt;", t)
  return t
}
# guess(f): the raw body of the first "title" string in f, for when no JSON parser ran. It
# keeps the text from the first line naming "title" on, and at most 8 KiB of it, so a large
# file costs one pass.
function guess(f,    l, s, i, c, t, on) {
  s = ""; on = 0
  while ((getline l < f) > 0) {
    if (!on) { i = index(l, "\"title\""); if (!i) continue; on = 1; l = substr(l, i) }
    s = s " " l
    if (length(s) > 8192) break
  }
  close(f)
  if (!match(s, /"title"[ \t\r]*:[ \t\r]*"/)) return ""
  s = substr(s, RSTART + RLENGTH, 4096)
  t = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") { t = t c substr(s, i + 1, 1); i++; continue }
    if (c == "\"") return t
    t = t c
  }
  return ""
}
# cap(t, n): t cut to n bytes, dropping a multibyte character the cut would split. A title
# is capped before clean() and plain(), which build their result a character at a time.
function cap(t, n) {
  if (length(t) <= n) return t
  t = substr(t, 1, n)
  sub(/[\300-\377][\200-\277]*$/, "", t)
  return t
}
AWK
}

not_shaped() {
  case "$1" in
    decisions) echo "does not look like a decisions file: expected a JSON object with \"title\" and \"decisions\"" ;;
    *) echo "does not look like a report file: expected a JSON object with \"title\" and \"summary\"" ;;
  esac
}

# --- The input ------------------------------------------------------------------------
[ -e "$IN" ] || die "no such file: $IN"
[ -f "$IN" ] || die "not a regular file: $IN"
[ -r "$IN" ] || die "cannot read: $IN"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/report-page.XXXXXX" 2>/dev/null)" \
  || die "cannot create a temporary directory under ${TMPDIR:-/tmp}"
NEW_JSON=""
STAGE=""
# The new page's JSON is removed again if its page is never written, and so is the folder
# pages are written in before they are renamed into place.
cleanup() {
  rm -rf "$WORK"
  [ -z "$NEW_JSON" ] || rm -f "$NEW_JSON"
  [ -z "$STAGE" ] || rm -rf "$STAGE"
}
trap cleanup EXIT
# Read the file once, at most one byte past the limit, and check and embed only that copy:
# what was checked is what lands on the page.
head -c $((MAX_BYTES + 1)) < "$IN" > "$WORK/in.json" 2>/dev/null || die "cannot read: $IN"
SRC="$WORK/in.json"
BYTES="$({ wc -c < "$SRC"; } 2>/dev/null | tr -d ' ')" || BYTES=""
[ -n "$BYTES" ] || die "cannot read: $IN"
[ "$BYTES" -gt 0 ] || die "empty file: $IN"
[ "$BYTES" -le "$MAX_BYTES" ] || die "$IN is over $MAX_BYTES bytes, the most a page's JSON may be"
SHAPED="$(F="$SRC" K="$KIND" M="$MAX_BYTES" LC_ALL=C awk "$(awk_lib)"'
  BEGIN { max = ENVIRON["M"] + 0; print (shaped(ENVIRON["F"], ENVIRON["K"]) ? "yes" : "no") }')" || SHAPED=""
[ "$SHAPED" = yes ] || die "$IN $(not_shaped "$KIND")"

# Validators print one line, "OK <the title as a JSON string>" or "ERR <reason>", and exit 0
# or 3. Anything else means the interpreter itself could not run (a macOS python3 stub
# without the command line tools, say), and the next one is tried.
py_validator() {
  cat <<'PY'
import json, re, sys

STATUSES = ("PASS", "NEEDS-FIX", "REFUTED", "UNVERIFIED")
# A line break or another control character in a link breaks the page's reading of it.
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]")

def emit(kind, text):
    # As bytes, so a non-ASCII title prints under any locale.
    sys.stdout.buffer.write((kind + " " + text + "\n").encode("utf-8", "replace"))
    sys.stdout.flush()
    sys.exit(0 if kind == "OK" else 3)

def err(text):
    emit("ERR", " ".join(str(text).split()))

def show(v):
    s = json.dumps(v, ensure_ascii=False)
    return s if len(s) <= 60 else s[:57] + "..."

def no_constant(name):
    raise ValueError("%s is not JSON" % name)

def text(v):
    return isinstance(v, str) and v.strip() != ""

def given(o, k):
    return o.get(k) is not None

def links(at, v):
    if not isinstance(v, list):
        err(at + ".links must be an array")
    for i, l in enumerate(v):
        lat = "%s.links[%d]" % (at, i)
        if isinstance(l, dict):
            if not text(l.get("href")):
                err(lat + ".href must be a non-empty string")
            if given(l, "label") and not isinstance(l["label"], str):
                err(lat + ".label must be a string")
            shown = l["href"] + (l.get("label") or "")
        elif not text(l):
            err(lat + " must be a non-empty string or an object with an href")
        else:
            shown = l
        if CONTROL.search(shown):
            err(lat + " holds a line break or another control character")

def item(at, it):
    if isinstance(it, dict):
        if not text(it.get("text")):
            err(at + ".text must be a non-empty string")
        if given(it, "status") and it["status"] not in STATUSES:
            err("%s.status must be one of %s, not %s" % (at, ", ".join(STATUSES), show(it["status"])))
        if given(it, "links"):
            links(at, it["links"])
    elif not text(it):
        err(at + " must be a non-empty string or an object with a text")

def decisions(data):
    if given(data, "intro") and not isinstance(data["intro"], str):
        err('"intro" must be a string')
    ds = data.get("decisions")
    if not isinstance(ds, list) or not ds:
        err('"decisions" must be a non-empty array')
    ids = set()
    for i, d in enumerate(ds):
        at = "decisions[%d]" % i
        if not isinstance(d, dict):
            err(at + " must be an object")
        if not text(d.get("id")):
            err(at + ".id must be a non-empty string")
        if d["id"] in ids:
            err("%s.id %s is used twice" % (at, show(d["id"])))
        ids.add(d["id"])
        n = d.get("number")
        if isinstance(n, bool) or not (isinstance(n, int) or text(n)):
            err(at + ".number must be an integer or a non-empty string")
        if not text(d.get("question")):
            err(at + ".question must be a non-empty string")
        for k in ("why", "recommended", "premises", "blocks"):
            if given(d, k) and not isinstance(d[k], str):
                err("%s.%s must be a string" % (at, k))
        if given(d, "reversible") and not isinstance(d["reversible"], bool):
            err(at + ".reversible must be true or false")
        if given(d, "context") and not (isinstance(d["context"], list) and all(isinstance(c, str) for c in d["context"])):
            err(at + ".context must be an array of strings")
        if given(d, "links"):
            links(at, d["links"])
        options = d.get("options")
        if not isinstance(options, list) or not options:
            err(at + ".options must be a non-empty array")
        values = set()
        for j, o in enumerate(options):
            oat = "%s.options[%d]" % (at, j)
            if not isinstance(o, dict):
                err(oat + " must be an object")
            for k in ("value", "label"):
                if not text(o.get(k)):
                    err("%s.%s must be a non-empty string" % (oat, k))
            if given(o, "detail") and not isinstance(o["detail"], str):
                err(oat + ".detail must be a string")
            if o["value"] in values:
                err("%s.value %s is used twice" % (oat, show(o["value"])))
            values.add(o["value"])
        if text(d.get("recommended")) and d["recommended"] not in values:
            err("%s.recommended %s is not one of its option values" % (at, show(d["recommended"])))
    if given(data, "decided"):
        if not isinstance(data["decided"], list):
            err('"decided" must be an array')
        for j, it in enumerate(data["decided"]):
            item("decided[%d]" % j, it)

def report(data):
    s = data.get("summary")
    if not (text(s) or (isinstance(s, list) and s and all(text(x) for x in s))):
        err('"summary" must be a non-empty string or an array of non-empty strings')
    if given(data, "sections"):
        if not isinstance(data["sections"], list):
            err('"sections" must be an array')
        for i, sec in enumerate(data["sections"]):
            at = "sections[%d]" % i
            if not isinstance(sec, dict):
                err(at + " must be an object")
            if not text(sec.get("heading")):
                err(at + ".heading must be a non-empty string")
            its = sec.get("items")
            if not isinstance(its, list) or not its:
                err(at + ".items must be a non-empty array")
            for j, it in enumerate(its):
                item("%s.items[%d]" % (at, j), it)
    for k in ("done", "warnings", "open"):
        if given(data, k):
            if not isinstance(data[k], list):
                err('"%s" must be an array' % k)
            for j, it in enumerate(data[k]):
                item("%s[%d]" % (k, j), it)

def check(data):
    if not isinstance(data, dict):
        err("the top level must be an object")
    if not text(data.get("title")):
        err('"title" must be a non-empty string')
    if given(data, "date") and not isinstance(data["date"], str):
        err('"date" must be a string')
    (decisions if sys.argv[2] == "decisions" else report)(data)
    # The title names the page and its file; 200 characters of it are plenty.
    emit("OK", json.dumps(" ".join(data["title"].split())[:200], ensure_ascii=False))

try:
    with open(sys.argv[1], encoding="utf-8-sig") as f:
        data = json.load(f, parse_constant=no_constant)
except UnicodeDecodeError:
    err("not UTF-8 text")
except (ValueError, RecursionError) as e:
    err("not valid JSON: %s" % e)
except OSError as e:
    err("cannot read: %s" % e.strerror)

# A check that fails on the data, rather than refusing it, refuses it too: data the
# validator could not get through never becomes a page unchecked.
try:
    check(data)
except Exception as e:
    err("could not be checked (%s: %s)" % (type(e).__name__, ("%s" % e)[:200]))
PY
}

node_validator() {
  cat <<'JS'
const fs = require('fs');
const STATUSES = ['PASS', 'NEEDS-FIX', 'REFUTED', 'UNVERIFIED'];
class Refused extends Error {}
function err(m) { throw new Refused(m); }
const text = (v) => typeof v === 'string' && v.trim() !== '';
const given = (o, k) => o[k] !== undefined && o[k] !== null;
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const show = (v) => { const s = JSON.stringify(v); return s.length <= 60 ? s : s.slice(0, 57) + '...'; };
// A line break or another control character in a link breaks the page's reading of it.
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;
function links(at, v) {
  if (!Array.isArray(v)) err(at + '.links must be an array');
  v.forEach((l, i) => {
    const lat = at + '.links[' + i + ']';
    let shown;
    if (isObj(l)) {
      if (!text(l.href)) err(lat + '.href must be a non-empty string');
      if (given(l, 'label') && typeof l.label !== 'string') err(lat + '.label must be a string');
      shown = l.href + (typeof l.label === 'string' ? l.label : '');
    } else if (!text(l)) err(lat + ' must be a non-empty string or an object with an href');
    else shown = l;
    if (CONTROL.test(shown)) err(lat + ' holds a line break or another control character');
  });
}
function item(at, it) {
  if (isObj(it)) {
    if (!text(it.text)) err(at + '.text must be a non-empty string');
    if (given(it, 'status') && STATUSES.indexOf(it.status) < 0) {
      err(at + '.status must be one of ' + STATUSES.join(', ') + ', not ' + show(it.status));
    }
    if (given(it, 'links')) links(at, it.links);
  } else if (!text(it)) err(at + ' must be a non-empty string or an object with a text');
}
function decisions(data) {
  if (given(data, 'intro') && typeof data.intro !== 'string') err('"intro" must be a string');
  const ds = data.decisions;
  if (!Array.isArray(ds) || !ds.length) err('"decisions" must be a non-empty array');
  const ids = new Set();
  ds.forEach((d, i) => {
    const at = 'decisions[' + i + ']';
    if (!isObj(d)) err(at + ' must be an object');
    if (!text(d.id)) err(at + '.id must be a non-empty string');
    if (ids.has(d.id)) err(at + '.id ' + show(d.id) + ' is used twice');
    ids.add(d.id);
    if (!(Number.isInteger(d.number) || text(d.number))) err(at + '.number must be an integer or a non-empty string');
    if (!text(d.question)) err(at + '.question must be a non-empty string');
    for (const k of ['why', 'recommended', 'premises', 'blocks']) {
      if (given(d, k) && typeof d[k] !== 'string') err(at + '.' + k + ' must be a string');
    }
    if (given(d, 'reversible') && typeof d.reversible !== 'boolean') err(at + '.reversible must be true or false');
    if (given(d, 'context') && !(Array.isArray(d.context) && d.context.every((c) => typeof c === 'string'))) {
      err(at + '.context must be an array of strings');
    }
    if (given(d, 'links')) links(at, d.links);
    const os = d.options;
    if (!Array.isArray(os) || !os.length) err(at + '.options must be a non-empty array');
    const values = new Set();
    os.forEach((o, j) => {
      const oat = at + '.options[' + j + ']';
      if (!isObj(o)) err(oat + ' must be an object');
      for (const k of ['value', 'label']) {
        if (!text(o[k])) err(oat + '.' + k + ' must be a non-empty string');
      }
      if (given(o, 'detail') && typeof o.detail !== 'string') err(oat + '.detail must be a string');
      if (values.has(o.value)) err(oat + '.value ' + show(o.value) + ' is used twice');
      values.add(o.value);
    });
    if (text(d.recommended) && !values.has(d.recommended)) {
      err(at + '.recommended ' + show(d.recommended) + ' is not one of its option values');
    }
  });
  if (given(data, 'decided')) {
    if (!Array.isArray(data.decided)) err('"decided" must be an array');
    data.decided.forEach((it, j) => item('decided[' + j + ']', it));
  }
}
function report(data) {
  const s = data.summary;
  if (!(text(s) || (Array.isArray(s) && s.length && s.every(text)))) {
    err('"summary" must be a non-empty string or an array of non-empty strings');
  }
  if (given(data, 'sections')) {
    if (!Array.isArray(data.sections)) err('"sections" must be an array');
    data.sections.forEach((sec, i) => {
      const at = 'sections[' + i + ']';
      if (!isObj(sec)) err(at + ' must be an object');
      if (!text(sec.heading)) err(at + '.heading must be a non-empty string');
      if (!Array.isArray(sec.items) || !sec.items.length) err(at + '.items must be a non-empty array');
      sec.items.forEach((it, j) => item(at + '.items[' + j + ']', it));
    });
  }
  for (const k of ['done', 'warnings', 'open']) {
    if (given(data, k)) {
      if (!Array.isArray(data[k])) err('"' + k + '" must be an array');
      data[k].forEach((it, j) => item(k + '[' + j + ']', it));
    }
  }
}
function check(file, kind) {
  let raw, data;
  try { raw = fs.readFileSync(file); } catch (e) { err('cannot read: ' + e.code); }
  if (typeof TextDecoder === 'function') {
    try { raw = new TextDecoder('utf-8', { fatal: true }).decode(raw); } catch (e) { err('not UTF-8 text'); }
  } else {
    raw = raw.toString('utf8');
  }
  try { data = JSON.parse(raw.replace(/^\uFEFF/, '')); } catch (e) { err('not valid JSON: ' + e.message); }
  if (!isObj(data)) err('the top level must be an object');
  if (!text(data.title)) err('"title" must be a non-empty string');
  if (given(data, 'date') && typeof data.date !== 'string') err('"date" must be a string');
  (kind === 'decisions' ? decisions : report)(data);
  // The title names the page and its file; 200 characters of it are plenty.
  return JSON.stringify(Array.from(data.title.split(/\s+/).filter(Boolean).join(' ')).slice(0, 200).join(''));
}
let out;
try {
  out = 'OK ' + check(process.argv[1], process.argv[2]);
  process.exitCode = 0;
} catch (e) {
  // A check that fails on the data, rather than refusing it, refuses it too: data the
  // validator could not get through never becomes a page unchecked.
  const why = e instanceof Refused ? String(e.message)
    : 'could not be checked (' + String((e && e.name) || 'Error') + ': ' + String(e && e.message).slice(0, 200) + ')';
  out = 'ERR ' + why.split(/\s+/).filter(Boolean).join(' ');
  process.exitCode = 3;
}
process.stdout.write(out + '\n');
JS
}

VTITLE=""
VALIDATED=""
# try_validator <name> <command...> — 0 valid (the title in VTITLE); dies on invalid data;
# 1 when the interpreter could not run.
try_validator() {
  local name="$1" out rc=0
  shift
  out="$("$@" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "${out#OK }" != "$out" ]; then
    VTITLE="${out#OK }"
    VALIDATED="$name"
    return 0
  fi
  if [ "$rc" -eq 3 ] && [ "${out#ERR }" != "$out" ]; then
    die "$IN: ${out#ERR }"
  fi
  echo "$ME: $name could not run (exit $rc); not validating with it" >&2
  return 1
}
# -I: never import from the current directory, so a json.py a repo plants is not run.
if command -v python3 >/dev/null 2>&1; then
  try_validator python3 python3 -I -c "$(py_validator)" "$SRC" "$KIND" || true
fi
if [ -z "$VALIDATED" ] && command -v node >/dev/null 2>&1; then
  try_validator node node -e "$(node_validator)" "$SRC" "$KIND" || true
fi
[ -n "$VALIDATED" ] \
  || echo "$ME: no python3 or node to validate $IN; the page will show any problem in it" >&2

# The title as a JSON string body (for the index) and as text (for the file name): from the
# validator when one ran, else read from the file as well as can be done without a parser;
# 1 KiB of it at most.
TITLES="$(GIVEN="$VTITLE" F="$SRC" LC_ALL=C awk "$(awk_lib)"'
  BEGIN {
    t = ENVIRON["GIVEN"]
    if (t ~ /^".*"$/) t = substr(t, 2, length(t) - 2)
    else t = guess(ENVIRON["F"])
    t = clean(cap(t, 1024))
    print t "\t" plain(t)
  }')" || TITLES="$TAB"
TITLE_BODY="${TITLES%%"$TAB"*}"
TITLE_TEXT="${TITLES#*"$TAB"}"
SLUG="$(printf '%s' "$TITLE_TEXT" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9' '-' \
  | sed -e 's/--*/-/g' -e 's/^-//' | cut -c1-60 | sed -e 's/-$//')" || SLUG=""
[ -n "$SLUG" ] || SLUG="$KIND"

# --- Where it goes --------------------------------------------------------------------
# .claude, or .agents in an --agents install: the folder this script was installed in.
SELF="${BASH_SOURCE[0]}"
case "$SELF" in */*) SELF_DIR="${SELF%/*}" ;; *) SELF_DIR="." ;; esac
SELF_DIR="$(cd "$SELF_DIR" && pwd)"
CONFIG_DIR="${SELF_DIR%/*}"
CONFIG_NAME="${CONFIG_DIR##*/}"
case "$CONFIG_NAME" in .claude | .agents) ;; *) CONFIG_NAME=".claude" ;; esac
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT=""
IN_GIT=""
[ -z "$ROOT" ] || IN_GIT=1
[ -n "$ROOT" ] || ROOT="$(pwd)"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || die "cannot enter the project root: $ROOT"
# Printed and opened by this path, not a resolved one, so "../../" from a page is the root.
DIR="$ROOT/$CONFIG_NAME/reports"
ROOT_PREFIX="../../"

# writable <dir> — a real directory, not a link, that this user owns and can create a file
# in (a probe, since a sandbox can refuse what the permission bits allow).
writable() {
  local probe
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  probe="$(mktemp "$1/.report-page.XXXXXX" 2>/dev/null)" || return 1
  rm -f "$probe"
}
# loose <dir> — group or other may write in it, so someone else could swap its files.
loose() {
  case "$(ls -ld "$1" 2>/dev/null | cut -c1-10)" in
    ?????w???? | ????????w?) return 0 ;;
  esac
  return 1
}
WHY=""
if [ -L "$DIR" ]; then
  WHY="it is a symbolic link"
elif ! mkdir -p "$DIR" 2>/dev/null; then
  WHY="it cannot be created"
elif ! writable "$DIR"; then
  WHY="it cannot be written"
fi
if [ -n "$WHY" ]; then
  BASE="${TMPDIR:-/tmp}"
  BASE="${BASE%/}"
  FALLBACK="$BASE/kit-reports"
  mkdir -p "$FALLBACK" 2>/dev/null || true
  # On a shared /tmp another user can create that name first, or it can be open to others:
  # use a private one then.
  if ! writable "$FALLBACK" || loose "$FALLBACK"; then
    FALLBACK="$(mktemp -d "$BASE/kit-reports.XXXXXX" 2>/dev/null)" \
      || die "cannot use $DIR ($WHY), nor create a folder for the page under $BASE"
  fi
  FALLBACK="$(cd "$FALLBACK" && pwd -P)" || die "cannot enter $FALLBACK"
  echo "$ME: $DIR cannot be used ($WHY); the page goes to $FALLBACK instead" >&2
  DIR="$FALLBACK"
  # Nothing to resolve a project path against from here, so paths stay text.
  ROOT_PREFIX=""
else
  # Whatever the project's .gitignore says. Written once, never over a file or a link:
  # noclobber refuses both.
  if [ ! -e "$DIR/.gitignore" ] && [ ! -L "$DIR/.gitignore" ]; then
    ( set -C; printf '%s\n' "# Pages written by solana-ai-kit's report-page.sh can hold private decisions: git ignores them all." '*' \
      > "$DIR/.gitignore" ) 2>/dev/null || true
  fi
fi

# names — the page files in the folder, one per line.
names() {
  local f
  for f in "$DIR"/*.html "$DIR"/*.json; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done
}
stems() {
  names | LC_ALL=C grep -E "^$STEM_RE\\.(html|json)\$" | LC_ALL=C sed -E 's/\.(html|json)$//' | LC_ALL=C sort -u
}
LAST="$(stems | tail -n 1 | cut -c1-17)" || LAST=""
if [ -z "$STAMP" ]; then
  # In UTC, so the names sort in the order the pages were made whatever the time zone.
  STAMP="$(date -u +%Y-%m-%d-%H%M%S)"
  # A page made in the same second as the last would sort by kind and slug rather than by
  # time: wait for the next second.
  n=0
  while [ "$STAMP" = "$LAST" ] && [ "$n" -lt 3 ]; do
    sleep 1
    STAMP="$(date -u +%Y-%m-%d-%H%M%S)"
    n=$((n + 1))
  done
fi

# put <file> <name> — copy into the folder through a temp file, so a failed write leaves
# nothing half-written and a link at the target is replaced, never followed.
put() {
  local tmp
  [ ! -d "$DIR/$2" ] || return 1
  tmp="$(mktemp "$DIR/.report-page.XXXXXX" 2>/dev/null)" || return 1
  if ! cat "$1" > "$tmp" || ! mv -f "$tmp" "$DIR/$2" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
}
# taken <name> — something in the folder already has that name.
taken() { [ -e "$DIR/$1" ] || [ -L "$DIR/$1" ]; }
# claim <stem> — create <stem>.json empty, failing when anything has that name: noclobber
# opens it with O_EXCL, so of two runs that pick one name only one gets it.
claim() { ( set -C; : > "$DIR/$1.json" ) 2>/dev/null; }
STEM0="$STAMP-$KIND-$SLUG"
STEM="$STEM0"
n=1
while :; do
  if ! taken "$STEM.html"; then
    claim "$STEM" && break
    taken "$STEM.json" || die "cannot write in $DIR"
  fi
  n=$((n + 1))
  [ "$n" -le 99 ] || die "too many pages named $STEM0 in $DIR"
  STEM="$STEM0-$n"
done
NEW_JSON="$DIR/$STEM.json"
put "$SRC" "$STEM.json" || die "cannot write in $DIR"

# --- Every page in the folder ---------------------------------------------------------
# ours <path> — a page this script wrote: a regular file, not a link, with the marker in
# its first lines.
ours() {
  local l n=0
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  while [ "$n" -lt 12 ] && IFS= read -r -n 4096 l; do
    [ "$l" = "$MARKER" ] && return 0
    n=$((n + 1))
  done < "$1"
  return 1
}
# Titles already known, from the index this script wrote: "stem<TAB>title" per page.
: > "$WORK/known"
if [ -f "$DIR/index.json" ] && [ ! -L "$DIR/index.json" ]; then
  LC_ALL=C sed -nE 's/^\{"sequence": [0-9]+, "kind": "(decisions|report)", "date": "[^"]*", "file": "('"$STEM_RE"')\.html", "title": "(([^"\\]|\\.)*)"\},?$/\2'"$TAB"'\5/p' \
    "$DIR/index.json" > "$WORK/known" 2>/dev/null || : > "$WORK/known"
fi
# Page files git tracks came from elsewhere, a cloned repository say, since this script
# commits nothing: their pages are left alone like any other it did not write.
: > "$WORK/tracked"
if [ -n "$IN_GIT" ] && [ "$DIR" = "$ROOT/$CONFIG_NAME/reports" ]; then
  { (cd "$ROOT" && git ls-files -- "$CONFIG_NAME/reports") 2>/dev/null \
    | LC_ALL=C sed -nE 's#^(.*/)?('"$STEM_RE"')\.(html|json)$#\2#p' > "$WORK/tracked"; } || : > "$WORK/tracked"
fi
# Per page, "stem<TAB>kind<TAB>page<TAB>json": page 1 when the page is this script's, 2 when
# it is an empty regular file, as a write cut short before its first byte leaves one, and 0
# when there is none; json 1 when the JSON is a regular file. Any other file with a page's
# name is left alone, and so is its page.
: > "$WORK/pages"
FOREIGN=""
while IFS= read -r s; do
  rest="${s:18}"
  k="${rest%%-*}"
  h=0
  j=0
  if [ -e "$DIR/$s.html" ] || [ -L "$DIR/$s.html" ]; then
    if ours "$DIR/$s.html"; then
      h=1
    elif [ -f "$DIR/$s.html" ] && [ ! -L "$DIR/$s.html" ] && [ ! -s "$DIR/$s.html" ]; then
      h=2
    else
      FOREIGN="$FOREIGN $s.html"
      continue
    fi
  fi
  [ -f "$DIR/$s.json" ] && [ ! -L "$DIR/$s.json" ] && j=1
  printf '%s\t%s\t%s\t%s\n' "$s" "$k" "$h" "$j" >> "$WORK/pages"
done < <(stems)

# The index, and per page "stem<TAB>kind<TAB>render|stale|skip|tracked<TAB>title as HTML".
# A page is rendered from its JSON when that passes the shape check and the page is this
# script's, or is missing or empty and index.json lists it: a page-named JSON with neither,
# left by a run still in progress or put there by someone else, never becomes a page. A
# page of this script's whose JSON is gone stays in the bar unrefreshed.
: > "$WORK/list"
DIR="$DIR" M="$MAX_BYTES" NEWSTEM="$STEM" NEWTITLE="$TITLE_BODY" \
  OUT_INDEX="$WORK/index.json" OUT_LIST="$WORK/list" LC_ALL=C awk "$(awk_lib)"'
  BEGIN { FS = "\t"; max = ENVIRON["M"] + 0; dir = ENVIRON["DIR"]; newstem = ENVIRON["NEWSTEM"] }
  FILENAME == ARGV[1] { if (!($1 in known)) known[$1] = cap($2, 1024); next }
  FILENAME == ARGV[2] { tracked[$1] = 1; next }
  {
    stem = $1; kind = $2; page = $3 + 0
    if (stem != newstem && (stem in tracked)) { print stem "\t" kind "\ttracked\t" > ENVIRON["OUT_LIST"]; next }
    good = ($4 == 1) && shaped(dir "/" stem ".json", kind)
    if (stem != newstem && page != 1 && !(good && (stem in known))) {
      if (page == 2) print stem "\t" kind "\tskip\t" > ENVIRON["OUT_LIST"]
      next
    }
    if (stem == newstem) t = ENVIRON["NEWTITLE"]
    else if (stem in known) t = known[stem]
    else if (good) t = guess(dir "/" stem ".json")
    else t = ""
    t = clean(cap(t, 1024))
    if (t == "") t = (kind == "report") ? "Report" : "Decision sheet"
    n++
    entry[n] = sprintf("{\"sequence\": %d, \"kind\": \"%s\", \"date\": \"%s %s:%s:%s UTC\", \"file\": \"%s.html\", \"title\": \"%s\"}", \
      n, kind, substr(stem, 1, 10), substr(stem, 12, 2), substr(stem, 14, 2), substr(stem, 16, 2), stem, t)
    print stem "\t" kind "\t" (good ? "render" : "stale") "\t" html(plain(t)) > ENVIRON["OUT_LIST"]
  }
  END {
    print "[" > ENVIRON["OUT_INDEX"]
    for (i = 1; i <= n; i++) print entry[i] (i < n ? "," : "") > ENVIRON["OUT_INDEX"]
    print "]" > ENVIRON["OUT_INDEX"]
  }' "$WORK/known" "$WORK/tracked" "$WORK/pages" || die "cannot list the pages in $DIR"

# --- The page -------------------------------------------------------------------------
NONCE="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || NONCE=""
case "$NONCE" in '' | *[!0-9a-f]*) NONCE="$(printf '%x%x%x' "$$" "$(date +%s)" "$RANDOM")" ;; esac

emit_css() {
  cat <<'CSS'
:root {
  --bg: #f4f6f9; --panel: #ffffff; --fg: #16202c; --muted: #5a6676; --line: #c7cfda;
  --teal: #0d7774; --teal-soft: #dff1f0; --amber: #a85f00; --amber-soft: #fbeedb;
  --red: #b0352c; --red-soft: #f8e3e0; --code: #edf0f5; --focus: #2457c5;
  --display: "Avenir Next", "Segoe UI Variable Display", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --body: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --bg: #0e131a; --panel: #151c25; --fg: #e3e8ef; --muted: #98a4b4; --line: #2b3543;
  --teal: #4fc4be; --teal-soft: #11302f; --amber: #f2a843; --amber-soft: #392810;
  --red: #f07b70; --red-soft: #3a1c19; --code: #1a2330; --focus: #8fb0ff; color-scheme: dark } }
:root[data-theme="dark"] {
  --bg: #0e131a; --panel: #151c25; --fg: #e3e8ef; --muted: #98a4b4; --line: #2b3543;
  --teal: #4fc4be; --teal-soft: #11302f; --amber: #f2a843; --amber-soft: #392810;
  --red: #f07b70; --red-soft: #3a1c19; --code: #1a2330; --focus: #8fb0ff; color-scheme: dark }
*, *::before, *::after { box-sizing: border-box; }
[hidden] { display: none !important; }
html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.6 var(--body); padding: 0 16px; }
.wrap { max-width: 880px; margin: 0 auto; padding: 20px 0 24px; display: grid; gap: 28px; min-width: 0; }
header { display: grid; gap: 12px; }
.eyebrow { font: 600 12px/1.2 var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
h1 { font: 800 clamp(30px, 5.5vw, 46px)/1.05 var(--display); margin: 0; letter-spacing: -.02em; text-wrap: balance; overflow-wrap: anywhere; }
h2 { font: 700 clamp(20px, 3vw, 25px)/1.2 var(--display); margin: 0; letter-spacing: -.01em; overflow-wrap: anywhere; }
h3 { font: 600 17px/1.35 var(--body); margin: 0; overflow-wrap: anywhere; }
p { margin: 0; max-width: 72ch; }
a { color: var(--teal); }
.lede { font-size: 18px; color: var(--muted); white-space: pre-line; }
.how { font-size: 15px; color: var(--muted); }
.warn { font-size: 14px; color: var(--amber); border-left: 3px solid var(--amber); padding-left: 10px; }
.err { background: var(--red-soft); color: var(--red); border: 1px solid var(--red); border-radius: 10px; padding: 14px 16px; overflow-wrap: anywhere; }
nav.pages { display: flex; align-items: center; gap: 8px; min-width: 0; }
nav.pages ol { position: relative; flex: 1 1 auto; min-width: 0; display: flex; gap: 6px; margin: 0; padding: 2px; list-style: none; overflow-x: auto; scrollbar-width: thin; }
nav.pages li { flex: none; }
nav.pages a, nav.pages .step { display: inline-flex; align-items: baseline; gap: 6px; padding: 6px 10px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); color: var(--fg); font-size: 13px; line-height: 1.3; text-decoration: none; white-space: nowrap; }
nav.pages a:hover { border-color: var(--muted); }
nav.pages a[aria-current="page"] { border-color: var(--teal); background: var(--teal-soft); }
nav.pages .step { flex: none; color: var(--teal); font: 600 12px/1.3 var(--mono); }
nav.pages .step.off { color: var(--muted); opacity: .45; }
nav.pages .seq { font: 600 11px var(--mono); color: var(--muted); font-variant-numeric: tabular-nums; }
nav.pages .kind { font: 700 10px var(--mono); color: var(--amber); }
nav.pages .nt { display: inline-block; max-width: 24ch; overflow: hidden; text-overflow: ellipsis; vertical-align: bottom; }
.decisions { display: grid; gap: 16px; }
.dec { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 18px; display: grid; gap: 12px; min-width: 0; }
.dec[data-answered="1"] { border-color: var(--teal); }
.dec-head { display: grid; grid-template-columns: auto 1fr auto; gap: 12px; align-items: baseline; }
.dec-head > * { min-width: 0; }
.dnum { font: 800 22px/1 var(--display); color: var(--amber); font-variant-numeric: tabular-nums; }
.why { color: var(--muted); font-size: 15px; white-space: pre-line; }
.status { font: 600 11px/1 var(--mono); padding: 5px 8px; border-radius: 999px; border: 1px solid var(--line); color: var(--muted); white-space: nowrap; }
.status[data-kind="done"] { color: var(--teal); border-color: var(--teal); background: var(--teal-soft); }
.status[data-kind="notes"] { color: var(--amber); border-color: var(--amber); background: var(--amber-soft); }
fieldset.opts { border: 0; margin: 0; padding: 0; display: grid; gap: 8px; min-width: 0; }
.sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
label.opt { display: grid; grid-template-columns: 20px 1fr; gap: 10px; align-items: start; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; cursor: pointer; }
label.opt:hover { border-color: var(--muted); }
label.opt.on { border-color: var(--teal); background: var(--teal-soft); }
label.opt input { margin: 5px 0 0; accent-color: var(--teal); }
label.opt span { min-width: 0; overflow-wrap: anywhere; }
label.opt b { font-weight: 600; }
label.opt small { display: block; color: var(--muted); font-size: 14px; line-height: 1.5; white-space: pre-line; }
.rec { font: 600 10px/1 var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--amber); margin-left: 8px; font-style: normal; white-space: nowrap; }
details.ctx { border-top: 1px dashed var(--line); padding-top: 10px; }
details.ctx > summary { cursor: pointer; color: var(--teal); font: 600 13px var(--mono); }
details.ctx > .body { padding-top: 10px; display: grid; gap: 10px; font-size: 15px; }
details.ctx p { white-space: pre-line; overflow-wrap: anywhere; }
.notes-l { font: 600 12px var(--mono); color: var(--muted); }
textarea { width: 100%; font: 15px/1.5 var(--body); color: var(--fg); background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 8px 10px; resize: vertical; }
#copybox { font: 13px/1.5 var(--mono); }
.bar { position: sticky; bottom: 0; z-index: 5; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 12px 16px calc(12px + env(safe-area-inset-bottom, 0px)); display: flex; flex-wrap: wrap; gap: 10px 16px; align-items: center; justify-content: space-between; box-shadow: 0 -6px 18px rgb(0 0 0 / .10); }
.bar p { font-size: 14px; color: var(--muted); }
.bar b { color: var(--fg); font-variant-numeric: tabular-nums; }
button { font: 600 14px var(--body); padding: 9px 14px; border-radius: 8px; border: 1px solid var(--teal); background: var(--teal); color: var(--panel); cursor: pointer; }
button:hover { filter: brightness(1.08); }
button[disabled] { opacity: .5; cursor: not-allowed; filter: none; }
.report { display: grid; gap: 28px; min-width: 0; }
.tldr { background: var(--panel); border: 1px solid var(--line); border-left: 4px solid var(--teal); border-radius: 12px; padding: 16px 18px; display: grid; gap: 10px; min-width: 0; }
.tldr h2, .blk h2 { font: 600 12px/1.2 var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--teal); }
.tldr ul { margin: 0; padding: 0; list-style: none; display: grid; gap: 8px; }
.tldr li { display: grid; grid-template-columns: 14px 1fr; gap: 10px; align-items: baseline; max-width: 76ch; white-space: pre-line; overflow-wrap: anywhere; }
.tldr li::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--teal); transform: translateY(-2px); }
.tldr > p { font-size: 17px; white-space: pre-line; overflow-wrap: anywhere; }
.tally { display: flex; flex-wrap: wrap; gap: 8px; }
.sec { display: grid; gap: 12px; min-width: 0; }
ul.items { margin: 0; padding: 0; list-style: none; display: grid; gap: 10px; }
ul.items > li { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; display: grid; gap: 6px; min-width: 0; }
.it { display: flex; gap: 10px; align-items: baseline; min-width: 0; }
.tx { min-width: 0; white-space: pre-line; overflow-wrap: anywhere; }
.pill { flex: none; display: inline-block; font: 600 11px/1 var(--mono); letter-spacing: .04em; padding: 5px 8px; border-radius: 999px; border: 1px solid var(--line); color: var(--muted); white-space: nowrap; }
.pill[data-status="PASS"] { color: var(--teal); border-color: var(--teal); background: var(--teal-soft); }
.pill[data-status="NEEDS-FIX"] { color: var(--amber); border-color: var(--amber); background: var(--amber-soft); }
.pill[data-status="REFUTED"] { color: var(--red); border-color: var(--red); background: var(--red-soft); }
.pill[data-status="UNVERIFIED"] { border-style: dashed; }
p.links { display: flex; flex-wrap: wrap; gap: 4px 14px; font: 13px/1.5 var(--mono); max-width: none; min-width: 0; }
p.links a, p.links span { min-width: 0; overflow-wrap: anywhere; }
p.links .nolink { color: var(--muted); }
.blocks { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 250px), 1fr)); gap: 12px; }
.blk { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; display: grid; gap: 10px; align-content: start; min-width: 0; }
.blk[data-block="warnings"] h2 { color: var(--amber); }
.blk[data-block="open"] h2 { color: var(--red); }
.blk ol { margin: 0; padding-left: 22px; display: grid; gap: 8px; }
.blk li { min-width: 0; }
.blk li > p.links { margin-top: 4px; }
.blk li::marker { font: 600 13px var(--mono); color: var(--muted); }
footer { font-size: 13px; color: var(--muted); border-top: 1px solid var(--line); padding-top: 14px; }
:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }
@media (max-width: 540px) {
  .dec-head { grid-template-columns: auto 1fr; }
  .dec-head .status { grid-column: 2; justify-self: start; }
  nav.pages .step { padding: 6px 8px; }
  nav.pages .nt { max-width: 16ch; }
}
CSS
}

emit_body() {
  if [ "$1" = report ]; then
    cat <<'HTML'
<div class="wrap">
<nav class="pages" id="pages" aria-label="Pages in this folder, oldest first" hidden></nav>
<header>
  <div class="eyebrow" id="eyebrow">Report</div>
  <h1 id="title">Report</h1>
</header>
<noscript><p class="err">This page needs JavaScript to show its content.</p></noscript>
<p class="err" id="error" role="alert" hidden></p>
<main class="report" id="app"></main>
<footer>Written by solana-ai-kit&rsquo;s report-page.sh. This page makes no network requests; a link opens only when you follow it.</footer>
</div>
HTML
  else
    cat <<'HTML'
<div class="wrap">
<nav class="pages" id="pages" aria-label="Pages in this folder, oldest first" hidden></nav>
<header>
  <div class="eyebrow" id="eyebrow">Decision sheet</div>
  <h1 id="title">Decisions</h1>
  <p class="lede" id="intro" hidden></p>
  <p class="how">Pick an option for each decision. Open Context for what it rests on, and add a note to change or add anything. Nothing on this page goes online, and your choices stay in this browser until you copy them. When you&rsquo;re done, press Copy answers and paste the text into the terminal.</p>
  <p class="warn" id="storage-note" hidden>This browser won&rsquo;t let the page keep drafts, so reloading it loses your choices. Copy them before you close it.</p>
</header>
<noscript><p class="err">This page needs JavaScript to show its content.</p></noscript>
<p class="err" id="error" role="alert" hidden></p>
<main class="decisions" id="app"></main>
<div class="bar" id="bar">
  <p><b id="count" aria-live="polite">0 of 0</b> answered &middot; Copy, then paste this in the terminal.</p>
  <button type="button" id="copy">Copy answers</button>
</div>
<textarea id="copybox" rows="8" hidden readonly aria-label="Your answers as text"></textarea>
<footer>Written by solana-ai-kit&rsquo;s report-page.sh. This page makes no network requests, and its drafts stay in this browser.</footer>
</div>
HTML
  fi
}

emit_js() {
  cat <<'JS'
(function () {
  'use strict';
  var doc = document;
  function $(id) { return doc.getElementById(id); }
  function str(v) { return typeof v === 'string' ? v : (v === null || v === undefined) ? '' : String(v); }
  function line(v) { return str(v).replace(/\s+/g, ' ').trim(); }
  // field(v): v for the Copy answers text, which /decide reads by its delimiters. Line
  // breaks and other controls become a space, zero-width and bidi characters go, and the
  // delimiters (the arrow, "|", "[" and "]") are written "->", "/", "(" and ")", so a line
  // holds only the page's own.
  var INVISIBLE_RE = /[\u00ad\u061c\u180e\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u206f\ufeff]/g;
  var CONTROL_RE = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g;
  function field(v) {
    return str(v).replace(INVISIBLE_RE, '').replace(CONTROL_RE, ' ').replace(/\s+/g, ' ').trim()
      .replace(/\u2192/g, '->').replace(/\|/g, '/').replace(/\[/g, '(').replace(/\]/g, ')');
  }
  function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
  // Every string from the data goes in through textContent or a text node, never as markup.
  function el(tag, cls, text) {
    var e = doc.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  }

  var dataEl = $('page-data');
  var KIND = dataEl.getAttribute('data-kind') === 'report' ? 'report' : 'decisions';
  var NAME = KIND === 'report' ? 'Report' : 'Decision sheet';
  var FILE = str(dataEl.getAttribute('data-file'));
  // A path resolves from the project root, two folders up from the page. A page outside the
  // project's reports folder has no root to resolve against, so its paths stay text.
  var ROOT = dataEl.getAttribute('data-root') === '../../' ? '../../' : '';
  var PAGE_RE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-(decisions|report)-[a-z0-9]+(-[a-z0-9]+)*\.html$/;
  var STATUS = { 'PASS': 1, 'NEEDS-FIX': 1, 'REFUTED': 1, 'UNVERIFIED': 1 };

  function fail(message) {
    var err = $('error');
    err.textContent = message;
    err.hidden = false;
    if ($('copy')) $('copy').disabled = true;
    if ($('count')) $('count').textContent = '0 of 0';
    doc.title = NAME + ': unreadable';
  }

  // --- Links: an https URL or a path from the project root, nothing else ---------------
  // A URL with a user name, any other scheme, an absolute path, a path that climbs out
  // with "..", and anything holding a space or a backslash shows as text.
  var HTTPS_RE = /^https:\/\/[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*(?::[0-9]{1,5})?(\/[^\s"<>\\^`{|}?#]*)?(?:[?#][^\s"<>\\^`{|}]*)?$/;
  // httpsPath(raw): the path of an https URL that may be a link, else null. A "." or ".."
  // segment, written out or %2e-encoded, makes the browser open a path other than the one
  // shown, so a URL holding one stays text.
  function httpsPath(raw) {
    var m = raw.length <= 2048 ? HTTPS_RE.exec(raw) : null;
    if (!m) return null;
    var path = m[1] || '';
    return path.split('/').some(function (s) { return /^(?:\.|%2e){1,2}$/i.test(s); }) ? null : path;
  }
  // urlLabel(raw, path): a GitHub pull request, issue or commit as owner/repo#n or
  // owner/repo@sha, read from the URL's own path; else the URL without its scheme.
  function urlLabel(raw, path) {
    var m;
    if (/^https:\/\/github\.com\//.test(raw)) {
      m = /^\/([A-Za-z0-9-]+)\/([A-Za-z0-9_.-]+)\/(?:pull|issues)\/([0-9]+)(?:\/|$)/.exec(path);
      if (m) return m[1] + '/' + m[2] + '#' + m[3];
      m = /^\/([A-Za-z0-9-]+)\/([A-Za-z0-9_.-]+)\/commit\/([0-9a-fA-F]{7,40})(?:\/|$)/.exec(path);
      if (m) return m[1] + '/' + m[2] + '@' + m[3].slice(0, 7);
    }
    var s = raw.replace(/^https:\/\//, '').replace(/\/$/, '');
    return s.length > 72 ? s.slice(0, 71) + '\u2026' : s;
  }
  // A label from the data that names a URL or a GitHub reference could pass for a target
  // other than its link's, so the link's own label is shown instead.
  var TARGET_RE = /:\/\/|^www\.|[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:#[0-9]+|@[0-9a-fA-F]{7,40})|(?:^|\s)#[0-9]+/i;
  // "src/lib.rs:42" -> "../../src/lib.rs": the line stays in the label only. A dotfile such
  // as .env, and anything inside .git, stays text: following the link would open it here.
  function pathHref(raw) {
    if (!ROOT) return '';
    var m = /^([\s\S]*?)(?::[0-9]+(?:[-:][0-9]+)?)?$/.exec(raw);
    if (!m) return '';
    var p = m[1], dir = false;
    if (p.slice(0, 2) === './') p = p.slice(2);
    if (p.length > 1 && p.charAt(p.length - 1) === '/') { dir = true; p = p.slice(0, -1); }
    if (!p || p.length > 512 || !/^[A-Za-z0-9._]/.test(p) || /[\s\x00-\x1f\x7f\\:*?"<>|#%]/.test(p)) return '';
    var parts = p.split('/');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] === '' || parts[i] === '.' || parts[i] === '..' || /^\.git$/i.test(parts[i])) return '';
    }
    if (parts[parts.length - 1].charAt(0) === '.') return '';
    return ROOT + parts.map(encodeURIComponent).join('/') + (dir ? '/' : '');
  }
  function linksRow(list) {
    if (!Array.isArray(list)) return null;
    var row = el('p', 'links'), n = 0;
    list.forEach(function (spec) {
      var raw = str(isObj(spec) ? spec.href : spec).trim();
      if (!raw) return;
      var label = isObj(spec) ? line(spec.label) : '', href = '', path = httpsPath(raw), a;
      if (TARGET_RE.test(label)) label = '';
      if (path !== null) {
        href = raw;
        label = label || urlLabel(raw, path);
      } else {
        href = pathHref(raw);
        label = label || raw;
      }
      if (href) {
        a = el('a', null, label);
        a.setAttribute('href', href);
        a.setAttribute('target', '_blank');
        a.setAttribute('rel', 'noopener noreferrer');
        if (label !== raw) a.setAttribute('title', raw);
      } else {
        // Not a link: shown as written, so nothing passes for one.
        a = el('span', 'nolink', raw);
      }
      row.appendChild(a);
      n++;
    });
    return n ? row : null;
  }

  // --- The navigation bar: every page in this folder, oldest first ---------------------
  function navbar() {
    var nav = $('pages'), src = $('nav-data');
    if (!nav || !src) return;
    var list;
    try { list = JSON.parse(str(src.textContent).trim() || '[]'); } catch (e) { return; }
    var pages = (Array.isArray(list) ? list : []).filter(function (p) { return isObj(p) && PAGE_RE.test(str(p.file)); });
    if (!pages.length) return;
    var cur = -1;
    pages.forEach(function (p, i) { if (p.file === FILE) cur = i; });
    function name(p) { return (p.kind === 'report' ? 'Report' : 'Decisions') + ': ' + (line(p.title) || '(untitled)'); }
    function step(text, p, rel) {
      var a;
      if (p) {
        a = el('a', 'step', text);
        a.setAttribute('href', p.file);
        a.setAttribute('rel', rel);
        a.setAttribute('title', name(p));
      } else {
        a = el('span', 'step off', text);
        a.setAttribute('aria-hidden', 'true');
      }
      return a;
    }
    nav.appendChild(step('\u2190 Previous', cur > 0 ? pages[cur - 1] : null, 'prev'));
    var ol = el('ol'), here = null;
    pages.forEach(function (p, i) {
      var li = el('li'), a = el('a');
      a.setAttribute('href', p.file);
      a.setAttribute('title', name(p) + (line(p.date) ? ' \u00b7 ' + line(p.date) : ''));
      a.appendChild(el('span', 'seq', String(i + 1)));
      a.appendChild(el('span', 'kind', p.kind === 'report' ? 'R' : 'D'));
      a.appendChild(el('span', 'nt', line(p.title) || '(untitled)'));
      if (i === cur) { a.setAttribute('aria-current', 'page'); here = a; }
      li.appendChild(a);
      ol.appendChild(li);
    });
    nav.appendChild(ol);
    nav.appendChild(step('Next \u2192', cur >= 0 && cur < pages.length - 1 ? pages[cur + 1] : null, 'next'));
    nav.hidden = false;
    // Bring the current page into view inside the bar, without scrolling the page itself.
    if (here && typeof here.offsetLeft === 'number' && typeof ol.clientWidth === 'number') {
      ol.scrollLeft = Math.max(0, here.offsetLeft - (ol.clientWidth - here.offsetWidth) / 2);
    }
  }

  // --- A decision sheet -----------------------------------------------------------------
  function decisions(data) {
    var app = $('app'), countEl = $('count'), copyBtn = $('copy'), box = $('copybox');
    var COPY_LABEL = 'Copy answers';
    var items = [], seen = Object.create(null);
    (Array.isArray(data.decisions) ? data.decisions : []).forEach(function (d, i) {
      if (!isObj(d)) return;
      var id = line(d.id) || 'd' + (i + 1);
      var opts = [];
      (Array.isArray(d.options) ? d.options : []).forEach(function (o, j) {
        if (!isObj(o)) return;
        var label = line(o.label) || line(o.value) || 'Option ' + (j + 1);
        opts.push({ value: str(o.value) || label, label: label, detail: str(o.detail).trim() });
      });
      items.push({
        n: i, id: id, key: seen[id] ? id + '#' + i : id, d: d, opts: opts, radios: [], labels: [],
        number: line(d.number) || String(i + 1),
        question: line(d.question) || '(no question given)'
      });
      seen[id] = true;
    });
    if (!items.length) {
      fail('This sheet holds no decisions: its data needs a non-empty "decisions" array. Fix its JSON and run report-page.sh again.');
      return;
    }

    var title = line(data.title) || 'Decisions';
    var date = line(data.date) || line(dataEl.getAttribute('data-date'));
    doc.title = title;
    $('title').textContent = title;
    $('eyebrow').textContent = NAME + (date ? ' \u00b7 ' + date : '');
    if (str(data.intro).trim()) {
      var intro = $('intro');
      intro.textContent = str(data.intro).trim();
      intro.hidden = false;
    }

    // Drafts live in this browser only, one set per page, keyed by the page's path: a
    // re-rendered page keeps them, and a page of the same name in another folder keeps its
    // own. Blocked storage costs the drafts and nothing else.
    var where = '';
    try { where = str(window.location && window.location.pathname); } catch (e) { where = ''; }
    var KEY = 'report-page:v1:' + (where || FILE || JSON.stringify([title, date]));
    var store = null;
    try {
      store = window.localStorage;
      store.setItem(KEY + ':probe', '1');
      store.removeItem(KEY + ':probe');
    } catch (e) { store = null; }
    if (!store) $('storage-note').hidden = false;
    function drafts() {
      if (!store) return {};
      try {
        var o = JSON.parse(store.getItem(KEY) || '{}');
        return isObj(o) && isObj(o.answers) ? o.answers : {};
      } catch (e) { return {}; }
    }
    function save() {
      if (!store) return;
      var answers = Object.create(null);
      items.forEach(function (it) {
        var c = chosen(it), notes = str(it.notes.value);
        if (c || notes) answers[it.key] = { choice: c ? c.value : '', notes: notes };
      });
      try { store.setItem(KEY, JSON.stringify({ answers: answers })); } catch (e) { /* full or blocked */ }
    }

    function chosen(it) {
      for (var j = 0; j < it.radios.length; j++) if (it.radios[j].checked) return it.opts[j];
      return null;
    }
    function notesOf(it) { return it.notes ? str(it.notes.value).trim() : ''; }
    function refresh(it) {
      var c = chosen(it), noted = notesOf(it) !== '';
      it.status.textContent = c ? 'Answered' : noted ? 'Notes only' : 'Not answered';
      it.status.setAttribute('data-kind', c ? 'done' : noted ? 'notes' : 'none');
      it.card.setAttribute('data-answered', c ? '1' : '0');
      it.labels.forEach(function (lab, j) { lab.className = it.radios[j].checked ? 'opt on' : 'opt'; });
      countEl.textContent = items.filter(chosen).length + ' of ' + items.length;
    }

    function card(it) {
      var d = it.d, n = it.n;
      var art = el('article', 'dec');
      it.card = art;
      var head = el('div', 'dec-head');
      head.appendChild(el('span', 'dnum', it.number));
      head.appendChild(el('h3', null, it.question));
      it.status = el('span', 'status', 'Not answered');
      it.status.setAttribute('data-kind', 'none');
      head.appendChild(it.status);
      art.appendChild(head);
      if (str(d.why).trim()) art.appendChild(el('p', 'why', str(d.why).trim()));
      var lr = linksRow(d.links);
      if (lr) art.appendChild(lr);

      var fs = el('fieldset', 'opts');
      fs.appendChild(el('legend', 'sr', 'Decision ' + it.number + ': ' + it.question));
      var rec = str(d.recommended);
      it.opts.forEach(function (o, j) {
        var rid = 'd' + n + '-o' + j;
        var lab = el('label', 'opt');
        lab.htmlFor = rid;
        var r = el('input');
        r.type = 'radio';
        r.id = rid;
        r.name = 'd' + n;
        r.value = String(j);
        r.addEventListener('change', function () { refresh(it); save(); });
        lab.appendChild(r);
        var span = el('span');
        span.appendChild(el('b', null, o.label));
        if (rec && o.value === rec) span.appendChild(el('em', 'rec', 'Recommended'));
        if (o.detail) span.appendChild(el('small', null, o.detail));
        lab.appendChild(span);
        fs.appendChild(lab);
        it.radios.push(r);
        it.labels.push(lab);
      });
      if (!it.opts.length) fs.appendChild(el('p', 'why', 'No options were given; answer in the notes.'));
      art.appendChild(fs);

      var ctx = [];
      var c = d.context;
      (Array.isArray(c) ? c : [c]).forEach(function (p) {
        if (typeof p === 'string' && p.trim()) ctx.push(el('p', null, p.trim()));
      });
      function fact(name, value) {
        var p = el('p');
        p.appendChild(el('b', null, name + ': '));
        p.appendChild(doc.createTextNode(value));
        ctx.push(p);
      }
      if (str(d.premises).trim()) fact('Premises', str(d.premises).trim());
      if (typeof d.reversible === 'boolean') fact('Reversible', d.reversible ? 'yes' : 'no, this one is one-way');
      if (str(d.blocks).trim()) fact('Blocks', str(d.blocks).trim());
      if (ctx.length) {
        var det = el('details', 'ctx');
        det.appendChild(el('summary', null, 'Context'));
        var body = el('div', 'body');
        ctx.forEach(function (p) { body.appendChild(p); });
        det.appendChild(body);
        art.appendChild(det);
      }

      var nid = 'd' + n + '-notes';
      var nl = el('label', 'notes-l', 'Notes (optional)');
      nl.htmlFor = nid;
      art.appendChild(nl);
      var ta = el('textarea');
      ta.id = nid;
      ta.rows = 2;
      ta.placeholder = 'Anything to add, change or drop';
      ta.addEventListener('input', function () { refresh(it); save(); });
      art.appendChild(ta);
      it.notes = ta;
      return art;
    }

    var saved = drafts();
    items.forEach(function (it) {
      app.appendChild(card(it));
      var v = Object.prototype.hasOwnProperty.call(saved, it.key) ? saved[it.key] : null;
      if (isObj(v)) {
        for (var j = 0; j < it.opts.length; j++) {
          if (str(v.choice) !== '' && it.opts[j].value === v.choice) { it.radios[j].checked = true; break; }
        }
        if (typeof v.notes === 'string') it.notes.value = v.notes;
      }
    });
    items.forEach(refresh);

    // The calls the run decided without the user, after the cards that need them.
    var decided = (Array.isArray(data.decided) ? data.decided : []).map(function (it) { return item(it); }).filter(Boolean);
    if (decided.length) {
      var sec = el('section', 'sec');
      sec.appendChild(el('h2', null, 'Decided this run'));
      var ul = el('ul', 'items');
      decided.forEach(function (li) { ul.appendChild(li); });
      sec.appendChild(ul);
      app.appendChild(sec);
    }

    // The shape /decide reads: a header naming the page, then a line per decision with its
    // number, [id], question, the arrow and the choice, and " | notes: " before any notes.
    function answersText() {
      var lines = ['Decision answers: ' + (field(title) || 'Decisions') + (field(date) ? ' (' + field(date) + ')' : '') +
        (PAGE_RE.test(FILE) ? ' [' + FILE + ']' : '')];
      items.forEach(function (it) {
        var c = chosen(it);
        var notes = field(notesOf(it).replace(/\s*[\r\n\u0085\u2028\u2029]+\s*/g, ' / '));
        lines.push((field(it.number) || String(it.n + 1)) + '. [' + (field(it.id) || 'd' + (it.n + 1)) + '] ' +
          (field(it.question) || '(no question given)') + ' \u2192 ' + (c ? field(c.label) || 'Option' : 'not answered') +
          (notes ? ' | notes: ' + notes : ''));
      });
      return lines.join('\n');
    }
    var resetTimer = null;
    copyBtn.addEventListener('click', function () {
      var text = answersText();
      box.value = text;
      function copied() {
        box.hidden = true;
        copyBtn.textContent = 'Copied';
        clearTimeout(resetTimer);
        resetTimer = setTimeout(function () { copyBtn.textContent = COPY_LABEL; }, 1800);
      }
      // file:// pages and older browsers can refuse the clipboard: show the text selected.
      function manual() {
        box.hidden = false;
        box.focus();
        box.select();
        copyBtn.textContent = 'Copy the selected text below';
      }
      try { navigator.clipboard.writeText(text).then(copied, manual); } catch (e) { manual(); }
    });
  }

  // --- A report -------------------------------------------------------------------------
  function pill(s) {
    var p = el('span', 'pill', s);
    p.setAttribute('data-status', STATUS[s] === 1 ? s : 'OTHER');
    return p;
  }
  function item(it) {
    var text = '', status = '', links = null;
    if (typeof it === 'string') text = it.trim();
    else if (isObj(it)) { text = str(it.text).trim(); status = line(it.status); links = it.links; }
    if (!text) return null;
    var li = el('li');
    var head = el('div', 'it');
    if (status) head.appendChild(pill(status));
    head.appendChild(el('span', 'tx', text));
    li.appendChild(head);
    var row = linksRow(links);
    if (row) li.appendChild(row);
    return li;
  }
  function report(data) {
    var app = $('app');
    var title = line(data.title) || 'Report';
    var date = line(data.date) || line(dataEl.getAttribute('data-date'));
    doc.title = title;
    $('title').textContent = title;
    $('eyebrow').textContent = NAME + (date ? ' \u00b7 ' + date : '');
    var sections = (Array.isArray(data.sections) ? data.sections : []).filter(isObj);
    var blocks = [['done', 'Done'], ['warnings', 'Warnings'], ['open', 'Open']];

    var counts = {};
    function count(it) {
      var s = isObj(it) ? line(it.status) : '';
      if (STATUS[s] === 1) counts[s] = (counts[s] || 0) + 1;
    }
    sections.forEach(function (s) { (Array.isArray(s.items) ? s.items : []).forEach(count); });
    blocks.forEach(function (b) { (Array.isArray(data[b[0]]) ? data[b[0]] : []).forEach(count); });

    var tl = el('section', 'tldr');
    tl.appendChild(el('h2', null, 'TL;DR'));
    var sum = data.summary;
    if (Array.isArray(sum)) {
      var ul = el('ul');
      sum.forEach(function (s) { if (str(s).trim()) ul.appendChild(el('li', null, str(s).trim())); });
      tl.appendChild(ul);
    } else if (str(sum).trim()) {
      tl.appendChild(el('p', null, str(sum).trim()));
    }
    var tally = el('p', 'tally');
    ['PASS', 'NEEDS-FIX', 'REFUTED', 'UNVERIFIED'].forEach(function (s) {
      if (!counts[s]) return;
      var p = pill(s);
      p.textContent = counts[s] + ' ' + s;
      tally.appendChild(p);
    });
    if (tally.children.length) tl.appendChild(tally);
    app.appendChild(tl);

    sections.forEach(function (s, i) {
      var sec = el('section', 'sec');
      sec.appendChild(el('h2', null, line(s.heading) || 'Section ' + (i + 1)));
      var list = el('ul', 'items');
      (Array.isArray(s.items) ? s.items : []).forEach(function (it) {
        var li = item(it);
        if (li) list.appendChild(li);
      });
      sec.appendChild(list);
      app.appendChild(sec);
    });

    // Done, Warnings and Open, each numbered from 1 so an item can be cited as "Open 2".
    var wrap = el('section', 'blocks');
    blocks.forEach(function (b) {
      var lis = (Array.isArray(data[b[0]]) ? data[b[0]] : []).map(function (it) { return item(it); }).filter(Boolean);
      if (!lis.length) return;
      var div = el('div', 'blk');
      div.setAttribute('data-block', b[0]);
      div.appendChild(el('h2', null, b[1]));
      var ol = el('ol');
      lis.forEach(function (li) { ol.appendChild(li); });
      div.appendChild(ol);
      wrap.appendChild(div);
    });
    if (wrap.children.length) app.appendChild(wrap);
  }

  navbar();
  var data;
  try { data = JSON.parse(str(dataEl.textContent).trim()); } catch (e) {
    fail('This page\u2019s data could not be read (' + e.message + '). Fix its JSON and run report-page.sh again.');
    return;
  }
  if (!isObj(data)) {
    fail('This page\u2019s data could not be read: it is not a JSON object. Fix its JSON and run report-page.sh again.');
    return;
  }
  if (KIND === 'report') report(data); else decisions(data);
})();
JS
}

{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
  printf '<meta http-equiv="Content-Security-Policy" content="%s">\n' \
    "default-src 'none'; style-src 'nonce-$NONCE'; script-src 'nonce-$NONCE'; base-uri 'none'; form-action 'none'"
  printf '%s\n' "$MARKER"
  printf '<meta name="referrer" content="no-referrer">\n'
  printf '<meta name="color-scheme" content="light dark">\n'
} > "$WORK/pre"
emit_css > "$WORK/css"
emit_body decisions > "$WORK/body-decisions"
emit_body report > "$WORK/body-report"
emit_js > "$WORK/js"

# render <list> <dir> — write each page <list> marks "render" to <dir>/<stem>.html. One awk
# for all of them: a process per page made a folder of a hundred pages take seconds per run.
# Each "<" in the data goes out as \u003c a piece at a time, so the time stays linear however
# many the data holds, and close() is checked, so a write that fails, on a full disk say,
# fails the run.
render() {
  W="$WORK" DIR="$DIR" NONCE="$NONCE" ROOTP="$ROOT_PREFIX" OUTDIR="$2" LC_ALL=C awk '
    function slurp(f,    s, l) { s = ""; while ((getline l < f) > 0) s = s l "\n"; close(f); return s }
    # put(s, out): s and a newline, with every "<" as \u003c, so nothing in the data can close
    # its script element.
    function put(s, out,    n, p, i) {
      n = split(s, p, "<")
      printf("%s", p[1]) > out
      for (i = 2; i <= n; i++) printf("\\u003c%s", p[i]) > out
      printf("\n") > out
    }
    BEGIN {
      FS = "\t"; w = ENVIRON["W"]; dir = ENVIRON["DIR"]; nonce = ENVIRON["NONCE"]; od = ENVIRON["OUTDIR"]
      pre = slurp(w "/pre"); css = slurp(w "/css"); js = slurp(w "/js")
      body["decisions"] = slurp(w "/body-decisions"); body["report"] = slurp(w "/body-report")
      # Every page carries the whole index: escape it once, into a file a piece at a time,
      # then read that back whole, RS being a byte clean() never leaves in the index.
      nf = w "/nav-escaped"
      while ((getline l < (w "/index.json")) > 0) put(l, nf)
      close(w "/index.json"); close(nf)
      nav = ""; RS = "\001"
      if ((getline nav < nf) <= 0) nav = ""
      close(nf); RS = "\n"
    }
    $3 != "render" { next }
    {
      stem = $1; kind = $2; out = od "/" stem ".html"
      printf("%s<title>%s</title>\n<style nonce=\"%s\">\n%s</style>\n</head>\n<body>\n%s", pre, $4, nonce, css, body[kind]) > out
      printf("<script type=\"application/json\" id=\"page-data\" data-kind=\"%s\" data-file=\"%s.html\" data-date=\"%s\" data-root=\"%s\">\n", \
        kind, stem, substr(stem, 1, 10), ENVIRON["ROOTP"]) > out
      f = dir "/" stem ".json"
      while ((getline l < f) > 0) put(l, out)
      close(f)
      printf("</script>\n<script type=\"application/json\" id=\"nav-data\">\n") > out
      printf("%s", nav) > out
      printf("</script>\n<script nonce=\"%s\">\n%s</script>\n</body>\n</html>\n", nonce, js) > out
      if (close(out) != 0) bad = 1
    }
    END { exit bad }' "$1"
}

# Pages are written into a private folder inside this one, then renamed into place: a write
# that fails leaves the old page whole, and a link put where a page was is replaced, never
# followed. The new page goes first, since it is the one asked for; then the index; then
# every earlier page, so each bar lists the new one.
LC_ALL=C grep -q "^$STEM$TAB[a-z]*${TAB}render$TAB" "$WORK/list" \
  || die "the page's JSON did not pass the shape check in $DIR"
STAGE="$(mktemp -d "$DIR/.report-page.XXXXXX" 2>/dev/null)" || die "cannot write in $DIR"
LC_ALL=C awk -F "$TAB" -v s="$STEM" '$1 == s' "$WORK/list" > "$WORK/list-new"
LC_ALL=C awk -F "$TAB" -v s="$STEM" '$1 != s && $3 == "render"' "$WORK/list" > "$WORK/list-earlier"
if ! render "$WORK/list-new" "$STAGE" || ! mv -f "$STAGE/$STEM.html" "$DIR/$STEM.html" 2>/dev/null; then
  die "cannot write the page in $DIR"
fi
NEW_JSON=""
put "$WORK/index.json" index.json || echo "$ME: could not update $DIR/index.json" >&2
if [ -s "$WORK/list-earlier" ]; then
  if ! render "$WORK/list-earlier" "$STAGE" \
    || ! (cd "$STAGE" && set -- *.html && [ -f "$1" ] && mv -f -- "$@" "$DIR/") 2>/dev/null; then
    echo "$ME: could not refresh the navigation bar of every earlier page in $DIR" >&2
  fi
fi
rm -rf "$STAGE"
STAGE=""
STALE="$(LC_ALL=C awk -F "$TAB" '$3 == "stale" { printf " %s.html", $1 }' "$WORK/list")" || STALE=""
SKIP="$(LC_ALL=C awk -F "$TAB" '$3 == "skip" { printf " %s.html", $1 }' "$WORK/list")" || SKIP=""
TRACKED="$(LC_ALL=C awk -F "$TAB" '$3 == "tracked" { printf " %s", $1 }' "$WORK/list")" || TRACKED=""
PAGES="$(LC_ALL=C grep -c '"sequence"' "$WORK/index.json" 2>/dev/null)" || PAGES=0
[ -z "$FOREIGN$SKIP" ] || echo "$ME: left alone, since this script did not write them:$FOREIGN$SKIP" >&2
[ -z "$TRACKED" ] || echo "$ME: left alone, since git tracks them:$TRACKED" >&2
[ -z "$STALE" ] || echo "$ME: kept in the bar but not refreshed, since their JSON is missing or not a page's:$STALE" >&2
[ "$PAGES" -le 500 ] \
  || echo "$ME: $DIR holds $PAGES pages and every run rewrites them all; delete old pages, with their .json, to keep runs quick" >&2
# The folder's own .gitignore keeps the pages out of git, unless one was there already that
# says otherwise and the project's does not cover them either: say so.
if [ -n "$IN_GIT" ] && [ "$DIR" = "$ROOT/$CONFIG_NAME/reports" ]; then
  rc=0
  (cd "$ROOT" && git check-ignore -q -- "$CONFIG_NAME/reports/$STEM.html") 2>/dev/null || rc=$?
  [ "$rc" -ne 1 ] \
    || echo "$ME: git does not ignore $DIR/$STEM.html, and a page can hold private decisions: add $CONFIG_NAME/reports/ to the project's .gitignore" >&2
fi

case "$(uname -s 2>/dev/null || true)" in
  Darwin) OPENER="open" ;;
  *) OPENER="xdg-open" ;;
esac
printf '%s\n' "$DIR/$STEM.html"
printf 'To open it: %s %q\n' "$OPENER" "$DIR/$STEM.html" >&2
