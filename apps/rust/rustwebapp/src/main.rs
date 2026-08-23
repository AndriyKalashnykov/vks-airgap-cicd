//! rustwebapp — the Rust sibling of the other five apps.
//!
//! Serves the SAME contract so the pipeline, the ingress and `make verify` treat every app
//! identically:
//!
//!   GET /         -> the landing page, whose greeting is the value we change to demo GitOps CD
//!   GET /healthz  -> liveness/readiness (k8s probes + the container HEALTHCHECK)
//!
//! THE SHARED-UI CONTRACT: the markup below is byte-identical (modulo blank lines) to every other
//! app's rendered page — `make check-ui-contract` renders all six and diffs them. Only the four
//! app-specific fields differ. Do not "improve" the markup here; change it in all six or not at all.
//!
//! AIR-GAP: dependencies are pre-fetched into apps/rust/rustwebapp/Dockerfile.builder's cargo
//! registry cache on the internet side, so the in-cluster build runs `cargo build --offline` and
//! reaches crates.io never. The binary is CGO-free and static, which is what lets the runtime image
//! be distroless/static — the same base gowebapp uses, so Rust adds a BUILD image only.
//!
//! Every operator-tunable value is env-driven with a documented default (mirrors .env.example).

use axum::{http::header, response::{Html, IntoResponse}, routing::get, Router};

/// The demo "deploy me" value. `make verify` rewrites THIS line with a unique marker, pushes it,
/// and asserts the marker appears on the deployed page — the same trick it plays on javawebapp's
/// application.yml and gowebapp's main.go. Keep it on one line, in this exact shape.
const DEFAULT_MESSAGE: &str = "Hello from vks-airgap-cicd";

#[derive(Clone)]
pub struct Page {
    pub app_name: String,
    pub message: String,
    pub version: String,
    pub commit: String,
}

/// Return the value of `key`, or `fallback` when unset/empty.
fn env(key: &str, fallback: &str) -> String {
    match std::env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => fallback.to_string(),
    }
}

/// Minimal escaping. Every field is interpolated into HTML and `make verify` injects a marker into
/// one of them; an unescaped '<' there would produce invalid markup and break the contract diff.
fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
        .replace('"', "&#34;").replace('\'', "&#39;")
}

pub fn render(p: &Page) -> String {
    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>{name} — VKS CI/CD demo</title>
    <style>
        :root {{ color-scheme: light dark; }}
        body {{
            font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
            margin: 0; min-height: 100vh; display: flex; align-items: center;
            justify-content: center; background: #0f172a; color: #e2e8f0;
        }}
        .card {{
            background: #1e293b; border-radius: 16px; padding: 2.5rem 3rem;
            box-shadow: 0 10px 40px rgba(0,0,0,.4); max-width: 40rem; width: 90%;
        }}
        h1 {{ margin: 0 0 .25rem; font-size: 1.4rem; color: #94a3b8; font-weight: 600; }}
        .message {{
            font-size: 2rem; font-weight: 700; margin: .5rem 0 1.5rem;
            color: #38bdf8; word-break: break-word;
        }}
        dl {{ display: grid; grid-template-columns: auto 1fr; gap: .4rem 1rem; margin: 0; }}
        dt {{ color: #64748b; font-weight: 600; }}
        dd {{ margin: 0; font-family: ui-monospace, "SFMono-Regular", Menlo, monospace; }}
    </style>
</head>
<body>
    <main class="card">
        <h1>{name}</h1>
        <p class="message">{msg}</p>
        <dl>
            <dt>Version</dt><dd>{ver}</dd>
            <dt>Commit</dt><dd>{commit}</dd>
        </dl>
    </main>
</body>
</html>
"#,
        name = esc(&p.app_name),
        msg = esc(&p.message),
        ver = esc(&p.version),
        commit = esc(&p.commit),
    )
}

/// Build the router. Split out from `main` so the tests exercise the REAL handlers — hermetic,
/// no network, no fixed port.
pub fn new_router(p: Page) -> Router {
    Router::new()
        .route("/healthz", get(|| async {
            ([(header::CONTENT_TYPE, "application/json")], r#"{"status":"UP"}"#).into_response()
        }))
        .route("/", get(move || {
            let body = render(&p);
            async move { Html(body).into_response() }
        }))
}

pub fn page_from_env() -> Page {
    Page {
        app_name: env("APP_NAME", "rustwebapp"),
        message: env("APP_MESSAGE", DEFAULT_MESSAGE),
        version: env("APP_VERSION", "dev"),
        commit: env("APP_COMMIT", "unknown"),
    }
}

#[tokio::main]
async fn main() {
    let p = page_from_env();
    let addr = format!("{}:{}", env("APP_BIND_HOST", "0.0.0.0"), env("APP_INTERNAL_PORT", "8080"));
    println!(r#"{{"level":"INFO","msg":"starting","app":"{}","addr":"{}"}}"#, p.app_name, addr);
    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    axum::serve(listener, new_router(p)).await.expect("serve");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p() -> Page {
        Page { app_name: "rustwebapp".into(), message: "marker-4711-hello".into(),
               version: "1.2.3".into(), commit: "abc1234".into() }
    }

    // The deployed page MUST render the message: `make verify` proves the whole GitOps loop by
    // pushing a unique marker into it and asserting the marker appears on the live page. If the
    // message stopped rendering, that check would be measuring nothing.
    #[test]
    fn index_renders_message_version_and_commit() {
        let out = render(&p());
        for want in ["marker-4711-hello", "1.2.3", "abc1234", "rustwebapp"] {
            assert!(out.contains(want), "missing {want}");
        }
    }

    #[test]
    fn html_significant_characters_are_escaped() {
        let mut q = p();
        q.message = "<script>x</script>".into();
        assert!(render(&q).contains("&lt;script&gt;"));
    }

    #[test]
    fn env_falls_back_when_unset_or_empty() {
        assert_eq!(env("VKS_DEFINITELY_UNSET_XYZ", "fb"), "fb");
    }

    // THE SHARED-UI CONTRACT PRODUCER (see scripts/check-ui-contract.sh). Writes the rendered page
    // to $UI_CONTRACT_OUT; a no-op when unset, so a normal `cargo test` is unaffected. The literals
    // must be IDENTICAL across all six apps AND MUTUALLY DISTINCT — distinctness is the only reason
    // a field SWAP (app_name rendered where version belongs) is caught by the diff.
    #[test]
    fn ui_contract_producer() {
        let Ok(out) = std::env::var("UI_CONTRACT_OUT") else { return };
        if out.is_empty() { return; }
        let page = Page { app_name: "APPNAME".into(), message: "MESSAGE".into(),
                          version: "VERSION".into(), commit: "COMMIT".into() };
        std::fs::write(&out, render(&page)).expect("write UI_CONTRACT_OUT");
    }
}
