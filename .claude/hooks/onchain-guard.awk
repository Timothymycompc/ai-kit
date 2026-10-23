# onchain-guard.awk — statement normaliser for the on-chain write gate.
#
#   awk -f lib-tokenize.awk -f onchain-guard.awk
#
# stdin : raw command text.  stdout: the same text with leading VAR= assignments
# kept, wrapper binaries and their options dropped, whitespace runs collapsed,
# and statement separators preserved, and every heredoc body reduced to what
# runs (hd_strip, #166): a document whose line begins with a gated verb is not a
# statement, while `bash <<'EOF' … solana program deploy … EOF` still is.
#
# Why this is NOT the shared tokenizer, even after #138 extracted one.
#
# The gate downstream is a position-anchored egrep: the gated verb has to START a
# statement.  That design needs the separators left IN the text, which split_cmd
# deliberately replaces with \001/\002.  The library's strip_heredocs is not used
# either: it reads a quoted delimiter as "prose", and a quoted body fed to bash
# is not prose.
#
# So this file takes from the library only what it can take identically — base(),
# is_wrapper(), is_shell(), kit_wrapper_optarg(), split_cmd() and tokenize() for
# heredoc heads — and keeps its own pass.  Rewriting it onto
# split_cmd is a behaviour change to the mainnet gate and belongs in its own
# change, with its own test corpus, not in a refactor.
#
# What it does take since: kit_shell_text, which joins backslash-newline
# continuations before anything else reads the text, and kit_qscan, which tells
# the pass below whether a statement starts in code or inside a quoted argument.
# A reserved word leading a statement (`if true; then anchor deploy …`) is
# dropped like a wrapper, but only in code: the split below is quote-blind on
# purpose, so `git commit -m "…; then anchor deploy …"` reaches strip() too.

# ---- the library's callbacks.  cmdword_x and strip_heredocs are never reached
# from here, but awk resolves a call lazily and a stray one would be a runtime
# error, so both are defined.
function kit_wrapper(b) { return wrapper(b) }
function kit_heredoc_is_code(b) { return is_shell(b) }

# wrapper — what this gate looks past.  The library's is_wrapper is exactly the
# non-shell half of the list this file used to carry; is_shell adds sh/bash/dash/
# zsh/ksh, and `ash` (BusyBox) is named here because the library's is_shell does
# not list it.  is_shell DOES list `fish`, which this file's own copy lacked — the
# one widening the extraction makes, and a plain fix: `fish -c "solana program
# deploy --url mainnet-beta"` made the gate silent before.
function wrapper(b) { return (is_wrapper(b) || is_shell(b) || b == "ash") }

# The options of those wrappers that swallow the next word (env -u HOME,
# xargs -I {}, nice -n 5, sudo -u me) are the library's kit_wrapper_optarg, the
# table this file carried first and lib-tokenize.awk now shares with the git gates.
#
# cmd is 1 when st starts in code, which is when a reserved word leading it is
# grammar to drop rather than text to keep.  ST_PAYLOAD comes back as the position
# in st of the quote that opens a wrapper's payload (`bash -c "…`), or 0, so the
# caller can read that quote as code and the rest of the payload with it.
function strip(st, cmd,   n, A, i, j, w, b, cur, hadw, keep, out) {
  n = split(st, A, /[ \t\r]+/)
  i = 1
  while (i <= n && A[i] == "") i++
  keep = ""; hadw = 0; ST_PAYLOAD = 0
  while (i <= n) {
    w = A[i]; b = base(w)
    # VAR=value is kept, not dropped: the cluster resolver in onchain-guard.sh
    # reads ANCHOR_PROVIDER_URL= out of this string, and the regex already allows
    # a run of assignments in front of the verb.
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { keep = keep w " "; i++; continue }
    # `coproc NAME { … }` and `function NAME` are headers; the command follows.
    if (cmd && w == "coproc" && i + 2 <= n && A[i + 2] == "{") { i += 2; continue }
    if (cmd && kit_reserved(w)) { i++; continue }
    if (cmd && w == "function" && i < n) { i += 2; continue }
    if (!wrapper(b)) break
    cur = b; hadw = 1; i++
    while (i <= n) {
      if (A[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { keep = keep A[i] " "; i++; continue }
      if (A[i] == "--") { i++; break }
      if (A[i] ~ /^[-+]/) { if (kit_wrapper_optarg(cur, A[i]) && i < n) i++; i++; continue }
      break
    }
    # One operand at most: timeout's duration, flock's lock file.
    if (i <= n && kit_wrapper_operand(cur, A[i])) i++
  }
  out = ""
  for (j = i; j <= n; j++) out = out (out == "" ? "" : " ") A[j]
  # A wrapper was consumed, so a quote here opens its payload (sh -c "solana
  # ...") rather than being part of the command word.
  if (hadw && sub(/^["\047]/, "", out)) {
    ST_PAYLOAD = field_pos(st, i)
    if (cmd) out = kit_unreserve(out)
  }
  return keep out
}
# field_pos — where field i of split(s, A, /[ \t\r]+/) starts in s.
function field_pos(s, i,   p, f) {
  p = 1
  for (f = 1; f < i; f++) {
    if (!match(substr(s, p), /[ \t\r]+/)) return 0
    p += RSTART + RLENGTH - 1
  }
  return p
}
# ---- heredoc classifier (#166).  This block, through hd_strip, is identical in
# secrets-guard.awk and onchain-guard.awk (tests/test_hooks.sh checks).  It
# belongs in lib-tokenize.awk once #233, which edits that file, has landed.
#
# The library's strip_heredocs keeps a body only when the delimiter is unquoted
# and the command on the left runs it.  Both halves miss: `python3 - <<'EOF'`
# runs a quoted body, and `cat <<EOF | sh` runs a body whose head is cat.  What
# decides is whether something RUNS the body: a shell or interpreter reading its
# program from stdin, as the command owning the heredoc, as a later stage of the
# pipeline, or as the inline-code command a `$(cat <<EOF …)` is spliced into
# (`bash -c "$(cat <<'EOF'`).  Quoting the delimiter changes expansion, not that.
# Every other body is data, except that an unquoted one still runs its $(…) and
# `…` substitutions, so those are kept and the prose around them is dropped.
#
# Each guard defines hd_interp_line(w, l): what an interpreter's body line
# becomes in the text the guard matches.

function hd_interp(w) {
  return (w == "python" || w == "python2" || w == "python3" || w == "node" || w == "deno" \
       || w == "bun" || w == "perl" || w == "ruby" || w == "php" || w == "osascript" \
       || w == "Rscript" || w == "lua" || w == "tclsh")
}
function hd_shell(w) { return (is_shell(w) || w == "ash") }
# hd_cmd — index of the command word, past assignments, reserved words
# (`then bash <<'EOF'`) and non-shell wrappers with the words their options take.
function hd_cmd(T, n,   ci, w) {
  ci = 1
  while (ci <= n) {
    while (ci <= n && (T[ci] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || kit_reserved(T[ci]))) ci++
    if (ci > n) break
    w = base(T[ci]); if (!is_wrapper(w) || w == "eval") break
    ci++
    while (ci <= n && T[ci] ~ /^-/) { if (ci < n && kit_wrapper_optarg(w, T[ci])) ci++; ci++ }
    if (ci <= n && kit_wrapper_operand(w, T[ci])) ci++
  }
  return ci
}
# hd_inline_flag — t makes w run its next argument as the program.
function hd_inline_flag(w, t) {
  if (hd_shell(w)) return (t ~ /^-[A-Za-z]*c[A-Za-z]*$/)
  return (t ~ /^-[A-Za-z]*[ceEp]$/ || t == "-m" || t ~ /^--(eval|print)/ || (w == "php" && t == "-r"))
}
# hd_stdin_path — t names the process's own stdin, which `-` also means.
function hd_stdin_path(t) { return (t == "-" || t == "/dev/stdin" || t == "/dev/fd/0" || t == "/proc/self/fd/0") }
# hd_stdin_code — the command at T[ci] reads its program from stdin.
function hd_stdin_code(T, n, ci,   w, sh, i, t) {
  w = base(T[ci])
  if (w == "source" || w == ".") return (ci < n && hd_stdin_path(T[ci + 1]))
  sh = hd_shell(w)
  if (!sh && !hd_interp(w)) return 0
  for (i = ci + 1; i <= n; i++) {
    t = T[i]
    if (hd_stdin_path(t)) return 1
    if (t ~ /^-/) {
      if (hd_inline_flag(w, t)) return 0             # stdin is that program's data
      if (sh ? t == "-o" : t ~ /^-[WX]$/) i++          # options taking a value
      continue
    }
    if ((w == "deno" || w == "bun") && t == "run" && i == ci + 1) continue
    return 0                                           # a script file; stdin is its data
  }
  return 1
}
# hd_inline — the command at T[ci] runs an argument as code.
function hd_inline(T, n, ci,   w, i) {
  w = base(T[ci])
  if (w == "eval") return 1
  if (!hd_shell(w) && !hd_interp(w)) return 0
  for (i = ci + 1; i <= n; i++) if (T[i] ~ /^-/ && hd_inline_flag(w, T[i])) return 1
  return 0
}
# hd_consumer — the word that runs a heredoc opened between head and tail on one
# line, or "" when its body is data.
function hd_consumer(head, tail,   ns, S, ng, G, g, n, T, Q, ci) {
  ns = split(split_cmd(head), S, "\001"); ng = split(S[ns], G, "\002")
  n = tokenize(G[ng], T, Q); ci = hd_cmd(T, n)
  if (ci <= n && hd_stdin_code(T, n, ci)) return base(T[ci])
  if (ng > 1 && G[ng-1] ~ /\$__X__[ \t]*$/) {
    n = tokenize(G[ng-1], T, Q); ci = hd_cmd(T, n)
    if (ci <= n && hd_inline(T, n, ci)) return base(T[ci])
  }
  ns = split(split_cmd(tail), S, "\001"); ng = split(S[1], G, "\002")
  for (g = 2; g <= ng; g++) {
    n = tokenize(G[g], T, Q); ci = hd_cmd(T, n)
    if (ci <= n && hd_stdin_code(T, n, ci)) return base(T[ci])
  }
  return ""
}
# hd_open — fills HD_P with the positions on l of each `<<` outside quotes and
# comments, and returns how many.  HD_Q is the quoting still open from earlier
# lines, as a stack: s '…', d "…", b `…`, p ( or $( (unquoted again inside "…").
# A `<<` inside quotes is text: `echo "<<X"` opens no heredoc.
function hd_open(l,   i, L, c, top, k) {
  k = 0; L = length(l)
  for (i = 1; i <= L; i++) {
    c = substr(l, i, 1); top = substr(HD_Q, length(HD_Q))
    if (top == "s") { if (c == SQ) HD_Q = substr(HD_Q, 1, length(HD_Q) - 1); continue }
    if (c == "\\") { i++; continue }
    if (top == "d") {
      if (c == "\"") HD_Q = substr(HD_Q, 1, length(HD_Q) - 1)
      else if (substr(l, i, 2) == "$(") { HD_Q = HD_Q "p"; i++ }
      else if (c == "`") HD_Q = HD_Q "b"
      continue
    }
    if (c == SQ) HD_Q = HD_Q "s"
    else if (c == "\"") HD_Q = HD_Q "d"
    else if (c == "`") HD_Q = (top == "b") ? substr(HD_Q, 1, length(HD_Q) - 1) : HD_Q "b"
    else if (c == "(") HD_Q = HD_Q "p"
    else if (c == ")") { if (top == "p") HD_Q = substr(HD_Q, 1, length(HD_Q) - 1) }
    else if (c == "#" && (i == 1 || substr(l, i - 1, 1) ~ /[ \t;&|(]/)) break
    else if (substr(l, i, 3) == "<<<") i += 2                   # a here-string
    else if (substr(l, i, 2) == "<<") { HD_P[++k] = i; i++ }
  }
  return k
}
# hd_strip — the raw command with every heredoc body reduced to what runs.  The
# delimiter is read by the shared kit_hd_delim, so a partly quoted delimiter
# (`<<E'O'F`) is read whole instead of truncated, and the body end by kit_hd_end.
# An unquoted body that is data still runs its substitutions across lines
# (kit_hd_subst), so a multi-line `$( … )` in it is kept, not dropped.
function hd_strip(raw,   text, delim, dash, mode, who, nl, L, k, l, s, np, j, at) {
  text = ""; delim = ""; HD_Q = ""
  nl = split(raw, L, "\n")
  for (k = 1; k <= nl; k++) {
    l = L[k]
    if (delim != "") {
      if (kit_hd_end(l, delim, dash)) {
        if (mode == "subst") { s = kit_hd_subst_flush(); if (s != "") text = text s "\n" }
        delim = ""; continue
      }
      if (mode == "shell") text = text l "\n"
      else if (mode == "interp") { s = hd_interp_line(who, l); if (s != "") text = text s "\n" }
      else if (mode == "subst") { s = kit_hd_subst(l); if (s != "") text = text s "\n" }
      continue
    }
    np = hd_open(l); at = 0
    for (j = 1; j <= np && at == 0; j++) if (kit_hd_delim(substr(l, HD_P[j]))) at = HD_P[j]
    if (at > 0) {
      who = hd_consumer(substr(l, 1, at - 1), substr(l, at + KHD_LEN))
      delim = KHD_DELIM; dash = KHD_DASH
      if (who == "") { mode = KHD_QUOTED ? "drop" : "subst"; if (mode == "subst") kit_hd_subst_reset() }
      else mode = (hd_shell(who) || who == "eval" || who == "source" || who == ".") ? "shell" : "interp"
    }
    text = text l "\n"
  }
  return text
}


# An interpreter's heredoc keeps its brackets and loses its string delimiters,
# the shape lib-headless.sh gives a non-shell MCP payload for this gate:
# os.system("solana program deploy …") then anchors on its `(`.
function hd_interp_line(w, l) { gsub(/["\047]/, "", l); return l }

{ raw = raw $0 "\n" }
END {
  # Continuations are joined first, so a heredoc head split over two lines is
  # still one head to hd_strip.  qs is the quote stack carried from statement to
  # statement and line to line: a statement starting inside a plain quote is an
  # argument, so its leading `then` stays and the regex never anchors on it.
  nl = split(hd_strip(kit_shell_text(raw, 0)), LN, "\n")
  qs = ""; KP = ""
  for (k = 1; k <= nl; k++) {
    line = LN[k]; out = ""
    if (k == nl && line == "") break
    KQ_PREV = ""; KQ_COMMENT = 0
    while (length(line)) {
      if (match(line, /(\|\||&&|\$\(|[;&|()])/)) {
        st = substr(line, 1, RSTART - 1)
        sep = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      } else { st = line; sep = ""; line = "" }
      cmd = !KQ_COMMENT && kit_code_top(qs)
      out = out strip(st, cmd)
      out = out kit_stmt_sep(st, sep, qs, ST_PAYLOAD)
      qs = kit_qscan(st sep, qs, ST_PAYLOAD)
    }
    print out
  }
}
