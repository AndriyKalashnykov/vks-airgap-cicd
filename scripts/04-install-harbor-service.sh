#!/usr/bin/env bash
# 04-install-harbor-service.sh — install Harbor as a Supervisor Service, end to end.
#
# Replaces scenario-1 Step 2's browser work AND its hand-editing of seven plaintext secrets:
#   vCenter UI -> Add New Service -> upload .yml -> Manage Service -> paste data-values
#
# Every secret is GENERATED here (gen_password / openssl), never typed by an operator and
# never defaulted to the vendor's published `Harbor12345`. The rendered values file holds
# them in cleartext for the duration of the request and is shredded on every exit path.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/vcenter.sh
. "${SCRIPT_DIR}/lib/vcenter.sh"
# shellcheck source=scripts/lib/state.sh
. "${SCRIPT_DIR}/lib/state.sh"
load_env

: "${HARBOR_URL:?HARBOR_URL is not set - the FQDN Harbor will serve on (bare host, no scheme)}"
: "${HARBOR_STORAGE_CLASS:?HARBOR_STORAGE_CLASS is not set - see: kubectl get storageclass}"
SRC_DIR="${VCF_CLI_SRC_DIR:-$HOME/Downloads/vcf}"

# The service definition and its data-values template are operator-supplied, entitled files.
DEF="$(find "$SRC_DIR" -maxdepth 1 -name 'supervisor-service-harbor-legacy-*.yml' 2>/dev/null | sort | tail -1)"
TPL="$(find "$SRC_DIR" -maxdepth 1 -name 'supervisor-service-harbor-data-values-*.yml' 2>/dev/null | sort | tail -1)"
[ -n "$DEF" ] || die "no supervisor-service-harbor-legacy-*.yml in $SRC_DIR (see docs/scenario-1.md Step 0)"
[ -n "$TPL" ] || die "no supervisor-service-harbor-data-values-*.yml in $SRC_DIR (see docs/scenario-1.md Step 0)"
log_info "service definition : $(basename "$DEF")"
log_info "data-values template: $(basename "$TPL")"

VALUES="$(mktemp)"; chmod 600 "$VALUES"
# if-then-else, NOT `A && B || C`: when shred EXISTS but FAILS, the `||` arm would still run and
# the file would be rm'd rather than shredded - silently weaker than it reads (SC2015).
cleanup() {
  if command -v shred >/dev/null 2>&1; then shred -u "$VALUES" 2>/dev/null || rm -f "$VALUES"
  else rm -f "$VALUES"; fi
  vc_logout
}
trap cleanup EXIT

# ── generate every [Required] secret ─────────────────────────────────────────────────────
# Lengths are CONTRACTUAL: secretKey must be exactly 16 chars and xsrfKey exactly 32 --
# Harbor rejects anything else at reconcile, long after the install "succeeds".
H_ADMIN="${HARBOR_PASSWORD:-$(gen_password)}"          # reuse an existing .env value if set
H_SECRETKEY="$(gen_password)"                                        # gen_password is 16 chars
H_XSRF="$(openssl rand -hex 16)"                                     # 16 bytes -> 32 hex chars
H_DBPASS="$(gen_password)"; H_CORE="$(gen_password)"
H_JOBSVC="$(gen_password)"; H_REGISTRY="$(gen_password)"
[ "${#H_SECRETKEY}" -eq 16 ] || die "internal: secretKey must be exactly 16 chars, got ${#H_SECRETKEY}"
[ "${#H_XSRF}" -eq 32 ]      || die "internal: xsrfKey must be exactly 32 chars, got ${#H_XSRF}"

# ── render ───────────────────────────────────────────────────────────────────────────────
# `change-it` appears FOUR times under different parents and each must become a DISTINCT
# value, so a global s/// is wrong. Track the current top-level key and replace in context.
awk -v host="$HARBOR_URL" -v sc="$HARBOR_STORAGE_CLASS" \
    -v adm="$H_ADMIN" -v skey="$H_SECRETKEY" -v xsrf="$H_XSRF" \
    -v dbp="$H_DBPASS" -v cor="$H_CORE" -v job="$H_JOBSVC" -v reg="$H_REGISTRY" '
  /^[A-Za-z][A-Za-z0-9_]*:/ { split($0, a, ":"); section = a[1] }
  /^hostname: yourdomain\.com$/            { print "hostname: " host; next }
  /^enableNginxLoadBalancer: false$/       { print "enableNginxLoadBalancer: true"; next }
  /^enableContourHttpProxy: true$/         { print "enableContourHttpProxy: false"; next }
  /^harborAdminPassword: /                 { print "harborAdminPassword: " adm; next }
  /^secretKey: /                           { print "secretKey: " skey; next }
  /^  xsrfKey: /                           { print "  xsrfKey: " xsrf; next }
  /^  password: change-it$/ && section=="database"   { print "  password: " dbp; next }
  /^  secret: change-it$/   && section=="core"       { print "  secret: " cor; next }
  /^  secret: change-it$/   && section=="jobservice" { print "  secret: " job; next }
  /^  secret: change-it$/   && section=="registry"   { print "  secret: " reg; next }
  { gsub(/insert-storage-class-name-here/, sc); print }
' "$TPL" > "$VALUES"

# ── assert the render actually landed ────────────────────────────────────────────────────
# This is the real guard, and it is a PROPERTY, not a line count: not one vendor placeholder
# may survive. A silently-unmatched pattern would otherwise ship a Harbor with the published
# default admin password, or no reachable ingress, and report success either way.
left="$(grep -cE 'yourdomain\.com|insert-storage-class-name-here|change-it|Harbor12345|0123456789ABCDEF' "$VALUES" || true)"
[ "$left" -eq 0 ] || {
  log_error "the data-values render left $left vendor placeholder(s) unreplaced:"
  grep -nE 'yourdomain\.com|insert-storage-class-name-here|change-it|Harbor12345|0123456789ABCDEF' "$VALUES" | sed 's/^/    /' >&2
  die "refusing to install Harbor with vendor placeholders - the template's key layout changed"
}
grep -q "^hostname: ${HARBOR_URL}$" "$VALUES" || die "hostname did not render"
grep -q '^enableNginxLoadBalancer: true$' "$VALUES" || die "the NGINX LoadBalancer toggle did not render"
log_info "rendered data-values: hostname=${HARBOR_URL} storageClass=${HARBOR_STORAGE_CLASS}, 7 secrets generated, 0 placeholders left"

# ── register + install ───────────────────────────────────────────────────────────────────
vc_login
MOID="$(vc_cluster_moid "${VKS_CLUSTER_COMPUTE:-}")"
[ -n "$MOID" ] || die "could not resolve the vSphere cluster moid; set VKS_CLUSTER_COMPUTE when vCenter has more than one cluster"
log_info "cluster: $MOID"

# NON-MUTATING: derives the id, version, type and validity WITHOUT registering.
CC="$(vc_ss_check_content "$DEF")"
SVC_TYPE="$(printf '%s' "$CC" | cut -d'|' -f1)"
SVC_ID="$(printf '%s'   "$CC" | cut -d'|' -f2)"
SVC_VER="$(printf '%s'  "$CC" | cut -d'|' -f3)"
SVC_STATUS="$(printf '%s' "$CC" | cut -d'|' -f4)"
# VALID_WITH_WARNINGS is what an ALREADY-REGISTERED service reports - it is not a rejection.
case "$SVC_STATUS" in
  VALID|VALID_WITH_WARNINGS) : ;;
  *) die "vCenter rejected $(basename "$DEF"): status=${SVC_STATUS:-unreadable} ($CC)" ;;
esac
# Only CARVEL_APPS_YAML makes the platform CREATE the PackageInstall that runs the operator.
# A CUSTOM_YAML registration publishes the Package and deploys NOTHING -- silently.
[ "$SVC_TYPE" = CARVEL_APPS_YAML ] || die "vCenter classifies $(basename "$DEF") as ${SVC_TYPE}, not CARVEL_APPS_YAML - it would publish a Package and deploy nothing"
[ -n "$SVC_ID" ] && [ -n "$SVC_VER" ] || die "checkContent returned no id/version ('$CC')"
log_info "service: ${SVC_ID} version ${SVC_VER} (${SVC_TYPE}, ${SVC_STATUS})"

if vc_ss_is_registered "$SVC_ID"; then
  log_info "${SVC_ID} is already registered in vCenter - skipping register (idempotent)"
else
  vc_ss_register "$DEF"; log_info "registered ${SVC_ID}"
fi

vc_ss_install "$MOID" "$SVC_ID" "$SVC_VER" "$VALUES"
log_info "install issued for ${SVC_ID}"

# ── publish what the rest of the flow needs ──────────────────────────────────────────────
# `admin` UNCONDITIONALLY, never "${HARBOR_USERNAME:-admin}": a freshly installed Harbor has
# only the built-in admin, so inheriting a robot name left over from a previous run is wrong
# twice -- it names an account that does not exist yet, and `robot$name` written unquoted makes
# the state overlay UNSOURCEABLE (`$name: unbound variable`). Step 7 sets the robot later.
# ONLY-IF-UNSET, exactly as 05-kind-up.sh:129-130 already does. PUBLISH ONLY WHAT WE PRODUCED.
#
# These two used to be unconditional, and both harms were measured:
#
#   * `H_ADMIN` is `${HARBOR_PASSWORD:-$(gen_password)}` — so when the operator already had a
#     password in .env we ECHOED IT BACK into the overlay. load_env sources the overlay LAST, so
#     that frozen copy then outranked .env AND the command line forever. `make harbor-admin-password`
#     could verify a fresh password against Harbor (http 200), write it to .env, and be discarded;
#     `make env-validate` returned 401 seconds later. Both commands were telling the truth about
#     different values. (Proof the copy was never generated: gen_password is 16 chars and the value
#     found on a real box was 32.)
#
#   * WORSE, and silent: `HARBOR_USERNAME admin` shadowed the least-privilege ROBOT that
#     22-harbor-robot.sh writes to .env — while 22 printed "the pipeline now runs as the ROBOT, not
#     as admin". That sentence was false on every real-lab box, and unlike the password case it does
#     not 401: the pipeline just runs as Harbor ADMIN, successfully, claiming otherwise.
#
# The guard makes the overlay contain, by construction, only values this script actually generated —
# which is the same rule the repo already applies in the other direction (never read back your own
# published state; see INGRESS_LB_IP_OVERRIDE and gitea_clone_url).
[ -n "${HARBOR_USERNAME:-}" ] || state_set HARBOR_USERNAME admin
[ -n "${HARBOR_PASSWORD:-}" ] || state_set HARBOR_PASSWORD "$H_ADMIN"
log_info "published HARBOR_USERNAME/HARBOR_PASSWORD to the state overlay (only the ones not already set)"
# `make harbor-service-status` DOES NOT EXIST — this line named it for months and nobody ran it.
# The real next step is to wait for the LoadBalancer ADDRESS, which is what the DNS record needs.
log_info "next: wait for its LoadBalancer address, then create that A record:"
log_info "        make show-dns-records DNS_RECORDS_WAIT_SECONDS=900"
