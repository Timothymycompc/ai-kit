#!/usr/bin/env bash
set -euo pipefail

# .claude/bin/decision-sheet.sh turns a decisions file into the HTML sheet /decide hands
# the user. What has to hold, and why:
#   - the page makes no network request, since a sheet can hold private decisions;
#   - text from the data never becomes markup, since it can come from PRs, issues or agents;
#   - the input and output checks keep a script the firewall allows without a prompt from
#     copying an arbitrary file somewhere readable, or overwriting one;
#   - the copy text keeps its exact shape, since /decide records the pasted answers verbatim.
# The page's own behaviour runs under node against a small DOM stand-in, when node exists.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

SHEET="$REPO_ROOT/.claude/bin/decision-sheet.sh"
T="$(new_tmp)" || exit 1
trap 'rm -rf "$T"' EXIT

echo "[test_decision_sheet] /decide's local HTML decision sheet"
echo ""

# Hermetic git, a known date, and no repository above the temp dir.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CEILING_DIRECTORIES="$T"
export DECISIONS_DATE=2026-01-02
mkdir -p "$T/tmp" "$T/nogit"
export TMPDIR="$T/tmp"
TMP_REAL="$(cd "$T/tmp" && pwd -P)"
HAVE_NODE=false
command -v node >/dev/null 2>&1 && HAVE_NODE=true
HAVE_PY=false
command -v python3 >/dev/null 2>&1 && HAVE_PY=true
case "$(uname -s)" in Darwin) OPENER=open ;; *) OPENER=xdg-open ;; esac
# A JSON "<" escape, written with printf so nothing along the way decodes it.
ESC_LT="$(printf '\\u003c')"

# run <dir> <args...> — the script from <dir>: stdout in OUT_TXT, stderr in ERR_TXT, RC.
run() {
  local dir="$1"
  shift
  RC=0
  OUT_TXT="$(cd "$dir" && bash "$SHEET" "$@" 2>"$T/stderr")" || RC=$?
  ERR_TXT="$(cat "$T/stderr")"
}
# run_with_path <path> <dir> <args...> — the same, with only <path> on PATH.
run_with_path() {
  local path="$1" dir="$2"
  shift 2
  RC=0
  OUT_TXT="$(cd "$dir" && PATH="$path" "$BASH" "$SHEET" "$@" 2>"$T/stderr")" || RC=$?
  ERR_TXT="$(cat "$T/stderr")"
}
# succeeded <label> — the last run exited 0; its stderr is shown only when it did not.
succeeded() {
  TOTAL=$((TOTAL + 1))
  if [ "$RC" -eq 0 ]; then
    echo "  PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (exit $RC, stderr: $ERR_TXT)"
    FAIL=$((FAIL + 1))
  fi
}
# refused <label> <needle> — the last run exited 1 and said why.
refused() {
  TOTAL=$((TOTAL + 1))
  if [ "$RC" -eq 1 ] && printf '%s\n' "$ERR_TXT" | grep -qF "$2"; then
    echo "  PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (exit $RC, stderr: $ERR_TXT)"
    FAIL=$((FAIL + 1))
  fi
}
# mode_of <path> — the permission string ls prints, e.g. -rw-------.
mode_of() { ls -ld "$1" 2>/dev/null | cut -c1-10; }

cat > "$T/sample.json" <<'EOF'
{
  "title": "Sample sheet: \"quoted\" & ünïcödé",
  "intro": "Three calls to check the renderer.\nThe second line of the intro.",
  "decisions": [
    {
      "id": "ship-now",
      "number": 1,
      "question": "Ship the \"fast\" path now?",
      "why": "It's ready, and two users are waiting on it.",
      "recommended": "yes",
      "options": [
        {"value": "yes", "label": "Yes, ship it", "detail": "It goes out today."},
        {"value": "no", "label": "Not yet"}
      ],
      "context": ["Paragraph one.", "Paragraph two, with 'single' quotes."],
      "premises": "CI is green [verified]",
      "reversible": true,
      "blocks": "the release"
    },
    {
      "id": "xss",
      "number": "2",
      "question": "Is </script><img src=x onerror=alert(1)> rendered as text?",
      "options": [
        {"value": "a", "label": "<b>bold?</b>"},
        {"value": "b", "label": "Plain"}
      ]
    },
    {
      "id": "unicode",
      "number": 3,
      "question": "Ünïcödé — 日本語 ✓?",
      "options": [
        {"value": "si", "label": "Sí, “quoted” ✓"},
        {"value": "no", "label": "No"}
      ],
      "reversible": false
    }
  ]
}
EOF
cat > "$T/mini.json" <<'EOF'
{"title": "Default path check", "decisions": [
  {"id": "a", "number": 1, "question": "Go?", "options": [{"value": "y", "label": "Yes"}, {"value": "n", "label": "No"}]}
]}
EOF
# What Copy answers must produce after the choices the node harness makes below.
cat > "$T/expected.txt" <<'EOF'
Decision answers: Sample sheet: "quoted" & ünïcödé (2026-01-02)
1. [ship-now] Ship the "fast" path now? → Yes, ship it
2. [xss] Is </script><img src=x onerror=alert(1)> rendered as text? → not answered
3. [unicode] Ünïcödé — 日本語 ✓? → Sí, “quoted” ✓ | notes: line one / line two
EOF

# --- The script -----------------------------------------------------------------------
echo "[script]"
assert_file_exists "$SHEET" "decision-sheet.sh exists"
TOTAL=$((TOTAL + 1))
if [ -x "$SHEET" ]; then
  echo "  PASS: decision-sheet.sh is executable"
  PASS=$((PASS + 1))
else
  echo "  FAIL: decision-sheet.sh is not executable"
  FAIL=$((FAIL + 1))
fi
assert_cmd_success "bash -n '$SHEET'" "decision-sheet.sh parses (bash -n)"
assert_file_contains "$SHEET" "set -euo pipefail" "decision-sheet.sh runs in strict mode"
run "$T/nogit"
assert_eq "2" "$RC" "no input file is a usage error (exit 2)"
run "$T/nogit" "$T/mini.json" --open
assert_eq "2" "$RC" "an unknown option is a usage error (exit 2)"

# --- Rendering ------------------------------------------------------------------------
echo "[render]"
run "$T/nogit" "$T/sample.json" -o "$T/out/sample.html"
SAMPLE="$T/out/sample.html"
succeeded "renders the sample"
assert_eq "$(cd "$T/out" && pwd -P)/sample.html" "$OUT_TXT" "prints only the sheet's absolute path on stdout"
assert_contains "$ERR_TXT" "To open it: $OPENER $OUT_TXT" "says on stderr how to open it ($OPENER)"
assert_file_exists "$SAMPLE" "the sheet exists"
assert_eq "<!doctype html>" "$(head -1 "$SAMPLE")" "the sheet starts with a doctype"
assert_file_contains "$SAMPLE" '<meta charset="utf-8">' "the sheet declares its charset"
assert_file_contains "$SAMPLE" '<meta name="viewport" content="width=device-width, initial-scale=1">' \
  "the sheet has a viewport meta"
assert_file_contains "$SAMPLE" '<title>Sample sheet: "quoted" &amp; ünïcödé</title>' \
  "the title comes from the data, HTML-escaped"
assert_file_contains "$SAMPLE" "${ESC_LT}/script>${ESC_LT}img src=x onerror=alert(1)>" \
  "every < in the data is embedded as \\u003c"
assert_file_not_contains "$SAMPLE" "<img" "no string in the data reaches the page as a tag"
assert_eq "2" "$(grep -c '</script>' "$SAMPLE")" "the data cannot close its script element early (2 closing tags)"
assert_file_contains "$SAMPLE" "日本語" "unicode in the data is embedded verbatim"
assert_file_contains "$SAMPLE" "“quoted” ✓" "typographic quotes survive"
assert_file_contains "$SAMPLE" 'id="sheet-data" data-date="2026-01-02"' "the page carries DECISIONS_DATE as its fallback date"
assert_file_contains "$SAMPLE" "Copy, then paste this in the terminal." "the bar keeps its hint"
assert_file_contains "$SAMPLE" '<button type="button" id="copy">Copy answers</button>' "the bar has the Copy answers button"
assert_file_contains "$SAMPLE" '<textarea id="copybox" rows="8" hidden readonly' "the copy fallback box is read-only"
assert_eq "-rw-------" "$(mode_of "$SAMPLE")" "the sheet is readable by its owner only"

# The page without its data block: everything the template itself contributes.
awk '/^<script type="application\/json" id="sheet-data"/ {skip = 1} !skip {print} skip && /^<\/script>$/ {skip = 0}' \
  "$SAMPLE" > "$T/template.html"
awk '/^<script nonce="[0-9a-f]+">$/ {on = 1; next} on && /^<\/script>$/ {exit} on {print}' "$SAMPLE" > "$T/page.js"

echo "[no-network]"
URLS="$(grep -Eo 'https?://[^"'"'"' <>)]+' "$SAMPLE" \
  | grep -Ev '^http://www\.w3\.org/(2000/svg|1999/xlink|1999/xhtml|XML/1998/namespace)$' || true)"
assert_eq "" "$URLS" "the sheet names no http(s) URL"
assert_eq "0" "$(grep -Eic '<(link|img|iframe|object|embed|audio|video|source|base|form)[[:space:]>]|@import|url\(' "$T/template.html" || true)" \
  "the template loads nothing: no link, media, frame, @import or url()"
assert_file_contains "$SAMPLE" "default-src 'none'" "a CSP of default-src 'none' blocks every fetch"
NONCE="$(sed -n "s/.*script-src 'nonce-\([0-9a-f]*\)'.*/\1/p" "$SAMPLE" | head -1)"
TOTAL=$((TOTAL + 1))
if [ "${#NONCE}" -ge 16 ]; then
  echo "  PASS: the CSP carries a script nonce"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the CSP carries no usable script nonce ('$NONCE')"
  FAIL=$((FAIL + 1))
fi
assert_file_contains "$SAMPLE" "style-src 'nonce-$NONCE'" "styles answer to the same nonce"
assert_file_contains "$SAMPLE" "<style nonce=\"$NONCE\">" "the inline style carries the nonce, or the CSP would drop it"
assert_file_contains "$SAMPLE" "<script nonce=\"$NONCE\">" "the inline script carries the nonce, or the CSP would block it"
assert_eq "1" "$(grep -c '<script' "$T/template.html")" "the template has exactly one executable script"
assert_eq "0" "$(grep -Eic '<[^>]+[[:space:]](on[a-z]+|style)=' "$T/template.html" || true)" \
  "the template has no inline handler or style attribute (the CSP would block them)"

echo "[no-markup-sinks]"
assert_file_not_contains "$SAMPLE" "innerHTML" "the sheet never assigns innerHTML"
for sink in outerHTML insertAdjacentHTML document.write 'eval(' 'new Function'; do
  assert_file_not_contains "$T/page.js" "$sink" "the page script never uses $sink"
done

echo "[page-script]"
if [ "$HAVE_NODE" = true ]; then
  assert_cmd_success "node --check '$T/page.js'" "the inline page script parses (node --check)"
  # A DOM stand-in just wide enough for the page script: elements, text nodes, events,
  # localStorage and the clipboard. Each check prints "ok <name>" or "not ok <name>".
  cat > "$T/harness.js" <<'JS'
'use strict';
const fs = require('fs');
const vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const expected = fs.readFileSync(process.argv[3], 'utf8').replace(/\n$/, '');
const OPEN = '<script type="application/json" id="sheet-data"';
const at = html.indexOf(OPEN);
const tagEnd = html.indexOf('>', at) + 1;
const skeleton = html.slice(0, at);
const renderDate = /data-date="([^"]*)"/.exec(html.slice(at, tagEnd))[1];
const dataText = html.slice(tagEnd, html.indexOf('</script>', at));
const js = /<script nonce="[0-9a-f]+">([\s\S]*?)<\/script>/.exec(html)[1];

function say(ok, name, got) {
  console.log((ok ? 'ok ' : 'not ok ') + name + (ok || got === undefined ? '' : ' (got ' + JSON.stringify(got) + ')'));
}
class Text { constructor(s) { this.data = String(s); } get textContent() { return this.data; } }
class El {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase(); this.children = []; this.attrs = {}; this.on = {};
    this.hidden = false; this.disabled = false; this.value = ''; this.checked = false; this.className = '';
  }
  appendChild(c) { this.children.push(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; }
  addEventListener(t, f) { (this.on[t] = this.on[t] || []).push(f); }
  fire(t) { (this.on[t] || []).forEach((f) => f({ type: t, target: this })); }
  focus() { this.focused = true; }
  select() { this.selected = true; }
  get textContent() { return this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this.children = v === '' || v == null ? [] : [new Text(v)]; }
}
function find(root, pred, out) {
  out = out || [];
  root.children.forEach((c) => { if (c instanceof El) { if (pred(c)) out.push(c); find(c, pred, out); } });
  return out;
}
const text = (e) => (e ? e.textContent : null);
const radios = (card) => find(card, (e) => e.tagName === 'INPUT' && e.type === 'radio');
const notes = (card) => find(card, (e) => e.tagName === 'TEXTAREA')[0];
const status = (card) => find(card, (e) => e.className === 'status')[0];
function choose(card, j) { const rs = radios(card); rs.forEach((r, k) => { r.checked = k === j; }); rs[j].fire('change'); }
function type(card, s) { const ta = notes(card); ta.value = s; ta.fire('input'); }
async function copy(p) { p.reg.copy.fire('click'); await new Promise((r) => setImmediate(r)); }

// page(opts) — run the page script once against a fresh DOM built from the skeleton.
function page(opts) {
  opts = opts || {};
  const reg = Object.create(null), tags = [];
  const re = /<([a-z0-9]+)([^>]*)>/gi;
  let m;
  while ((m = re.exec(skeleton))) {
    const id = /\sid="([^"]+)"/.exec(m[2]);
    if (!id) continue;
    const e = new El(m[1]);
    e.id = id[1];
    e.hidden = /\shidden(\s|$)/.test(m[2]);
    reg[e.id] = e;
  }
  const data = new El('script');
  data.textContent = opts.data !== undefined ? opts.data : dataText;
  data.setAttribute('data-date', renderDate);
  reg['sheet-data'] = data;
  const store = new Map(opts.storage || []);
  const clip = { text: null };
  const document = {
    title: '',
    getElementById: (id) => reg[id] || null,
    createElement: (t) => { tags.push(String(t).toLowerCase()); return new El(t); },
    createTextNode: (s) => new Text(s),
  };
  const window = {};
  if (opts.storageBlocked) {
    Object.defineProperty(window, 'localStorage', { get() { throw new Error('SecurityError'); } });
  } else {
    window.localStorage = {
      getItem: (k) => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => { store.set(k, String(v)); },
      removeItem: (k) => { store.delete(k); },
    };
  }
  const navigator = opts.clipboard === 'missing' ? {} : { clipboard: { writeText: (t) => {
    clip.text = t;
    return opts.clipboard === 'reject' ? Promise.reject(new Error('NotAllowedError')) : Promise.resolve();
  } } };
  const ctx = vm.createContext({ document, window, navigator, setTimeout: () => 0, clearTimeout: () => {} });
  let error = null;
  try { vm.runInContext(js, ctx); } catch (e) { error = e; }
  const cards = reg.app ? reg.app.children.filter((c) => c.tagName === 'ARTICLE') : [];
  return { reg, tags, store, clip, document, error, cards };
}

(async () => {
  const TITLE = 'Sample sheet: "quoted" & ünïcödé';
  const XSS_Q = 'Is </script><img src=x onerror=alert(1)> rendered as text?';
  const lines = expected.split('\n');

  const a = page();
  say(a.error === null, 'the page script runs without throwing', a.error && String(a.error));
  say(a.document.title === TITLE, 'the tab title comes from the data', a.document.title);
  say(a.cards.length === 3, 'one card per decision', a.cards.length);
  say(text(a.reg.count) === '0 of 3', 'the bar starts at 0 of 3 answered', text(a.reg.count));
  say(text(a.reg.eyebrow) === 'Decision sheet · 2026-01-02', 'with no date in the data, DECISIONS_DATE is shown', text(a.reg.eyebrow));
  say(!a.reg.intro.hidden && text(a.reg.intro).indexOf('Three calls') === 0, 'the intro is shown');
  say(text(find(a.cards[1], (e) => e.tagName === 'H3')[0]) === XSS_Q, 'a question holding </script><img ...> is shown as text');
  const bad = a.tags.filter((t) => ['img', 'script', 'iframe', 'a', 'link', 'style', 'object', 'embed'].indexOf(t) >= 0);
  say(bad.length === 0, 'the page creates no element that could load or run anything', bad);
  say(find(a.cards[1], (e) => e.tagName === 'B' && text(e) === '<b>bold?</b>').length === 1, 'markup in an option label is shown as text');
  const recs = find(a.reg.app, (e) => e.className === 'rec');
  const firstLabel = find(a.cards[0], (e) => e.tagName === 'LABEL' && e.className.indexOf('opt') === 0)[0];
  say(recs.length === 1 && find(firstLabel, (e) => e.className === 'rec').length === 1, 'one Recommended tag, on the recommended option', recs.length);
  const ctx0 = text(find(a.cards[0], (e) => e.tagName === 'DETAILS')[0]) || '';
  say(['Paragraph one.', "Paragraph two, with 'single' quotes.", 'Premises: CI is green [verified]', 'Reversible: yes', 'Blocks: the release']
    .every((s) => ctx0.indexOf(s) >= 0), 'context, premises, reversible and blocks render in the Context section', ctx0);
  say((text(find(a.cards[2], (e) => e.tagName === 'DETAILS')[0]) || '').indexOf('Reversible: no') >= 0, 'a one-way decision says so in its context');
  say(find(a.cards[1], (e) => e.tagName === 'DETAILS').length === 0, 'no Context section for a decision without one');
  say(a.reg['storage-note'].hidden === true, 'no storage warning while drafts can be kept');

  choose(a.cards[0], 0);
  say(text(status(a.cards[0])) === 'Answered' && status(a.cards[0]).getAttribute('data-kind') === 'done', 'choosing an option marks the card answered', text(status(a.cards[0])));
  say(text(a.reg.count) === '1 of 3', 'choosing an option updates the count', text(a.reg.count));
  type(a.cards[2], '  line one\nline two  ');
  say(text(status(a.cards[2])) === 'Notes only', 'a note on its own marks the card "Notes only"', text(status(a.cards[2])));
  say(text(a.reg.count) === '1 of 3', 'a note on its own is not an answer', text(a.reg.count));
  choose(a.cards[2], 0);
  say(text(a.reg.count) === '2 of 3', 'the count follows each choice', text(a.reg.count));
  await copy(a);
  say(a.clip.text === expected, 'Copy answers writes the exact answer text', a.clip.text);
  say(a.reg.copybox.hidden === true && text(a.reg.copy) === 'Copied', 'a successful copy keeps the fallback box hidden', [a.reg.copybox.hidden, text(a.reg.copy)]);

  const b = page({ storage: a.store });
  say(radios(b.cards[0])[0].checked && radios(b.cards[2])[0].checked && !radios(b.cards[1])[0].checked, 'a reload restores the chosen options');
  say(notes(b.cards[2]).value === '  line one\nline two  ', 'a reload restores the notes as typed', notes(b.cards[2]).value);
  say(text(b.reg.count) === '2 of 3', 'a reload restores the count', text(b.reg.count));
  await copy(b);
  say(b.clip.text === expected, 'the restored sheet copies the same text', b.clip.text);

  const c = page({ storageBlocked: true });
  say(c.error === null && c.cards.length === 3, 'with storage blocked the page still renders', c.error && String(c.error));
  say(c.reg['storage-note'].hidden === false, 'with storage blocked the page says drafts are not kept');
  choose(c.cards[1], 1);
  await copy(c);
  say(text(c.reg.count) === '1 of 3' && (c.clip.text || '').split('\n')[2] === '2. [xss] ' + XSS_Q + ' → Plain',
    'with storage blocked, choosing and copying still work', c.clip.text);

  const d = page({ clipboard: 'reject' });
  choose(d.cards[0], 1);
  await copy(d);
  say(d.reg.copybox.hidden === false && d.reg.copybox.selected === true
    && d.reg.copybox.value.split('\n')[1] === '1. [ship-now] Ship the "fast" path now? → Not yet',
    'a refused clipboard shows the text selected in the box', [d.reg.copybox.hidden, d.reg.copybox.value]);
  say(text(d.reg.copy) !== 'Copied', 'a refused clipboard does not claim a copy', text(d.reg.copy));

  const e = page({ clipboard: 'missing' });
  await copy(e);
  say(e.reg.copybox.hidden === false && e.reg.copybox.value.split('\n')[0] === lines[0], 'with no clipboard API the text is shown to copy by hand', e.reg.copybox.value);

  const dated = JSON.parse(dataText);
  dated.date = '23 Oct 2026';
  const f = page({ data: JSON.stringify(dated) });
  await copy(f);
  say((f.clip.text || '').split('\n')[0] === 'Decision answers: ' + TITLE + ' (23 Oct 2026)', "the data's own date heads the copy text", f.clip.text);

  const g = page({ data: '{"title": "x", "decisions": [' });
  say(g.error === null && g.reg.error.hidden === false && /could not be read/.test(text(g.reg.error)),
    'unparseable data shows a clear error, not a blank page', text(g.reg.error));
  say(g.reg.copy.disabled === true, 'with unreadable data there is nothing to copy');
  console.log('done');
})().catch((err) => { console.log('not ok the harness crashed: ' + String((err && err.stack) || err).split('\n')[0]); });
JS
  HARNESS_OUT="$(node "$T/harness.js" "$SAMPLE" "$T/expected.txt" 2>&1)" || true
  while IFS= read -r line; do
    case "$line" in
      "ok "*) TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "  PASS: ${line#ok }" ;;
      "not ok "*) TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo "  FAIL: ${line#not ok }" ;;
    esac
  done <<EOF
$HARNESS_OUT
EOF
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$HARNESS_OUT" | grep -qx 'done'; then
    echo "  PASS: the page harness ran to the end"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: the page harness stopped early:"
    printf '%s\n' "$HARNESS_OUT" | tail -5 | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
else
  echo "  NOTE: node not found; the page script's syntax and behaviour checks did not run"
fi

# --- Where it goes --------------------------------------------------------------------
echo "[default-path]"
mkdir -p "$T/repo/sub"
(cd "$T/repo" && git init -q -b main && git commit -q --allow-empty --no-gpg-sign -m init)
GCD_REAL="$(cd "$T/repo/.git" && pwd -P)"
run "$T/repo/sub" "$T/mini.json"
assert_eq "$GCD_REAL/decisions/sheets/2026-01-02-default-path-check.html" "$OUT_TXT" \
  "in a repo, from a subdirectory: <git-common-dir>/decisions/sheets/<DECISIONS_DATE>-<slug>.html"
assert_file_exists "$GCD_REAL/decisions/sheets/2026-01-02-default-path-check.html" "the sheet is there"
assert_eq "drwx------" "$(mode_of "$GCD_REAL/decisions/sheets")" "the sheets directory is private to its owner"
(cd "$T/repo" && git worktree add -q "$T/wt" 2>/dev/null)
run "$T/wt" "$T/sample.json"
assert_eq "$GCD_REAL/decisions/sheets/2026-01-02-sample-sheet-quoted-n-c-d.html" "$OUT_TXT" \
  "a worktree's sheet goes to the clone's common git dir, shared by every worktree"

mkdir -p "$T/repo2"
(cd "$T/repo2" && git init -q -b main)
: > "$T/repo2/.git/decisions"
run "$T/repo2" "$T/mini.json"
assert_eq "$TMP_REAL/decision-sheets/2026-01-02-default-path-check.html" "$OUT_TXT" \
  "where the git dir can't take the sheet (as at High), it falls back to \$TMPDIR/decision-sheets"
assert_eq "0" "$(wc -c < "$T/repo2/.git/decisions" | tr -d ' ')" "the blocking file is left as it was"

rm -rf "$T/tmp/decision-sheets"
run "$T/nogit" "$T/mini.json"
assert_eq "$TMP_REAL/decision-sheets/2026-01-02-default-path-check.html" "$OUT_TXT" \
  "outside a git repo the sheet goes to \$TMPDIR/decision-sheets"
assert_eq "drwx------" "$(mode_of "$T/tmp/decision-sheets")" "the fallback directory is private to its owner"
assert_eq "-rw-------" "$(mode_of "$OUT_TXT")" "the fallback sheet is readable by its owner only"

TODAY="$(date +%Y-%m-%d)"
RC=0
OUT_TXT="$(cd "$T/nogit" && unset DECISIONS_DATE && bash "$SHEET" "$T/mini.json" 2>/dev/null)" || RC=$?
assert_eq "$TMP_REAL/decision-sheets/$TODAY-default-path-check.html" "$OUT_TXT" "without DECISIONS_DATE the name carries today's date"
RC=0
ERR_TXT="$(cd "$T/nogit" && DECISIONS_DATE=../../escape bash "$SHEET" "$T/mini.json" 2>&1 >/dev/null)" || RC=$?
refused "a DECISIONS_DATE that is not YYYY-MM-DD is refused, so it can't steer the path" "DECISIONS_DATE must be YYYY-MM-DD"

echo "[output-flag]"
run "$T/nogit" "$T/mini.json" -o rel/dir/one.html
assert_eq "$(cd "$T/nogit/rel/dir" 2>/dev/null && pwd -P)/one.html" "$OUT_TXT" "-o writes a relative path, creating its directory, and prints it absolute"
run "$T/nogit" "$T/mini.json" -o rel/dir/one.html
succeeded "-o replaces a sheet this script wrote"
printf 'keep me\n' > "$T/nogit/notes.html"
run "$T/nogit" "$T/mini.json" -o notes.html
refused "-o never replaces a file this script did not write" "did not write"
assert_eq "keep me" "$(cat "$T/nogit/notes.html")" "and that file is left as it was"
ln -s "$T/nogit/notes.html" "$T/nogit/link.html"
run "$T/nogit" "$T/mini.json" -o link.html
refused "-o refuses a symlink to a file this script did not write" "did not write"
assert_eq "keep me" "$(cat "$T/nogit/notes.html")" "and the symlink's target is left as it was"
ln -s one.html "$T/nogit/rel/dir/two.html"
run "$T/nogit" "$T/sample.json" -o rel/dir/two.html
TOTAL=$((TOTAL + 1))
if [ "$RC" -eq 0 ] && [ ! -L "$T/nogit/rel/dir/two.html" ] && grep -qF '<title>Default path check</title>' "$T/nogit/rel/dir/one.html"; then
  echo "  PASS: a symlink at the target is replaced, never written through"
  PASS=$((PASS + 1))
else
  echo "  FAIL: a symlink at the target was followed or kept (exit $RC)"
  FAIL=$((FAIL + 1))
fi
run "$T/nogit" "$T/mini.json" -o "$T/nogit/out.txt"
refused "-o takes only an .html path" "ending in .html"
assert_file_not_exists "$T/nogit/out.txt" "and writes nothing"

# --- What it refuses to read ----------------------------------------------------------
echo "[input]"
run "$T/nogit" "$T/no-such.json"
refused "a missing input exits non-zero and says so" "no such file"
run "$T/nogit" "$T/nogit"
refused "a directory is refused" "not a regular file"
: > "$T/empty.json"
run "$T/nogit" "$T/empty.json"
refused "an empty file is refused" "empty file"
cp "$T/mini.json" "$T/locked.json"
chmod 000 "$T/locked.json"
if [ "$(id -u)" -eq 0 ]; then
  echo "  NOTE: running as root, which reads any file; the unreadable-input check did not run"
else
  run "$T/nogit" "$T/locked.json"
  refused "an unreadable input exits non-zero and says so" "cannot read"
fi
# A keypair is a JSON array of numbers; a credential file is an object without these keys.
printf '[12, 34, 56, 78]\n' > "$T/id.json"
run "$T/nogit" "$T/id.json"
refused "a JSON array (a keypair's shape) is refused, so the sheet can't carry one" "does not look like a decisions file"
printf '{"type": "service_account", "client_email": "x@example.invalid"}\n' > "$T/creds.json"
run "$T/nogit" "$T/creds.json"
refused "an object without title and decisions is refused" "does not look like a decisions file"
{ printf '{"title": "big", "decisions": []}'; head -c 1048577 /dev/zero | tr '\0' ' '; } > "$T/big.json"
run "$T/nogit" "$T/big.json"
refused "an input over 1 MiB is refused" "at most"
printf '{"title": "x", "decisions": [}\n' > "$T/broken.json"
printf '{"title": "x", "decisions": [{"id": "a", "number": 1, "question": "q?", "recommended": "z",\n "options": [{"value": "y", "label": "Yes"}]}]}\n' > "$T/badrec.json"
printf '{"title": "x", "decisions": [\n {"id": "a", "number": 1, "question": "q?", "options": [{"value": "y", "label": "Yes"}]},\n {"id": "a", "number": 2, "question": "r?", "options": [{"value": "y", "label": "Yes"}]}]}\n' > "$T/dupid.json"
if [ "$HAVE_PY" = true ] || [ "$HAVE_NODE" = true ]; then
  run "$T/nogit" "$T/broken.json"
  refused "invalid JSON is refused when a validator exists" "not valid JSON"
  run "$T/nogit" "$T/badrec.json"
  refused "a recommended value that is not an option is refused" "is not one of its option values"
else
  echo "  NOTE: neither python3 nor node found; the validation checks did not run"
fi

echo "[validators]"
TOOLS="cat wc tr head od grep sed cut date uname mkdir mktemp mv rm awk"
# fake_path <dir> <tool>... — a PATH holding only these tools.
fake_path() {
  local dir="$1" t p
  shift
  mkdir -p "$dir"
  for t in "$@"; do
    p="$(command -v "$t" 2>/dev/null)" || { echo "  NOTE: $t not found for a restricted PATH"; return 1; }
    ln -sf "$p" "$dir/$t"
  done
}
if fake_path "$T/bin-none" $TOOLS; then
  run_with_path "$T/bin-none" "$T/nogit" "$T/mini.json"
  assert_eq "$TMP_REAL/decision-sheets/2026-01-02-default-path-check.html" "$OUT_TXT" \
    "with no python3, node or git it still names the sheet from the title"
  assert_contains "$ERR_TXT" "no python3 or node" "and says the data went unvalidated"
  assert_file_contains "$OUT_TXT" "<title>Default path check</title>" "the title is read without a JSON parser"
  run_with_path "$T/bin-none" "$T/nogit" "$T/broken.json" -o "$T/nogit/broken.html"
  succeeded "with no validator, invalid JSON still renders, for the page to report"
  # With no validator the shape floor is all that stands; each half has to hold alone.
  run_with_path "$T/bin-none" "$T/nogit" "$T/id.json" -o "$T/nogit/id.html"
  refused "with no validator, a keypair-shaped file is still refused" "does not look like a decisions file"
  printf '[{"title": "x", "decisions": []}]\n' > "$T/wrapped.json"
  run_with_path "$T/bin-none" "$T/nogit" "$T/wrapped.json" -o "$T/nogit/wrapped.html"
  refused "with no validator, an array is refused even when it holds both keys" "does not look like a decisions file"
  run_with_path "$T/bin-none" "$T/nogit" "$T/creds.json" -o "$T/nogit/creds.html"
  refused "with no validator, an object without both keys is refused" "does not look like a decisions file"
  assert_file_not_exists "$T/nogit/creds.html" "and nothing is written for a refused file"
fi
if [ "$HAVE_NODE" = true ] && fake_path "$T/bin-node" $TOOLS node; then
  run_with_path "$T/bin-node" "$T/nogit" "$T/dupid.json" -o "$T/nogit/dup.html"
  refused "without python3, node validates (a repeated id is refused)" "is used twice"
  run_with_path "$T/bin-node" "$T/nogit" "$T/sample.json" -o "$T/nogit/node.html"
  succeeded "node accepts the sample"
  # A python3 that cannot run, like macOS's stub without the command line tools.
  if fake_path "$T/bin-stub" $TOOLS node; then
    printf '#!/bin/sh\nexit 1\n' > "$T/bin-stub/python3"
    chmod +x "$T/bin-stub/python3"
    run_with_path "$T/bin-stub" "$T/nogit" "$T/broken.json" -o "$T/nogit/stub.html"
    refused "a python3 that can't run hands over to node" "not valid JSON"
    assert_contains "$ERR_TXT" "python3 could not run" "and says python3 could not run"
  fi
fi
if [ "$HAVE_PY" = true ]; then
  run "$T/nogit" "$T/dupid.json"
  refused "python3 refuses a repeated id" "is used twice"
  # The validator must not import from the project directory: a repo could plant json.py.
  mkdir -p "$T/plant"
  printf 'import os\nopen(os.path.join(os.path.dirname(os.path.abspath(__file__)), "IMPORTED"), "w").close()\n' > "$T/plant/json.py"
  run "$T/plant" "$T/mini.json" -o "$T/plant/out.html"
  succeeded "renders from a directory holding a json.py"
  assert_file_not_exists "$T/plant/IMPORTED" "python3 runs isolated (-I): a planted json.py is never imported"
fi

print_summary
