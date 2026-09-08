# armscan.awk — emit one record per ARM of every `case` block that dispatches on a token-expiry
# verdict, for the SSO-lockout control in test-creds-show.sh.
#
# ⚠️ THERE IS NO CHARACTER CLASS FOR LABEL RECOGNITION, AND THAT IS THE WHOLE DESIGN.
# Four successive rounds refuted a version that asked "does this line LOOK like a label?" — a
# character class, then a whitespace test, then `^[^(]*\)`. Each was an ENUMERATED LIST guarding a
# SILENT MERGE into the previous arm, and each new list re-opened the previous hole somewhere else.
# The last one was a measurable REGRESSION: it closed `"REVOKED"*)` and `REVOKED* )` and opened
# `(REVOKED*)`, `@(R)*)`, `!(E)*)` — all valid bash, all shellcheck-clean, all inheriting EXPIRED.
#
# The shell already answers the question: a `case` arm ENDS at `;;`. So the line after `case … in`,
# and the line after every `;;` / `;;&` / `;&`, IS a label. Nothing to out-run.
#
# ⚠️ THE EXEMPT TEST IS ANCHORED. `!(EXPIRED)*)` contains "EXPIRED" but is the NEGATION of it, and
# an unanchored /EXPIRED/ would treat it as the one exempting label.
#
# Record: <file>\t<label>\t<arm text, comments stripped, newlines collapsed>
function flush_arm() { if (lab != "") { labs[n] = lab; txts[n] = buf; n++ } lab = ""; buf = "" }
function label_end(s,   i, d, c) {          # index of the ")" that closes the label, or 0
  d = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "(") d++
    else if (c == ")") { if (d == 0) return i; d-- }
  }
  return 0
}
FNR == 1 { depth = 0; n = 0; has = 0; lab = ""; buf = ""; want = 0 }
{ line = $0
  sub(/^[[:space:]]+/, "", line)
  # A TRAILING COMMENT must not hide the arm terminator. `;;   # the cause is a FACT here` made the
  # NEXT arm merge into this one — and since EXPIRED is first in every consumer, it inherited the
  # exempting label. Measured: 10 of 11 label spellings false-GREEN under that terminator, the
  # spelling being irrelevant. (Quotes are excluded from the strip so a `#` inside a string stays.)
  sub(/[[:space:]]+#[^"'\'']*$/, "", line)
  sub(/[[:space:]]+$/, "", line)
  if (line ~ /^#/) next                       # a COMMENT is not code
  if (line == "") next

  # A one-line `case … in … esac` opens and closes on the same line: it must not move depth, but it
  # IS part of the enclosing arm's body and can carry the remedy.
  if (line ~ /^case[[:space:]]/ && line ~ /esac[[:space:]]*(;;&?|;&)?[[:space:]]*$/) {
    if (lab != "") buf = buf " " line
    if (depth == 1 && line ~ /;;&?$|;&$/) want = 1   # it CLOSED the enclosing arm too
    next
  }
  if (line ~ /^case[[:space:]]/) {
    depth++
    if (depth == 1) { n = 0; has = 0; lab = ""; buf = ""; want = 1 }   # next line is a LABEL
    next
  }
  if (depth >= 2 && line ~ /^esac/ && line ~ /;;&?$|;&$/) { depth--; if (depth == 1) want = 1; next }
  if (depth >= 1 && line ~ /^esac/) {
    if (depth == 1) {
      flush_arm()
      if (has) for (i = 0; i < n; i++) printf "%s\t%s\t%s\n", FILENAME, labs[i], txts[i]
    }
    depth--; want = 0; next
  }
  if (depth < 1) next

  if (depth == 1 && want) {                   # THE SHELL SAID THIS IS A LABEL. No guessing.
    e = label_end(line)
    lbl = (e > 0) ? substr(line, 1, e) : ("UNPARSED " line)
    flush_arm()
    lab = lbl; buf = line
    if (lbl ~ /^\(?EXPIRED/) has = 1          # ANCHORED: !(EXPIRED)*) is not EXPIRED
    want = 0
    if (line ~ /;;&?$|;&$/) want = 1          # label and body on one line, arm already closed
    next
  }
  if (lab != "") buf = buf " " line           # BODY — at any depth, so a nested case is not lost
  if (depth == 1 && line ~ /;;&?$|;&$/) want = 1
}
