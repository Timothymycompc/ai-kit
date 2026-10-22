# kit-code-size.awk — whether a Bash command is small enough for the guards to read
# in time, for lib-headless.sh's kit_size_cap: prints "ok" when the code in it, its
# length less the heredoc bodies every guard copies rather than parses, is within
# KIT_CODE_LIMIT bytes and it has at most KIT_LINE_LIMIT lines, and "over"
# otherwise.  Run with lib-tokenize.awk, which calls back into the two functions
# below.  The line limit is there because every guard builds its input into one
# string a line at a time, which is quadratic in awk: 262,144 empty lines kept each
# guard busy 10 s, whatever the bytes.  This file reads line by line instead, and
# stops counting once the code limit is passed.
#
# It leaves a body out only when all of these hold, so a mistake here can only
# refuse more:
#   - the shell reads the `<<` as an operator (kit_hd_ops), outside every quote,
#     $( ), ( ) and `…`.  Inside a substitution the body's output may run as code:
#     `bash -c "$(cat <<'EOF' …)"`;
#   - the command it feeds is cat or tee, and the line has no `|`, `(` or
#     backquote, so nothing hands the body to a program that runs it:
#     `cat <<'EOF' | bash`;
#   - it is the only heredoc on its line, and that line neither continues onto
#     the next nor is continued from the last: the guards read a continued line
#     joined, so `bash \<newline>cat <<'EOF'` is a heredoc fed to bash;
#   - its delimiter is quoted, or the body holds no $( or backquote, since an
#     unquoted body runs its substitutions and the guards read those as code;
#   - the delimiter line arrives.  An unterminated body counts.
function kit_wrapper(c) { return (is_wrapper(c) || is_shell(c)) }
function kit_heredoc_is_code(c) { return 1 }
function code_line(l,   t, np, s, d, hs, HS, hn, HT, HQ, hw, x, wascont) {
  if (delim != "") {
    t = l; gsub(/^[ \t]+|[ \t]+$/, "", t)
    if (t == delim) { delim = ""; SIZE += length(l) + 1; return }
    if (!exempt) { SIZE += length(l) + 1; return }
    pend += length(l) + 1
    if (!quoted && (index(l, "$(") || index(l, "`"))) { exempt = 0; SIZE += pend; pend = 0 }
    return
  }
  SIZE += length(l) + 1
  if (SIZE > LIMIT) return
  np = kit_hd_ops(l, q); q = KH_QEND
  # Ending in a backslash outside '…' continues the line, as the shell reads it.
  wascont = cont; cont = (l ~ /\\$/ && q !~ /s$/)
  if (np == 0) return
  s = substr(l, KH_P[1]); quoted = 0
  if (match(s, "^" HD_DQ) || match(s, "^" HD_SQ)) quoted = 1
  else if (!match(s, "^" HD_BARE)) return
  d = substr(s, 1, RLENGTH); sub(/^<<-?[ \t]*/, "", d); gsub(/"/, "", d); gsub(SQ, "", d)
  hs = split(split_cmd(substr(l, 1, KH_P[1] - 1)), HS, /\001/)
  hs = split(HS[hs], HS, /\002/); hn = tokenize(HS[hs], HT, HQ); hw = cmdword_x(HT, hn, 0, 0)
  x = l; gsub(/\|\|/, "", x)
  exempt = (np == 1 && !cont && !wascont && KH_S[1] == "" && (hw == "cat" || hw == "tee") && x !~ /[|(`]/)
  delim = d; pend = 0
}
BEGIN {
  HD_DQ = "<<-?[ \t]*\"[A-Za-z_][A-Za-z0-9_]*\""
  HD_SQ = "<<-?[ \t]*" SQ "[A-Za-z_][A-Za-z0-9_]*" SQ
  HD_BARE = "<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*"
  LIMIT = ENVIRON["KIT_CODE_LIMIT"] + 0
  if (LIMIT < 1) LIMIT = 32768
  LINES = ENVIRON["KIT_LINE_LIMIT"] + 0
  if (LINES < 1) LINES = 10000
  SIZE = 0; q = ""; delim = ""; cont = 0
}
SIZE <= LIMIT { code_line($0) }
END {
  # An unterminated body counts: nothing proves it is only data.
  if (delim != "" && exempt) SIZE += pend
  print (SIZE <= LIMIT && NR <= LINES) ? "ok" : "over"
}
