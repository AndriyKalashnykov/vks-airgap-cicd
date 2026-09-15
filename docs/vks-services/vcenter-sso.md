# vCenter Single Sign-On — lockout & the admin account

The living, graded record of the vCenter SSO **account-lockout** facts this repo relies on. Corrects
the long-standing "SSO locks out PERMANENTLY after 3 failed attempts" claim (B733), which was the
vCenter **appliance-local root** number, not SSO.

Provenance grades: `lab-verified` (measured on this lab), `9.1-doc` (Broadcom `/9-1/`, raw HTML),
`8.0-doc-inferred-for-9.1`, `KB`, `community`.

## The default SSO lockout policy

| Fact | Value | Grade | Source |
|---|---|---|---|
| Max failed attempts before lockout | **5** | `lab-verified` + `9.1-doc` | live `vmwPasswordChangeMaxFailedAttempts` (below); 9.1 security guide `vcenter-server-password-requirements-and-lockout-behavior` "five consecutive failed attempts in three minutes" |
| Failure counting interval | **180 s (3 min)** | `lab-verified` + `9.1-doc` | live `vmwPasswordChangeFailedAttemptIntervalSec`; same 9.1 page |
| Auto-unlock interval | **300 s (5 min)** — the account **unlocks itself** | `lab-verified` + `9.1-doc` | live `vmwPasswordChangeAutoUnlockIntervalSec`; same 9.1 page |
| "Unlock time 0" | means an admin must unlock **manually** — NOT the default | `9.1-doc` | 9.1 authentication guide `edit-lockout-policy-sso-on-prem` |
| The attributes govern failed **logins** (not only password changes) | yes | `9.1-doc` + `community` | 9.1 UI wording; vmdir/Lightwave source counts failed binds |

> **Gating:** this table uses a prose `Grade`/`Source` pair, not the `Confidence` + `[src:]` token
> shape `check-vks-provenance` enforces on the sibling docs, so it is a **documented phase-2 residual**
> (the gate's header scopes prose claims out). Not converted because the 9.1-doc rows would need full
> `url=` tokens this session did not fetch, and a fabricated citation is worse than the gap; the
> lab-measured rows ARE reproducible via the LDAPS read below.

### MEASURED live (do not re-derive; re-read if the lab is rebuilt)

2026-09-15, vCenter **9.1.0.0300**, authenticated LDAPS bind as
`cn=Administrator,cn=Users,dc=vsphere,dc=local` to `ldaps://vcsa.env1.lab.test:636`, base
`cn=password and lockout policy,dc=vsphere,dc=local` (positive control: the domain object returned a
`dn:`, so the bind was authenticated, not the anonymous vacuous-green case):

```text
vmwPasswordChangeMaxFailedAttempts:        5
vmwPasswordChangeFailedAttemptIntervalSec: 180
vmwPasswordChangeAutoUnlockIntervalSec:    300
```

Matches the lab's earlier 2026-08-04 reading and the documented 9.1 default — this lab is unhardened.
Read-only; a correct admin bind spends no failed attempt (and the admin account is exempt anyway).

## `administrator@vsphere.local` is EXEMPT by default

Stated on three separate 9.1 pages (`9.1-doc`, raw HTML):

- authentication guide, `edit-lockout-policy-sso-on-prem`: *"The lockout policy applies only to user
  accounts, not to system accounts such as `administrator@vsphere.local`."*
- security guide, lockout-behavior page: *"The vCenter Single Sign-On domain administrator,
  `administrator@vsphere.local` by default, is not affected by the lockout policy. The user is affected
  by the password policy."*
- password-policy page: *"The administrator account (`administrator@vsphere.local`) does not get locked
  out nor does its password expire."*

**But treat every SSO password as lockable in operator output.** vCenter **9.1.1.0** adds an opt-in
vCenter API (`enable_lockout_policy`) that removes the exemption; a hardened or third-party lab may also
set a stricter policy or `unlock=0`. So the exemption is a *default*, not a guarantee — hence
`make creds` says "can lock", never "is exempt". (`9.1-doc`, 9.1.1.0 release notes; the endpoint is
`PATCH` on the SSO-admin password-policy path.)

## The "3 attempts / permanent" figure is a DIFFERENT account

The vCenter **appliance-local** `root`/OS accounts use PAM `faillock` (8.0 U2+): `deny=3`, root
auto-unlocks after 300 s, other local OS accounts do **not** auto-unlock. This is the source of the old
"3 / permanent" claim; it is **not** the SSO policy. (`9.1-doc` `default-password-requirements-for-vcf-components`;
KB 394828, `8.0-doc-inferred-for-9.1`.) One KB (326186, scoped 7.x/8.x) says the SSO admin locks after
3 — it contradicts the 9.1 docs and matches the appliance `deny=3`, so it likely conflates the two.

## Residual (not settled, and why)

- Whether a failed `kubectl vsphere login` / `vcf context create` increments the **SSO** counter for a
  non-admin user is `UNVERIFIED` in primary docs (a strong inference: the auth proxy forwards to SSO).
  It is **moot for `administrator@vsphere.local`** (exempt), and not safely testable without spending
  real attempts on a throwaway user. The repo's discipline — never retry a rejected password blind —
  is correct regardless.
