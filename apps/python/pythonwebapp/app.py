"""pythonwebapp — the Python sibling of the other five apps.

Serves the SAME contract so the pipeline, the ingress and `make verify` treat every app
identically:

    GET /         -> the landing page, whose greeting is the value we change to demo GitOps CD
    GET /healthz  -> liveness/readiness (k8s probes + the container HEALTHCHECK)

THE SHARED-UI CONTRACT: the markup below is byte-identical (modulo blank lines) to every other
app's rendered page — `make check-ui-contract` renders all six and diffs them. Only the four
app-specific fields differ. Do not "improve" the markup here; change it in all six or not at all.

AIR-GAP: Python is the INTERPRETED case, and it differs from Java/Go/Rust in a way worth showing —
its dependencies must be present at RUNTIME, not compiled away. Dockerfile.builder therefore
installs into a virtualenv that the runtime stage copies wholesale; the venv IS the artifact.

Every operator-tunable value is env-driven with a documented default (mirrors .env.example).
"""

import json
import os

from flask import Flask, Response
from markupsafe import escape

# DEFAULT_MESSAGE is the demo "deploy me" value. `make verify` rewrites THIS line with a unique
# marker, pushes it, and asserts the marker appears on the deployed page — the same trick it plays
# on javawebapp's application.yml and gowebapp's main.go. Keep it on one line, in this exact shape.
DEFAULT_MESSAGE = "Hello from vks-airgap-cicd"


def env(key: str, fallback: str) -> str:
    """Return the value of key, or fallback when unset/empty."""
    return os.environ.get(key) or fallback


def render(p: dict) -> str:
    """Render the shared page. Every field is escaped: `make verify` injects a marker into one of
    them, and an unescaped '<' there would produce invalid markup and break the contract diff."""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>{escape(p['app_name'])} — VKS CI/CD demo</title>
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
        <h1>{escape(p['app_name'])}</h1>
        <p class="message">{escape(p['message'])}</p>
        <dl>
            <dt>Image tag</dt><dd>{escape(p['version'])}</dd>
            <dt>Commit</dt><dd>{escape(p['commit'])}</dd>
        </dl>
    </main>
</body>
</html>
"""


def new_app(p: dict) -> Flask:
    """Build the app. Split out from the listener so the tests exercise the REAL handlers over
    Flask's test client — hermetic, no network, no fixed port."""
    app = Flask(__name__)

    @app.get("/healthz")
    def healthz() -> Response:
        return Response(json.dumps({"status": "UP"}, separators=(",", ":")),
                        mimetype="application/json")

    @app.get("/")
    def index() -> Response:
        return Response(render(p), mimetype="text/html; charset=utf-8")

    return app


def page_from_env() -> dict:
    return {
        "app_name": env("APP_NAME", "pythonwebapp"),
        "message": env("APP_MESSAGE", DEFAULT_MESSAGE),
        "version": env("APP_VERSION", "dev"),
        "commit": env("APP_COMMIT", "unknown"),
    }


if __name__ == "__main__":
    new_app(page_from_env()).run(
        host=env("APP_BIND_HOST", "0.0.0.0"),
        port=int(env("APP_INTERNAL_PORT", "8080")),
    )
