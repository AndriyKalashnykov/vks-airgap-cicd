#!/usr/bin/env bash
# scripts/check-doc-greeting-paths.sh — every file path the demo walkthrough tells an operator to
# edit must EXIST and still contain the greeting it says to change.
#
# WHY. docs/demo-walkthrough.md is the hand-driven version of `make verify`, and Step 2 names a
# per-app file. That table is an enumerated list of paths OUTSIDE the file that owns them, so it
# rots the first time an app is restructured — and it rots SILENTLY, because nothing executes a
# document. The operator finds out by navigating Gitea to a path that does not exist.
#
# It already had rotted once: the walkthrough named ONLY javawebapp's
# `src/main/resources/application.yml` while the repo shipped SIX apps whose greetings live in
# main.go, server.js, app.py, src/main.rs and Program.cs. `make creds-show` lists all six as equals,
# so five of six readers were sent to a path that does not exist. The doc was not part of the
# six-apps sweep that fixed eight other documents.
#
# Offline, no cluster, no network — it reads the table and stats the files.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${REPO_ROOT}/scripts/lib/apps.sh"

DOC="${REPO_ROOT}/docs/demo-walkthrough.md"
[ -f "$DOC" ] || die "check-doc-greeting-paths: ${DOC} is missing"

# The marker the table promises the operator will find in each file. Single-sourced here so a change
# to the demo greeting surfaces as one edit, not six.
GREETING="${DEMO_GREETING:-Hello from vks-airgap-cicd}"

fail=0; n=0
# The set of REGISTERED app names, used to decide which table rows are ours. Deriving this beats
# any shape heuristic: the document contains OTHER tables (the TaskRun one), and a first attempt
# that filtered by "looks like a row" parsed `| TaskRun | Does |` as an app, called app_src on it,
# and killed the script mid-run. A row is ours iff its first cell is a name the registry knows.
_known=" $(app_names | tr '\n' ' ')"

# ⚠️ ONLY THE FIRST APP-ROW TABLE. The walkthrough now carries a SECOND per-app table — the
# DECLARED-VERSION bump (pom.xml / package.json / Cargo.toml / main.go / app.py / .csproj) — and its
# rows have the identical shape. Without this stop the gate stats those files too and fails with
# "pom.xml exists but no longer contains 'Hello from vks-airgap-cicd'", which is TRUE and irrelevant:
# a pom is not where a greeting lives. MEASURED when the version table landed: 4 false REDs.
# Keyed on the block ENDING (a non-app row after we have seen app rows), not on a heading string or
# a row count — a heading is prose that moves, and a count would silently pass if a row were dropped.
_seen_block=0
# Rows look like:  | `gowebapp` | `main.go` | `const defaultMessage = "..."` |
while IFS='|' read -r _ app file _rest; do
  app="$(printf '%s' "$app" | tr -d ' `')"
  file="$(printf '%s' "$file" | tr -d ' `')"
  case "$_known" in
    *" ${app} "*) _seen_block=1 ;;
    *) [ "$_seen_block" = 1 ] && break; continue ;;
  esac
  [ -n "$file" ] || continue
  n=$((n+1))
  src="$(app_src "$app" 2>/dev/null || true)"
  if [ -z "$src" ]; then
    log_error "  ${app}: named in the walkthrough table but NOT in the app registry"
    fail=1; continue
  fi
  p="${src}/${file}"
  if [ ! -f "$p" ]; then
    log_error "  ${app}: the walkthrough sends the operator to '${file}', which does not exist under ${src#"${REPO_ROOT}"/}"
    fail=1
  elif ! grep -qF "$GREETING" "$p"; then
    log_error "  ${app}: ${file} exists but no longer contains '${GREETING}' — the walkthrough's Step 2 edit is stale"
    fail=1
  else
    log_info "  ok    ${app}: ${file} exists and carries the greeting"
  fi
done < "$DOC"

# EVERY app must appear. A row silently DROPPED is the rot this exists to catch, and a
# per-row-only check passes over it — the table would just get shorter.
want=0
while read -r a; do [ -n "$a" ] || continue; want=$((want+1))
  grep -qF "\`${a}\`" "$DOC" || { log_error "  ${a}: in the app registry but MISSING from the walkthrough table"; fail=1; }
done < <(app_names)

# ---- second assertion: a GENERIC instruction must not name a CONCRETE app --------------------
# The rest of the walkthrough is written with `<app>` placeholders so all six readers can follow it.
# One cell of the Step-3 TaskRun table said "writes the new tag back into `javawebapp-deploy`" while
# its three siblings said `<app>` — so five of six readers were told the wrong repo. Nothing could
# see it: check-app-hardcodes deliberately excludes docs/ (this repo's policy is that prose MAY name
# an instance), and the Step-2 table above legitimately names all six.
#
# So the rule is POSITIONAL, not lexical: an app name is allowed ONLY in a Step-2 table row (a line
# whose FIRST cell is that app) or on the one line that deliberately introduces the example. Every
# other occurrence is a placeholder someone left concrete.
#
# MEASURED on the healthy doc: 7 occurrences, 7 allowed -> false-RED 0. RED on demand: put
# `javawebapp-deploy` back into the deploy-update row and this fires.
EXAMPLE_LINE='The examples walk'
stray=0
occ=0
while IFS= read -r line; do
  case "$line" in *"$EXAMPLE_LINE"*) continue ;; esac
  while read -r a; do
    [ -n "$a" ] || continue
    case "$line" in *"$a"*) ;; *) continue ;; esac
    occ=$((occ+1))
    # allowed: a table row whose FIRST cell is this app (leading spaces permitted)
    case "$line" in *"| \`${a}\` |"*) continue ;; esac
    log_error "  a GENERIC instruction names the concrete app '${a}':"
    log_error "    ${line}"
    log_error "    use the <app> placeholder — five of six readers follow a different app"
    stray=$((stray+1)); fail=1
  done < <(app_names)
done < "$DOC"
log_info "check-doc-greeting-paths: ${occ} app-name occurrence(s) outside the example line, ${stray} stray"

log_info "check-doc-greeting-paths: ${n} table row(s) checked against ${want} registered app(s)"
[ "$n" -eq "$want" ] || { log_error "  row count ${n} != app count ${want} — the table and the registry disagree"; fail=1; }
if [ "$fail" -eq 0 ]; then echo "check-doc-greeting-paths: OK"; else echo "check-doc-greeting-paths: FAILED"; exit 1; fi
