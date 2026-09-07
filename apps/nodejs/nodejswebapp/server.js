// nodejswebapp — the Node sibling of javawebapp / gowebapp / rustwebapp / pythonwebapp / dotnetwebapp.
//
// It serves the SAME contract as every other app, so the pipeline, the ingress and `make verify`
// treat them identically:
//
//   GET /         -> the landing page, whose greeting is the value we change to demo GitOps CD
//   GET /healthz  -> liveness/readiness (k8s probes + the container HEALTHCHECK)
//
// THE SHARED-UI CONTRACT: the markup below is byte-identical (modulo blank lines) to every other
// app's rendered page — `make check-ui-contract` renders all six and diffs them. Only the four
// app-specific fields differ. Do not "improve" the markup here; change it in all six or not at all.
//
// AIR-GAP: this app is THE builder-image case — it has a real npm dependency (express), baked into
// apps/nodejs/nodejswebapp/Dockerfile.builder on the internet side so the in-cluster build runs
// `npm ci --offline` and reaches no registry.
//
// Every operator-tunable value is env-driven with a documented default (mirrors .env.example).
import express from 'express';
// readFileSync, NOT require(): this file is an ES MODULE ("type": "module"), where `require` does
// not exist — it fails at STARTUP with `ReferenceError: require is not defined in ES module scope`.
import { readFileSync } from 'node:fs';

// defaultMessage is the demo "deploy me" value. `make verify` rewrites THIS line with a unique
// marker, pushes it, and asserts the marker appears on the deployed page — the same trick it plays
// on javawebapp's application.yml and gowebapp's main.go. Keep it on one line, in this exact shape.
const defaultMessage = 'Hello from vks-airgap-cicd';

const env = (key, fallback) => process.env[key] || fallback;

const page = {
  appName: env('APP_NAME', 'nodejswebapp'),
  message: env('APP_MESSAGE', defaultMessage),
  version: env('APP_VERSION', 'dev'),
  commit: env('APP_COMMIT', 'unknown'),
};

// Minimal escaping: every field is interpolated into HTML, and `make verify` injects its marker
// into one of them. An unescaped '<' there would produce invalid markup and break the contract diff.
const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&#34;', "'": '&#39;' }[c]));

// The app's icon, served at a CONSTANT path.
//
// WHY A ROUTE AND NOT AN INLINE data: URI. Not because of any escaper -- a LITERAL data URI in a
// template survives Go's html/template and Thymeleaf untouched (measured; only an {{.Action}} is
// rewritten to #ZgotmplZ). The reason is `make check-ui-contract`: the six apps' rendered pages must
// be BYTE-IDENTICAL, so a per-app icon CANNOT live in the shared markup at all. Behind a constant URL
// it can -- the markup is the same six times, and the per-app difference is this response body.
//
// The colour APPROXIMATES the language's brand family; it is not an official value, and the label is
// an abbreviation, not a wordmark. rgb() not #rrggbb: a `#` would truncate the SVG at a URL fragment
// if anyone ever inlines it.
export const ICON = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32" role="img" aria-label="nodejswebapp"><rect width="32" height="32" rx="7" fill="rgb(83,158,67)"/><text x="16" y="21" text-anchor="middle" font-family="system-ui,sans-serif" font-size="13" font-weight="700" fill="rgb(255,255,255)">Nd</text></svg>';

export const render = (p) => `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>${esc(p.appName)} — VKS CI/CD demo</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg"/>
    <style>
        :root { color-scheme: light dark; }
        body {
            font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
            margin: 0; min-height: 100vh; display: flex; align-items: center;
            justify-content: center; background: #0f172a; color: #e2e8f0;
        }
        .card {
            background: #1e293b; border-radius: 16px; padding: 2.5rem 3rem;
            box-shadow: 0 10px 40px rgba(0,0,0,.4); max-width: 40rem; width: 90%;
        }
        .logo { display: block; width: 44px; height: 44px; margin: 0 0 1rem; }
        h1 { margin: 0 0 .25rem; font-size: 1.4rem; color: #94a3b8; font-weight: 600; }
        .message {
            font-size: 2rem; font-weight: 700; margin: .5rem 0 1.5rem;
            color: #38bdf8; word-break: break-word;
        }
        dl { display: grid; grid-template-columns: auto 1fr; gap: .4rem 1rem; margin: 0; }
        dt { color: #64748b; font-weight: 600; }
        dd { margin: 0; font-family: ui-monospace, "SFMono-Regular", Menlo, monospace; }
    </style>
</head>
<body>
    <main class="card">
        <img class="logo" src="/favicon.svg" alt="" width="44" height="44"/>
        <h1>${esc(p.appName)}</h1>
        <p class="message">${esc(p.message)}</p>
        <dl>
            <dt>Deployed tag</dt><dd>${esc(p.version)}</dd>
            <dt>Commit</dt><dd>${esc(p.commit)}</dd>
        </dl>
    </main>
</body>
</html>
`;

// newApp is split out from the listener so the tests exercise the REAL handlers over a real socket
// — hermetic, no fixed port, no machine state.
export const newApp = (p) => {
  const app = express();
  app.disable('x-powered-by');
  app.get('/healthz', (_req, res) => res.type('application/json').status(200).send('{"status":"UP"}'));
  app.get('/favicon.svg', (_req, res) => res.type('image/svg+xml').status(200).send(ICON));
  app.get('/', (_req, res) => res.type('text/html; charset=utf-8').status(200).send(render(p)));
  return app;
};

// Only listen when run directly, so importing this file in a test does not bind a port.
if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(env('APP_INTERNAL_PORT', '8080'));
  const host = env('APP_BIND_HOST', '0.0.0.0');
  const server = newApp(page).listen(port, host, () => {
    console.log(JSON.stringify({ level: 'INFO', msg: 'starting', app: page.appName, port, version: page.version, commit: page.commit }));
  });
  // k8s sends SIGTERM on rollout. A container's PID 1 gets NO default signal dispositions, so
  // without this handler the process IGNORES SIGTERM, the kubelet waits out the full 30s
  // terminationGracePeriod and SIGKILLs it — dropping in-flight requests. MEASURED over 114 samples
  // across 19 runs: apps that handle it drain in 5s, this one took 30s.
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => {
      server.close(() => process.exit(0));
      // Don't hang forever on a wedged keep-alive connection.
      setTimeout(() => process.exit(0), 10000).unref();
    });
  }
}
