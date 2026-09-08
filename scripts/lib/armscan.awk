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
  if (line ~ /case[[:space:]]+"?\$[A-Za-z_][A-Za-z_0-9]*"?[[:space:]]+in/ && line ~ /esac[[:space:]]*$/) next
  if (line ~ /^case[[:space:]]+"?\$[A-Za-z_][A-Za-z_0-9]*"?[[:space:]]+in/) {
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
  if (depth != 1) next
  if (line ~ /^[^(]*\)/ && line !~ /^\$\(/ && line !~ /^[[:space:]]*\|\|/) {
    lbl = line; sub(/\).*$/, ")", lbl)
    if (lbl ~ /^[A-Za-z_*"'\''|() \t]+\)$/) {
      if (lab != "") { labs[n] = lab; txts[n] = buf; n++ }
      lab = lbl; buf = line; has = has || (lbl ~ /EXPIRED/)
      next
    }
  }
  if (lab != "") buf = buf " " line
}
