#!/usr/bin/env bash
# fetch-ca.sh <endpoint> <out-file> [label] — fetch the CA that ISSUED a TLS endpoint's certificate,
# and PROVE the result actually verifies that endpoint.
#
# THE BUG THIS REPLACES (it was in `make fetch-harbor-ca` AND `make fetch-argocd-ca`):
#
#     openssl s_client -showcerts | openssl x509 -outform PEM > ca.crt
#
# `openssl x509` reads only the FIRST PEM block on its stdin — which is the SERVER LEAF, not the CA.
# So both targets wrote a leaf certificate into a file called "ca.crt" and handed it to crane
# (SSL_CERT_FILE), to podman (--cert-dir) and to in-cluster Kaniko (the harbor-ca ConfigMap) as a trust
# anchor. Go builds a chain from the leaf to a ROOT whose Subject matches the leaf's Issuer; a leaf is not
# that root, so verification fails with `x509: certificate signed by unknown authority` — AFTER the
# runbook has told the operator this step "handles both consumers for you".
#
# It survived because our KinD stand-in never runs it (06-install-harbor.sh mints the CA and writes
# HARBOR_CA_FILE directly), and because a Harbor that serves a SELF-SIGNED leaf happens to make leaf==CA,
# which papers over the defect in exactly the case we test. On a real lab, where cert-manager issues a
# leaf from a separate CA, it breaks.
#
# So: take the LAST certificate the server presents (its issuer), fall back to the leaf when the server
# presents a single self-signed cert, and then VERIFY — `openssl verify` must actually validate the leaf
# against what we wrote. We do not write a trust anchor we have not proven is one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# ⚠️ REQUIRED for ca_fingerprint / ca_pin_verdict below — os.sh does NOT pull tls.sh in. Without this
# line those calls are `command not found` (rc 127), which under `set -e` kills the script with no
# message at all. tls.sh has an idempotent load guard and no source-time side effects.
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"

EP="${1:?usage: fetch-ca.sh <endpoint> <out-file> [label]}"
OUT="${2:?usage: fetch-ca.sh <endpoint> <out-file> [label]}"
LABEL="${3:-endpoint}"

# ⚠️ VALIDATE THE LABEL BEFORE ANYTHING ELSE — it becomes a VARIABLE NAME (${LABEL^^}_CA_SHA256, read by
# indirect expansion). MEASURED 2026-08-05: `fetch-ca.sh <ep> <out> my-registry` died with
# `MY-REGISTRY_CA_SHA256: invalid variable name` at the indirect expansion — AFTER the CA had been written
# and BEFORE any refusal path, leaving a 1135-byte UNAUTHENTICATED 0644 anchor on disk. It FAILED OPEN,
# via the documented third argument. Checked here, where nothing has been written yet.
case "$LABEL" in
  ''|*[!A-Za-z0-9_]*) die "label '${LABEL}' is not usable: it becomes the variable name
  ${LABEL}_CA_SHA256, so it must contain only letters, digits and underscores." ;;
esac

hostport="$(printf '%s' "$EP" | sed -E 's#^https?://##; s#/.*##')"
host="${hostport%%:*}"; port="${hostport##*:}"; [ "$port" = "$host" ] && port=443

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log_info "fetching the ${LABEL} CA from ${host}:${port}"

# -showcerts prints the WHOLE chain the server sends. Keep it all; we choose from it deliberately.
openssl s_client -connect "${host}:${port}" -servername "$host" -showcerts </dev/null 2>/dev/null \
  > "${tmp}/chain.txt" \
  || die "could not connect to ${host}:${port} — is ${LABEL} reachable over HTTPS?"

# Split the chain into one file per certificate, in the order the server sent them (leaf first).
# ⚠️ `inc` is LOAD-BEARING — without it this splitter DESTROYS the certificate it just wrote.
# In awk, `print > f` holds the stream open, but after `close(f)` a later `> f` REOPENS IT
# TRUNCATED. The old catch-all `n && f { print > f }` kept matching the session text that
# s_client prints AFTER the last -----END CERTIFICATE-----, so each of those ~22 lines wiped
# and rewrote cert-NN.pem. MEASURED 2026-08-04: cert-01.pem ended up containing
# "--- / Server certificate / subject=… / issuer=…" and ZERO PEM, so `openssl x509` failed —
# and because line 58 assigns it in `$( )`, `set -e` killed the script with NO message at all,
# never reaching the informative die below. Gate printing on being INSIDE a certificate.
awk -v d="$tmp" '
  /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/cert-%02d.pem", d, n); inc = 1 }
  inc { print > f }
  /-----END CERTIFICATE-----/   { close(f); inc = 0 }
' "${tmp}/chain.txt"

n="$(find "$tmp" -maxdepth 1 -name 'cert-*.pem' | wc -l | tr -d ' ')"
[ "$n" -ge 1 ] || die "${host}:${port} presented NO certificate (is it really serving TLS?)"

leaf="${tmp}/cert-01.pem"
last="$(find "$tmp" -maxdepth 1 -name 'cert-*.pem' | sort | tail -1)"

# `|| true` is REQUIRED, not defensive noise: under `set -euo pipefail` a failing `openssl x509`
# makes the ASSIGNMENT non-zero and kills the script SILENTLY — no message, just rc=1 — so every
# actionable die below becomes unreachable exactly when it is needed. MEASURED 2026-08-04.
subj="$(openssl x509 -in "$last" -noout -subject 2>/dev/null | sed 's/^subject=//' || true)"
issu="$(openssl x509 -in "$last" -noout -issuer  2>/dev/null | sed 's/^issuer=//' || true)"
[ -n "$subj" ] && [ -n "$issu" ] || die "could not parse the certificate ${host}:${port} presented.
  This is usually a DEFECT IN THIS SCRIPT (the chain splitter), not in the server — check that
  ${last} contains a PEM block. Re-check with: openssl s_client -connect ${host}:${port} -showcerts"

if [ "$n" -eq 1 ]; then
  # A single cert. It is a legitimate trust anchor ONLY if it is self-signed (subject == issuer);
  # otherwise the server is not sending its issuer and we cannot derive the CA from the wire at all.
  if [ "$subj" != "$issu" ]; then
    # ⚠️ THIS die IS SHARED. Makefile calls this script for BOTH harbor and argocd, and there is one
    # die here — so any Harbor-specific recipe printed below would also print on an ArgoCD CA failure,
    # naming a Harbor UI page that has nothing to do with what just failed. The die stays GENERIC and
    # the per-service recipe lives in docs/scenario-1.md, which is already per-service.
    #
    # ⚠️ AND THE ORDER OF THE TWO ROUTES IS THE WHOLE POINT. The scriptable route (reading Harbor's
    # `harbor-ca-key-pair` Secret) ALSO returns the CA's PRIVATE SIGNING KEY: measured, it is
    # kubernetes.io/tls with ca.crt(1540)/tls.crt(1540)/tls.key(2236), sha256(ca.crt)==sha256(tls.crt),
    # self-signed CA:TRUE — and Kubernetes RBAC has no field-level read, so whoever can run it can MINT
    # a certificate every consumer of this file trusts. The UI route needs only a service login and no
    # Kubernetes access at all. Printing the privileged route first, with a disclosure underneath, IS
    # the laundering: a disclosure only changes behaviour when a CHEAPER path sits beside it.
    die "${host}:${port} presents ONE certificate that is NOT self-signed (subject != issuer).
  Its CA is not on the wire, so it cannot be fetched from here.
    subject: ${subj}
    issuer:  ${issu}

  Get the issuing CA the cheap way FIRST — it needs only a login to ${LABEL}, no Kubernetes access
  and no cluster RBAC: open ${LABEL}'s own UI and download its registry/root certificate.

  Only if that is unavailable, ask the platform team for the issuing CA directly. There is also a
  read-it-from-the-cluster route, but it costs an ADMIN-level grant (the Secret carries the CA's
  private key, not just the certificate) — docs/scenario-1.md §8 documents it, and what it costs.

  Either way, point ${LABEL^^}_CA_FILE at the file you obtain."
  fi
  log_info "server presents a single SELF-SIGNED certificate — it is its own CA"
else
  log_info "server presents a chain of ${n}; taking the last (the issuer) as the CA"
fi

# ⚠️ STAGE TO A TEMP CANDIDATE. $OUT IS NOT TOUCHED UNTIL EVERY CHECK HAS PASSED.
# MEASURED 2026-08-05: this used to `cp "$last" "$OUT"` HERE, ~50 lines before the first check, and each
# refusal path then did `rm -f "$OUT"`. So planting a good CA at $OUT and triggering a MISMATCH left
# `ls: cannot access` — DETECTING AN INTERCEPTOR DESTROYED THE OPERATOR'S GOOD ANCHOR. Worse, HARBOR_CA_FILE
# defaults into ./secrets/, which is gitignored and untracked, so it is unrecoverable; and the die said
# "refusing to WRITE a trust anchor" while having already written and deleted one.
# A refusal must be a NO-OP on the operator's filesystem, not a rollback.
CAND="${tmp}/candidate.crt"
cp "$last" "$CAND"

# ---- CONSISTENCY, WHICH IS NOT AUTHENTICITY. -----------------------------------------------------------
# This check is worth keeping and it is NOT proof of anything about WHO we are talking to. It catches a
# broken EXTRACTION (we grabbed the wrong PEM out of the chain), and nothing else.
#
# ⚠️ MEASURED 2026-08-05 with a live oracle: two independent self-signed certs for the same CN, serve the
# EVIL one, run this script unmodified -> it wrote the EVIL CA and printed "VERIFIED". A MITM's chain is
# self-consistent BY CONSTRUCTION, so verifying a leaf against an issuer taken off the SAME WIRE can only
# ever succeed. Worse, in the n==1 branch $OUT is copied FROM the leaf, so this reduces to verify(X,X) --
# `openssl verify -CAfile ss.crt ss.crt` -> OK, rc=0 for ANY self-signed cert, attacker's included.
# The word "VERIFIED" was the laundering: it is the sentence an operator quotes when their security team
# asks how the anchor was validated. Only the fingerprint comparison below can answer that.
if openssl verify -CAfile "$CAND" "$leaf" >/dev/null 2>&1; then
  if [ "$n" -eq 1 ]; then
    log_info "SELF-SIGNED — self-consistent by construction, NOT authenticated"
  else
    log_info "chain is internally consistent — note an attacker supplies BOTH halves of it"
  fi
else
  die "the certificate we extracted does NOT verify ${host}'s leaf — refusing to write a trust anchor that
  does not work (it would fail later, inside crane/Kaniko, as 'x509: certificate signed by unknown
  authority', pointing you at the wrong thing). Ask the platform team for ${LABEL}'s issuing CA."
fi

# ---- AUTHENTICITY: an out-of-band fingerprint is the ONLY thing that provides it. -----------------------
# ⚠️ PIN THE CA, NOT THE LEAF. lib/tls.sh keeps the CA stable across runs (3650d) and REGENERATES the leaf
# every run (825d), so a leaf pin would false-fire on every rebuild. And 30-vks-login.sh records a MEASURED
# incident where a message compared a stored CA fingerprint against a live LEAF fingerprint -- two
# different objects that can never match. Every digest we print is therefore LABELLED with its object.
UPPER="$(printf '%s' "$LABEL" | tr '[:lower:]' '[:upper:]')"
# ONE definition of "compute the digest / compare it to a pin", in lib/tls.sh, shared with
# 30-vks-login.sh. The normalisation ("strip colons, lowercase, is it 64 hex") is the drift-prone
# part; two copies of it would diverge, which is the class check-*-alignment gates exist for.
fp_colon="$(ca_fingerprint "$CAND")" \
  || { die "could not compute a SHA-256 fingerprint for the CA we extracted."; }
fp_bare="$(printf '%s' "$fp_colon" | tr -d ':' | tr '[:upper:]' '[:lower:]')"

# ⚠️ THE PIN MUST BE PASSED EXPLICITLY BY THE CALLER. This script does NOT call load_env, and the Makefile's
# `-include .env` creates MAKE variables, NOT environment. MEASURED: with HARBOR_CA_SHA256 set in .env, a
# recipe sees make-var=[AA:BB:CC] while the script it invokes sees []. So a pin written to .env alone is
# SILENTLY INERT -- the operator would conclude pinning is broken and stop using it. The Makefile recipe
# exports it; see the `fetch-harbor-ca` / `fetch-argocd-ca` targets.
pin_var="${UPPER}_CA_SHA256"
# Indirect expansion, NOT `eval "pin=\${${pin_var}}"`. Same result, and it avoids evaluating a
# constructed variable name — plus shellcheck can SEE this one (an eval is opaque to it, which
# cost an SC2154 on the assignment below).
pin="${!pin_var:-}"

# ⚠️ `verdict=0; cmd || verdict=$?` — NOT `cmd; verdict=$?`. Under `set -e` a non-zero return from
# ca_pin_verdict (which is its NORMAL way of reporting a mismatch) would kill the script before the
# case could run, so every actionable message below would be unreachable exactly when it is needed.
# Same trap the `|| true` on the subject/issuer reads above exists for.
verdict=0; ca_pin_verdict "$CAND" "$pin" || verdict=$?

# 4 = SET BUT UNUSABLE, and it must never collapse into 3 (= not set). MEASURED 2026-08-05: an earlier
# version normalised first and branched on the result, so ':::' became empty and took the
# trust-on-first-use path — the operator supplied a pin and it was silently ignored. Unattended that
# still refused (safe by accident); on a TERMINAL they would have been asked y/N and would have
# believed they were pinned.
if [ "$verdict" -eq 4 ]; then
  die "${pin_var} is set but is not a SHA-256 digest — REFUSING (a malformed pin must never silently
  downgrade to trust-on-first-use).

    got:      '${pin}'
    expected: 64 hex characters, with or without colons, e.g.
              AB:CD:...  or  abcd...

  Recompute it from the CA file the platform team gave you:
    openssl x509 -in <their-ca.crt> -noout -fingerprint -sha256"
fi

if [ "$verdict" -ne 3 ]; then
  if [ "$verdict" -eq 0 ]; then
    log_info "CA fingerprint MATCHES the expected value from ${pin_var}"
  else
    die "CA FINGERPRINT MISMATCH for ${host}:${port} — REFUSING to write a trust anchor.

    expected (${pin_var}): $(printf '%s' "$pin" | tr -d ': ' | tr '[:upper:]' '[:lower:]')
    served by ${host}:     ${fp_bare}

  Either the endpoint's CA was legitimately rotated, or something is intercepting this connection.
  Do NOT proceed by clearing ${pin_var}. Confirm the correct fingerprint with whoever operates
  ${LABEL} — by a channel that is not this connection — and re-run."
  fi
else
  # NO PIN. This is trust-on-first-use, so make the operator SEE it and CONSENT to it.
  # ⚠️ The consent text names what a wrong anchor costs, because it is NOT just image trust:
  # lib/harbor.sh writes `user = "$HARBOR_USERNAME:$HARBOR_PASSWORD"` into a curl -K config and every
  # harbor_api call submits it over the connection this file anchors; 22-harbor-robot.sh mints the robot
  # with the ADMIN credential over the same channel and the robot secret returns on it. A MITM here
  # therefore harvests credentials, not merely serves bad images.
  # ⚠️ STDERR, NOT STDOUT — including the prompt. MEASURED 2026-08-05: with the block on stdout, running
  # this as `make fetch-harbor-ca >log` (or piping to tee) hid the ⚠️ banner, the digest, the
  # credential-disclosure AND the question, leaving an interactive run as a SILENT HANG on a prompt the
  # operator cannot see. log_info/die already go to stderr; the consent text is operator output too.
  exec 3>&2
  printf '\n' >&3
  printf '  ⚠️  NOT AUTHENTICATED. This CA was taken off the same connection it is meant to protect,\n' >&3
  printf '      so nothing here proves it belongs to %s rather than to something intercepting it.\n' "$host" >&3
  printf '\n' >&3
  printf '      CA SHA-256: %s\n' "$fp_colon" >&3
  printf '                  %s\n' "$fp_bare" >&3
  printf '\n' >&3
  printf '      Anything trusting this file will submit %s credentials over it.\n' "$LABEL" >&3
  printf '      Confirm the digest with whoever operates %s, by some channel OTHER than this one.\n' "$LABEL" >&3
  printf '\n' >&3
  if [ -t 0 ]; then
    printf '  Does that digest match what they told you? [y/N] ' >&3
    ans=''; read -r ans || true
    case "$ans" in
      y|Y|yes|YES) log_info "operator confirmed the fingerprint out of band" ;;
      *) die "not confirmed — no trust anchor written. Re-run with ${pin_var}=<digest> once you have it." ;;
    esac
  else
    die "refusing to write an unauthenticated trust anchor with no terminal to confirm it on.
  Pass the expected digest explicitly:  make fetch-${LABEL}-ca ${pin_var}=<sha256>
  (No make target depends on this one and no CI workflow invokes it — still true, re-checked.
  ⚠️ ONE automated path DOES reach it now: scenario-2 Step 2 is a walked block, and the walker is
  non-TTY. That is deliberate and it does not fire in practice, because Step 2 asks whether the CA
  is already present FIRST and the walk's driver stages it — so the walk takes the have-it-already
  branch and never gets here. If it ever does get here, the walk SHOULD stop: an unattended run
  pinning whatever answered is exactly what this refuses, and a green walk that pinned a stranger's
  certificate would be worse than a red one.)"
  fi
fi

# ---- ONLY NOW does the operator's filesystem change. ---------------------------------------------------
# PUBLIC trust material: 0644, always. A 0600 CA is unreadable by a container user with a different uid,
# and the failure it produces ("error adding trust anchors from file") names TRUST, not PERMISSIONS.
mkdir -p "$(dirname "$OUT")"
install -m0644 "$CAND" "$OUT" || die "could not write ${OUT}"

printf 'wrote %s\n' "$OUT"
printf '  CA SHA-256: %s\n' "$fp_colon"
# ⚠️ Say WHICH of the two it is. Without this the success text reads identically whether the digest was
# checked against an out-of-band value or merely consented to, and a reader scanning for "did this get
# verified?" would take the second for the first.
if [ "$verdict" -eq 0 ]; then
  printf '  AUTHENTICATED against %s\n' "$pin_var"
else
  printf '  ⚠️  NOT AUTHENTICATED — accepted on your confirmation alone. Set %s to make this a check.\n' "$pin_var"
fi
printf '  set it in .env, e.g.  %s_CA_FILE=%s\n' "$UPPER" "$OUT"
