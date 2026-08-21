# CI/CD

<br>

GitHub Actions (`.github/workflows/ci.yml`) runs on push to `main`, tags `v*`, pull requests, `workflow_dispatch`, and a **weekly schedule** (Mondays). The schedule is not decoration: it is the only trigger that runs the full `static-check`, so it is what makes the row below conditionally true.

| Job | Runs | Purpose |
|-----|------|---------|
| **changes** | always | `dorny/paths-filter` classifies the diff into `code` / `docs` |
| **static-check** | if `code` changed | **PR / push to main:** `make static-check-pr` — lint, manifest validation, app tests, fast script tests. ⚠️ **NOT `sec`** — trivy-fs and trivy-config do **not** gate a PR (`ci.yml:349` picks the target by `github.event_name`; `sec` is absent from `static-check-pr`, measured). **Weekly `schedule` only:** the full `make static-check`, which adds `sec`. gitleaks is unaffected — the always-on `secrets` job below runs it on every PR. |
| **docs-lint** | if `docs` changed | `make docs-lint` — markdownlint + `diagrams-check` (PNG drift vs `.puml`) |
| **static-check-fast** | **always** | `make static-check-fast` — the cheap half (alignment / doc / env gates, no mise toolchain). Unconditional **on purpose**: these are the gates most likely to be blinded by a docs-only change |
| **secrets** | **always** | gitleaks over history **and** the working tree. Unconditional, and on a docs-only PR it is effectively the whole gate — a `$PWD` mount or a credential written name-then-colon-then-value in prose reddens it |
| **diagrams-check** | if `diagrams` changed | committed PNGs must match their `.puml` source |
| **ci-pass** | always | Aggregator; the single required status check — green only if the needed jobs passed |

Locally, `make ci` runs `static-check` + `docs-lint` + `diagrams-check`, and `static-check` pulls in
`sec` (gitleaks, trivy-fs, trivy-config) plus `static-check-fast`.

⚠️ **A PR does NOT run everything `make ci` does.** `static-check` and `static-check-fast` are
**separate CI jobs**, so a change can pass the composite locally and still redden the fast half —
measured 2026-08-21, when `check-ns-chokepoint` failed as a PR job while the full `static-check`
passed. Run `env -u GOROOT make static-check` locally before relying on a green.

---

[← back to the README](../README.md)
