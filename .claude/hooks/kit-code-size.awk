# kit-code-size.awk — the length of a Bash command less the heredoc bodies that only
# write a file, for lib-headless.sh's kit_size_cap.  Run with lib-tokenize.awk, which
# calls back into the two functions below.
#
# Only a body fed to `cat` or `tee` is left out: the guards copy those rather than
# parse them, so even a large one costs them almost nothing, and it is the usual way
# to write a file.  Every other body counts, quoted or not, because some guard reads
# a body fed to a shell or an interpreter as code, and that is where the time goes.
# A `<<<` here-string is not a heredoc.
function kit_wrapper(c) { return (is_wrapper(c) || is_shell(c)) }
function kit_heredoc_is_code(c) { return 1 }
function code_size(raw,   size, delim, nl, L, k, l, t, d, head, hn, HT, HQ, hw, skip, p) {
  size = 0; delim = ""; skip = 0
  nl = split(raw, L, "\n")
  for (k = 1; k <= nl; k++) {
    l = L[k]
    if (delim != "") {
      t = l; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == delim) delim = ""
      else if (!skip) size += length(l) + 1
      continue
    }
    size += length(l) + 1
    # The first `<<WORD` that is not part of a `<<<`.
    p = l
    while (match(p, /<<-?[ \t]*["']?[A-Za-z_][A-Za-z0-9_]*/)) {
      if (substr(p, RSTART + 2, 1) == "<" || (RSTART > 1 && substr(p, RSTART - 1, 1) == "<")) {
        p = substr(p, RSTART + 3); continue
      }
      d = substr(p, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", d); gsub(/["']/, "", d)
      head = substr(l, 1, index(l, substr(p, RSTART, RLENGTH)) - 1)
      hn = tokenize(split_cmd(head), HT, HQ); hw = cmdword_x(HT, hn, 0, 0)
      delim = d; skip = (hw == "cat" || hw == "tee")
      break
    }
  }
  return size
}
{ raw = raw $0 "\n" }
END { print code_size(raw) }
