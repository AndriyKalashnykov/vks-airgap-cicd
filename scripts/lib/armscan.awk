# armscan.awk — emit one record per ARM of every `case` block that dispatches on a token-expiry
# verdict, for the SSO-lockout control in test-creds-show.sh.
#
# ⚠️ THE BLOCK SET IS DERIVED, NEVER HAND-TYPED. check-classifier-consumers.sh:14 records the rule
# verbatim: "a second hand-typed list is the same rot one level up." A hand-typed 2-element list
# MISSED a third consumer that had been in the same file all along, and the resulting control was
# byte-identically green while an arm named the SSO command. A consumer block is anything whose
# arms include an EXPIRED label — that is what makes it a token-expiry dispatcher.
#
# Record: <file>\t<label>\t<arm text, comments stripped, newlines collapsed>
FNR == 1 { depth = 0; n = 0; has = 0; lab = ""; buf = "" }   # per-FILE reset; without it one
                                                             # stray esac desyncs every later file
{ line = $0
  sub(/^[[:space:]]+/, "", line)
  if (line ~ /^#/) next                    # a COMMENT is not code — the false-RED class this
                                           # repo already recorded once (test-creds-show.sh:1321)
  # ⚠️ A ONE-LINE `case ... in ... esac` opens and closes on the SAME line. A naive depth counter
  # increments and never decrements, so every later block in the file is seen at depth>1 and is
  # SILENTLY DROPPED. MEASURED: creds.sh has 5 of them, and they hid one of its two consumer
  # blocks — the control then reported ok while covering two thirds of the arms.
  # ⚠️ OPEN AND CLOSE MUST MATCH THE SAME SET OF LINES. `depth++` once required a quoted `$VAR`
  # subject while `depth--` fired on ANY `esac`, so `case "${VAR}" in`, `case "$1" in` and
  # `case "$(f)" in` were closers with no opener — each one desyncs every later block in the file.
  # A one-line `case ... in ... esac` opens and closes on the same line, so it must not touch
  # depth — but it is still part of the enclosing arm's BODY and can carry the remedy. Skipping it
  # outright emptied the arm, which is the same silence the fall-through above was removed for.
  if (line ~ /^case[[:space:]]/ && line ~ /esac[[:space:]]*(;;)?[[:space:]]*(#.*)?$/) {
    if (lab != "") buf = buf " " line
    next
  }
  if (line ~ /^case[[:space:]]/) {
    depth++; if (depth == 1) { n = 0; has = 0; lab = ""; buf = "" }
    next
  }
  if (depth >= 1 && line ~ /^esac/) {
    if (depth == 1) {
      if (lab != "") { labs[n] = lab; txts[n] = buf; n++ }
      if (has) for (i = 0; i < n; i++) printf "%s\t%s\t%s\n", FILENAME, labs[i], txts[i]
    }
    depth--; next
  }
  # ⚠️ ACCUMULATE AT ANY DEPTH. `if (depth != 1) next` dropped the body of a nested `case`, so an
  # arm whose remedy lived inside one emitted EMPTY text and could prescribe the bind unseen
  # (creds.sh:873 already uses the idiom). Only LABEL RECOGNITION is depth-1; TEXT is not.
  if (depth != 1) { if (lab != "") buf = buf " " line; next }
  # ⚠️ A LABEL THE CLASS REJECTS IS EMITTED AS `UNPARSED`, NEVER MERGED. Merging it appended the
  # line to the PRECEDING arm's buffer — and EXPIRED is the first arm in every consumer, so a new
  # arm written after it inherited the one exempting label. MEASURED: 10 of 12 label spellings were
  # false GREEN, isolated to a single character (`REVOKEDSOON*)` caught, `REVOKED-SOON*)` not), and
  # the arm COUNT never moved, so the floor could not see it either. UNPARSED sorts as
  # not-EXPIRED downstream, so an unrecognised label now fails SAFE.
  # ⚠️ THERE IS NO FALL-THROUGH. Every label-shaped line becomes a RECORD — recognised, or
  # `UNPARSED`. Three successive rounds each answered a refutation by adding ANOTHER FILTER in
  # front of a silent merge (a character class, then a whitespace test), and each new filter
  # re-opened the previous hole somewhere else: `"REVOKED"*)` and `REVOKED* )` still merged into
  # the PRECEDING arm and inherited EXPIRED, the one exempting label. The disease was never the
  # filter's contents — it was that rejecting a label meant SILENCE.
  #
  # The candidate test is `^[^(]*\)`: a label has no `(` before its `)`. PROSE does
  # (`printf 'the token has NOT expired (valid until %s)`), which is what a weaker test misread as
  # a label — so this one line replaces the whitespace filter it was patched with.
  if (line ~ /^[^(]*\)/ && line !~ /^\$\(/ && line !~ /^\|\|/) {
    lbl = line; sub(/\).*$/, ")", lbl)
    if (lab != "") { labs[n] = lab; txts[n] = buf; n++ }
    lab = (lbl ~ /^[A-Za-z_*|()'"\t -]+\)$/) ? lbl : ("UNPARSED " lbl)
    buf = line; has = has || (lbl ~ /EXPIRED/)
    next
  }
  if (lab != "") buf = buf " " line
}
