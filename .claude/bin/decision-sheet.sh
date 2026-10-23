#!/usr/bin/env bash
# Render a decisions file as a local HTML decision sheet: one card per decision, with its
# options as buttons, a collapsible context and a notes box, and a "Copy answers" button
# whose text the user pastes back into the terminal. /decide writes one by default.
#
# Usage: bash .claude/bin/decision-sheet.sh <decisions.json> [-o <out.html>]
#
# Prints the sheet's absolute path on stdout and how to open it on stderr; it never opens
# it. Without -o the sheet goes to $(git rev-parse --git-common-dir)/decisions/sheets/
# <date>-<slug>.html, beside the decision record, private and shared by every worktree of
# the clone; outside a repo, or where that directory can't be written (the High tier), to
# ${TMPDIR:-/tmp}/decision-sheets/. DECISIONS_DATE=YYYY-MM-DD overrides the date.
#
# The JSON is embedded verbatim, every "<" written as \u003c so no string can close the
# script element, and the page renders every string with textContent, since the text can
# come from PRs, issues or agents. The page makes no network request at all (system fonts,
# no links, and a CSP of default-src 'none'), because a sheet can hold private decisions.
#
# The input checks are strict because the firewall allows this script without a prompt:
# it must not become a way to copy any file somewhere readable. It reads only a regular
# file under 1 MiB shaped like a decisions file (a JSON object with "title" and
# "decisions" keys), which a keypair, a JSON array, never is. -o takes only an .html path
# and never replaces a file this script did not write.
#
# python3, else node, checks this shape and stops at the first problem; with neither, the
# page shows the parse error instead.
#   {"title": str, "date": str?, "intro": str?, "decisions": [{"id": str,
#    "number": int|str, "question": str, "why": str?, "recommended": <option value>?,
#    "options": [{"value": str, "label": str, "detail": str?}], "context": [str]?,
#    "premises": str?, "reversible": bool?, "blocks": str?}]}
#
# Exit: 0 written; 1 the input or the output path was refused (why, on stderr); 2 usage.
set -euo pipefail
umask 077

ME="decision-sheet"
MAX_BYTES=1048576
# Marks a file as this script's output: -o replaces only a file that carries it.
MARKER='<meta name="generator" content="solana-ai-kit decision-sheet">'

usage() {
  echo "Usage: bash .claude/bin/decision-sheet.sh <decisions.json> [-o <out.html>]"
  echo "Writes a local HTML decision sheet and prints its path. The JSON shape is in this script's header."
}
die() {
  echo "$ME: $*" >&2
  exit 1
}

IN=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "$ME: -o needs a path" >&2; usage >&2; exit 2; }
      OUT="$2"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    -?*) echo "$ME: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$IN" ] || { echo "$ME: one decisions file at a time" >&2; usage >&2; exit 2; }
      IN="$1"
      shift
      ;;
  esac
done
if [ $# -gt 0 ]; then
  [ -z "$IN" ] && [ $# -eq 1 ] || { echo "$ME: one decisions file at a time" >&2; usage >&2; exit 2; }
  IN="$1"
fi
[ -n "$IN" ] || { usage >&2; exit 2; }
# Keep a path that starts with "-" from reading as an option to python3 or node.
case "$IN" in -*) IN="./$IN" ;; esac

# --- The input ------------------------------------------------------------------------
[ -e "$IN" ] || die "no such file: $IN"
[ -f "$IN" ] || die "not a regular file: $IN"
[ -r "$IN" ] || die "cannot read: $IN"
BYTES="$({ wc -c < "$IN"; } 2>/dev/null | tr -d ' ')" || BYTES=""
[ -n "$BYTES" ] || die "cannot read: $IN"
[ "$BYTES" -gt 0 ] || die "empty file: $IN"
[ "$BYTES" -le "$MAX_BYTES" ] || die "$IN is $BYTES bytes; a decisions file is at most $MAX_BYTES"

# The shape floor, which holds with no JSON parser on the machine: the first non-blank
# bytes are "{" (7b), after an optional UTF-8 byte-order mark (efbbbf), and both keys are
# present.
NOT_SHEET="does not look like a decisions file: expected a JSON object with \"title\" and \"decisions\""
HEAD_HEX="$({ LC_ALL=C tr -d ' \t\r\n' < "$IN" | head -c 8 | od -An -tx1 | tr -d ' \n'; } 2>/dev/null)" || true
case "$HEAD_HEX" in
  7b* | efbbbf7b*) ;;
  *) die "$IN $NOT_SHEET" ;;
esac
LC_ALL=C grep -Eq '"title"[[:space:]]*:' "$IN" && LC_ALL=C grep -Eq '"decisions"[[:space:]]*:' "$IN" \
  || die "$IN $NOT_SHEET"

# Validators print one line, "OK <title>" or "ERR <reason>", and exit 0 or 3. Anything
# else means the interpreter itself could not run (a macOS python3 stub without the
# command line tools, say), and the next one is tried.
py_validator() {
  cat <<'PY'
import json, sys

def out(kind, text):
    # As bytes, so a non-ASCII title prints under any locale.
    sys.stdout.buffer.write((kind + " " + " ".join(str(text).split()) + "\n").encode("utf-8"))
    sys.stdout.flush()
    sys.exit(0 if kind == "OK" else 3)

def show(v):
    s = json.dumps(v, ensure_ascii=False)
    return s if len(s) <= 60 else s[:57] + "..."

def no_constant(name):
    raise ValueError("%s is not JSON" % name)

def text(v):
    return isinstance(v, str) and v.strip() != ""

def given(o, k):
    return o.get(k) is not None

try:
    with open(sys.argv[1], encoding="utf-8-sig") as f:
        data = json.load(f, parse_constant=no_constant)
except UnicodeDecodeError:
    out("ERR", "not UTF-8 text")
except ValueError as e:
    out("ERR", "not valid JSON: %s" % e)
except OSError as e:
    out("ERR", "cannot read: %s" % e.strerror)

if not isinstance(data, dict):
    out("ERR", "the top level must be an object")
if not text(data.get("title")):
    out("ERR", '"title" must be a non-empty string')
for k in ("date", "intro"):
    if given(data, k) and not isinstance(data[k], str):
        out("ERR", '"%s" must be a string' % k)
decisions = data.get("decisions")
if not isinstance(decisions, list) or not decisions:
    out("ERR", '"decisions" must be a non-empty array')
ids = set()
for i, d in enumerate(decisions):
    at = "decisions[%d]" % i
    if not isinstance(d, dict):
        out("ERR", at + " must be an object")
    if not text(d.get("id")):
        out("ERR", at + ".id must be a non-empty string")
    if d["id"] in ids:
        out("ERR", "%s.id %s is used twice" % (at, show(d["id"])))
    ids.add(d["id"])
    n = d.get("number")
    if isinstance(n, bool) or not (isinstance(n, int) or text(n)):
        out("ERR", at + ".number must be an integer or a non-empty string")
    if not text(d.get("question")):
        out("ERR", at + ".question must be a non-empty string")
    for k in ("why", "recommended", "premises", "blocks"):
        if given(d, k) and not isinstance(d[k], str):
            out("ERR", "%s.%s must be a string" % (at, k))
    if given(d, "reversible") and not isinstance(d["reversible"], bool):
        out("ERR", at + ".reversible must be true or false")
    if given(d, "context") and not (isinstance(d["context"], list) and all(isinstance(c, str) for c in d["context"])):
        out("ERR", at + ".context must be an array of strings")
    options = d.get("options")
    if not isinstance(options, list) or not options:
        out("ERR", at + ".options must be a non-empty array")
    values = set()
    for j, o in enumerate(options):
        oat = "%s.options[%d]" % (at, j)
        if not isinstance(o, dict):
            out("ERR", oat + " must be an object")
        for k in ("value", "label"):
            if not text(o.get(k)):
                out("ERR", "%s.%s must be a non-empty string" % (oat, k))
        if given(o, "detail") and not isinstance(o["detail"], str):
            out("ERR", oat + ".detail must be a string")
        if o["value"] in values:
            out("ERR", "%s.value %s is used twice" % (oat, show(o["value"])))
        values.add(o["value"])
    if text(d.get("recommended")) and d["recommended"] not in values:
        out("ERR", "%s.recommended %s is not one of its option values" % (at, show(d["recommended"])))
out("OK", data["title"])
PY
}

node_validator() {
  cat <<'JS'
const fs = require('fs');
function check(file) {
  let raw, data;
  try { raw = fs.readFileSync(file); } catch (e) { return ['ERR', 'cannot read: ' + e.code]; }
  if (typeof TextDecoder === 'function') {
    try { raw = new TextDecoder('utf-8', { fatal: true }).decode(raw); } catch (e) { return ['ERR', 'not UTF-8 text']; }
  } else {
    raw = raw.toString('utf8');
  }
  try { data = JSON.parse(raw.replace(/^\uFEFF/, '')); } catch (e) { return ['ERR', 'not valid JSON: ' + e.message]; }
  const text = (v) => typeof v === 'string' && v.trim() !== '';
  const given = (o, k) => o[k] !== undefined && o[k] !== null;
  const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
  const show = (v) => { const s = JSON.stringify(v); return s.length <= 60 ? s : s.slice(0, 57) + '...'; };
  if (!isObj(data)) return ['ERR', 'the top level must be an object'];
  if (!text(data.title)) return ['ERR', '"title" must be a non-empty string'];
  for (const k of ['date', 'intro']) {
    if (given(data, k) && typeof data[k] !== 'string') return ['ERR', '"' + k + '" must be a string'];
  }
  const ds = data.decisions;
  if (!Array.isArray(ds) || !ds.length) return ['ERR', '"decisions" must be a non-empty array'];
  const ids = new Set();
  for (let i = 0; i < ds.length; i++) {
    const d = ds[i], at = 'decisions[' + i + ']';
    if (!isObj(d)) return ['ERR', at + ' must be an object'];
    if (!text(d.id)) return ['ERR', at + '.id must be a non-empty string'];
    if (ids.has(d.id)) return ['ERR', at + '.id ' + show(d.id) + ' is used twice'];
    ids.add(d.id);
    if (!(Number.isInteger(d.number) || text(d.number))) return ['ERR', at + '.number must be an integer or a non-empty string'];
    if (!text(d.question)) return ['ERR', at + '.question must be a non-empty string'];
    for (const k of ['why', 'recommended', 'premises', 'blocks']) {
      if (given(d, k) && typeof d[k] !== 'string') return ['ERR', at + '.' + k + ' must be a string'];
    }
    if (given(d, 'reversible') && typeof d.reversible !== 'boolean') return ['ERR', at + '.reversible must be true or false'];
    if (given(d, 'context') && !(Array.isArray(d.context) && d.context.every((c) => typeof c === 'string'))) {
      return ['ERR', at + '.context must be an array of strings'];
    }
    const os = d.options;
    if (!Array.isArray(os) || !os.length) return ['ERR', at + '.options must be a non-empty array'];
    const values = new Set();
    for (let j = 0; j < os.length; j++) {
      const o = os[j], oat = at + '.options[' + j + ']';
      if (!isObj(o)) return ['ERR', oat + ' must be an object'];
      for (const k of ['value', 'label']) {
        if (!text(o[k])) return ['ERR', oat + '.' + k + ' must be a non-empty string'];
      }
      if (given(o, 'detail') && typeof o.detail !== 'string') return ['ERR', oat + '.detail must be a string'];
      if (values.has(o.value)) return ['ERR', oat + '.value ' + show(o.value) + ' is used twice'];
      values.add(o.value);
    }
    if (text(d.recommended) && !values.has(d.recommended)) {
      return ['ERR', at + '.recommended ' + show(d.recommended) + ' is not one of its option values'];
    }
  }
  return ['OK', data.title];
}
const r = check(process.argv[1]);
process.stdout.write(r[0] + ' ' + String(r[1]).split(/\s+/).filter(Boolean).join(' ') + '\n');
process.exitCode = r[0] === 'OK' ? 0 : 3;
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
  try_validator python3 python3 -I -c "$(py_validator)" "$IN" || true
fi
if [ -z "$VALIDATED" ] && command -v node >/dev/null 2>&1; then
  try_validator node node -e "$(node_validator)" "$IN" || true
fi
[ -n "$VALIDATED" ] \
  || echo "$ME: no python3 or node to validate $IN; the page will show any problem in it" >&2

# guess_title — the top-level "title" when no validator ran. It only names the file and
# the tab before the script runs, so a best effort is enough: escapes are dropped.
guess_title() {
  { LC_ALL=C tr '\r\n\t' '   ' < "$IN" | LC_ALL=C awk '
    {
      if (!match($0, /"title"[ ]*:[ ]*"/)) exit
      s = substr($0, RSTART + RLENGTH, 2000); t = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") { i += (substr(s, i + 1, 1) == "u") ? 5 : 1; continue }
        if (c == "\"") break
        t = t c
      }
      print t
      exit
    }'; } 2>/dev/null || true
}
TITLE="$VTITLE"
[ -n "$TITLE" ] || TITLE="$(guess_title)"

DATE="${DECISIONS_DATE:-$(date +%Y-%m-%d)}"
case "$DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) die "DECISIONS_DATE must be YYYY-MM-DD, got: $DATE" ;;
esac
SLUG="$(printf '%s' "$TITLE" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9' '-' \
  | sed -e 's/--*/-/g' -e 's/^-//' | cut -c1-60 | sed -e 's/-$//')" || SLUG=""
[ -n "$SLUG" ] || SLUG="decisions"
NAME="$DATE-$SLUG.html"
TITLE_HTML="$(printf '%s' "${TITLE:-Decision sheet}" | LC_ALL=C sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
NONCE="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || NONCE=""
case "$NONCE" in '' | *[!0-9a-f]*) NONCE="$(printf '%x%x%x' "$$" "$(date +%s)" "$RANDOM")" ;; esac

# --- The page -------------------------------------------------------------------------
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
.wrap { max-width: 880px; margin: 0 auto; padding: 40px 0 24px; display: grid; gap: 28px; }
header { display: grid; gap: 12px; }
.eyebrow { font: 600 12px/1.2 var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
h1 { font: 800 clamp(30px, 5.5vw, 46px)/1.05 var(--display); margin: 0; letter-spacing: -.02em; text-wrap: balance; overflow-wrap: anywhere; }
h3 { font: 600 17px/1.35 var(--body); margin: 0; overflow-wrap: anywhere; }
p { margin: 0; max-width: 72ch; }
.lede { font-size: 18px; color: var(--muted); white-space: pre-line; }
.how { font-size: 15px; color: var(--muted); }
.warn { font-size: 14px; color: var(--amber); border-left: 3px solid var(--amber); padding-left: 10px; }
.err { background: var(--red-soft); color: var(--red); border: 1px solid var(--red); border-radius: 10px; padding: 14px 16px; overflow-wrap: anywhere; }
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
footer { font-size: 13px; color: var(--muted); border-top: 1px solid var(--line); padding-top: 14px; }
:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }
@media (max-width: 540px) {
  .dec-head { grid-template-columns: auto 1fr; }
  .dec-head .status { grid-column: 2; justify-self: start; }
}
CSS
}

emit_body() {
  cat <<'HTML'
<div class="wrap">
<header>
  <div class="eyebrow" id="eyebrow">Decision sheet</div>
  <h1 id="title">Decisions</h1>
  <p class="lede" id="intro" hidden></p>
  <p class="how">Pick an option for each decision. Open Context for what it rests on, and add a note to change or add anything. Nothing on this page goes online, and your choices stay in this browser until you copy them. When you&rsquo;re done, press Copy answers and paste the text into the terminal.</p>
  <p class="warn" id="storage-note" hidden>This browser won&rsquo;t let the page keep drafts, so reloading it loses your choices. Copy them before you close it.</p>
</header>
<noscript><p class="err">This sheet needs JavaScript to show its decisions.</p></noscript>
<p class="err" id="error" role="alert" hidden></p>
<main class="decisions" id="app"></main>
<div class="bar" id="bar">
  <p><b id="count" aria-live="polite">0 of 0</b> answered &middot; Copy, then paste this in the terminal.</p>
  <button type="button" id="copy">Copy answers</button>
</div>
<textarea id="copybox" rows="8" hidden readonly aria-label="Your answers as text"></textarea>
<footer>Written by solana-ai-kit&rsquo;s decision-sheet.sh. This page makes no network requests, and its drafts stay in this browser.</footer>
</div>
HTML
}

emit_js() {
  cat <<'JS'
(function () {
  'use strict';
  var doc = document;
  function $(id) { return doc.getElementById(id); }
  var app = $('app'), countEl = $('count'), copyBtn = $('copy'), box = $('copybox'), dataEl = $('sheet-data');
  var COPY_LABEL = 'Copy answers';

  function str(v) { return typeof v === 'string' ? v : (v === null || v === undefined) ? '' : String(v); }
  function line(v) { return str(v).replace(/\s+/g, ' ').trim(); }
  function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
  // Every string from the data goes in through textContent or a text node, never as markup.
  function el(tag, cls, text) {
    var e = doc.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  }
  function fail(message) {
    var err = $('error');
    err.textContent = message;
    err.hidden = false;
    copyBtn.disabled = true;
    countEl.textContent = '0 of 0';
    doc.title = 'Decision sheet: unreadable';
  }

  var data;
  try { data = JSON.parse(str(dataEl.textContent).trim()); } catch (e) {
    fail('This sheet\u2019s decisions could not be read (' + e.message + '). Fix the decisions file and run decision-sheet.sh again.');
    return;
  }
  var items = [], seen = Object.create(null);
  (isObj(data) && Array.isArray(data.decisions) ? data.decisions : []).forEach(function (d, i) {
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
    fail('This sheet holds no decisions: its data needs a non-empty "decisions" array. Fix the decisions file and run decision-sheet.sh again.');
    return;
  }

  var title = line(data.title) || 'Decisions';
  var date = line(data.date) || line(dataEl.getAttribute('data-date'));
  doc.title = title;
  $('title').textContent = title;
  $('eyebrow').textContent = 'Decision sheet' + (date ? ' \u00b7 ' + date : '');
  if (str(data.intro).trim()) {
    var intro = $('intro');
    intro.textContent = str(data.intro).trim();
    intro.hidden = false;
  }

  // Drafts live in this browser only, keyed on the sheet's title and date. Blocked
  // storage costs the drafts and nothing else.
  var KEY = 'decision-sheet:v1:' + JSON.stringify([title, date]);
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

  // One line per decision, in the shape /decide records verbatim.
  function answersText() {
    var lines = ['Decision answers: ' + title + (date ? ' (' + date + ')' : '')];
    items.forEach(function (it) {
      var c = chosen(it);
      var notes = notesOf(it).replace(/\s*[\r\n]+\s*/g, ' / ');
      lines.push(it.number + '. [' + it.id + '] ' + it.question + ' \u2192 ' + (c ? c.label : 'not answered') +
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
})();
JS
}

render() {
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
  printf '<meta http-equiv="Content-Security-Policy" content="%s">\n' \
    "default-src 'none'; style-src 'nonce-$NONCE'; script-src 'nonce-$NONCE'; base-uri 'none'; form-action 'none'"
  printf '%s\n' "$MARKER"
  printf '<meta name="color-scheme" content="light dark">\n'
  printf '<title>%s</title>\n' "$TITLE_HTML"
  printf '<style nonce="%s">\n' "$NONCE"
  emit_css
  printf '</style>\n</head>\n<body>\n'
  emit_body
  printf '<script type="application/json" id="sheet-data" data-date="%s">\n' "$DATE"
  LC_ALL=C sed 's/</\\u003c/g' "$IN" || return 1
  printf '\n</script>\n<script nonce="%s">\n' "$NONCE"
  emit_js
  printf '</script>\n</body>\n</html>\n' || return 1
}

# ours <path> — the file is an earlier sheet, safe to replace.
ours() { [ -f "$1" ] && head -c 2048 "$1" 2>/dev/null | LC_ALL=C grep -F "$MARKER" >/dev/null; }

# write_sheet <dir> <name> — render through a temp file in <dir>, so a failed write leaves
# nothing half-written and a symlink at the target is replaced, never followed. Returns 1
# when <dir> can't take the file, 2 when the target is a file this script did not write.
write_sheet() {
  local dir="$1" name="$2" tmp
  if [ -e "$dir/$name" ] || [ -L "$dir/$name" ]; then
    ours "$dir/$name" || { echo "$ME: refusing to replace $dir/$name, which this script did not write" >&2; return 2; }
  fi
  tmp="$(mktemp "$dir/.decision-sheet.XXXXXX" 2>/dev/null)" || return 1
  if ! render > "$tmp" || ! mv -f "$tmp" "$dir/$name" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
}

# --- Where it goes --------------------------------------------------------------------
RESULT=""
if [ -n "$OUT" ]; then
  case "$(printf '%s' "$OUT" | LC_ALL=C tr 'A-Z' 'a-z')" in
    *.html | *.htm) ;;
    *) die "-o takes a path ending in .html: $OUT" ;;
  esac
  [ ! -d "$OUT" ] || die "-o names a directory: $OUT"
  case "$OUT" in
    */*) ODIR="${OUT%/*}"; ONAME="${OUT##*/}" ;;
    *) ODIR="."; ONAME="$OUT" ;;
  esac
  [ -n "$ODIR" ] || ODIR="/"
  mkdir -p -- "$ODIR" 2>/dev/null || die "cannot create $ODIR"
  ODIR="$(cd -- "$ODIR" && pwd -P)" || die "cannot enter the directory of $OUT"
  rc=0
  write_sheet "$ODIR" "$ONAME" || rc=$?
  [ "$rc" -ne 2 ] || exit 1
  [ "$rc" -eq 0 ] || die "cannot write $ODIR/$ONAME"
  RESULT="${ODIR%/}/$ONAME"
else
  GCD="$(git rev-parse --git-common-dir 2>/dev/null)" || GCD=""
  if [ -n "$GCD" ] && GCD="$(cd "$GCD" 2>/dev/null && pwd -P)" \
    && mkdir -p "$GCD/decisions/sheets" 2>/dev/null; then
    rc=0
    write_sheet "$GCD/decisions/sheets" "$NAME" || rc=$?
    [ "$rc" -ne 2 ] || exit 1
    [ "$rc" -ne 0 ] || RESULT="$GCD/decisions/sheets/$NAME"
  fi
  if [ -z "$RESULT" ]; then
    BASE="${TMPDIR:-/tmp}"
    BASE="${BASE%/}"
    DIR="$BASE/decision-sheets"
    mkdir -p "$DIR" 2>/dev/null || true
    # On a shared /tmp another user can create that name first: use a private one then.
    if ! { [ -d "$DIR" ] && [ ! -L "$DIR" ] && [ -O "$DIR" ]; }; then
      DIR="$(mktemp -d "$BASE/decision-sheets.XXXXXX" 2>/dev/null)" \
        || die "cannot create a directory for the sheet under $BASE"
    fi
    DIR="$(cd "$DIR" && pwd -P)" || die "cannot enter $DIR"
    rc=0
    write_sheet "$DIR" "$NAME" || rc=$?
    [ "$rc" -ne 2 ] || exit 1
    [ "$rc" -eq 0 ] || die "cannot write the sheet in $DIR"
    RESULT="$DIR/$NAME"
  fi
fi

case "$(uname -s 2>/dev/null || true)" in
  Darwin) OPENER="open" ;;
  *) OPENER="xdg-open" ;;
esac
printf '%s\n' "$RESULT"
printf 'To open it: %s %q\n' "$OPENER" "$RESULT" >&2
