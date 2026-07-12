// gowebapp — the Go sibling of javawebapp.
//
// Deliberately STDLIB-ONLY (net/http + html/template). That is not laziness: an air-gapped
// build cannot reach a module proxy, so a dependency would force the same pre-baked
// dependency-cache builder image that the Maven app needs (apps/java/javawebapp/Dockerfile.builder).
// With zero external modules, `go build` works offline against the mirrored golang image alone.
//
// It serves the same contract as javawebapp so the pipeline, the ingress and `make verify` treat
// the two apps identically:
//
//	GET /         -> the landing page, whose greeting is the value we change to demo GitOps CD
//	GET /healthz  -> liveness/readiness (k8s probes + the container HEALTHCHECK)
//
// Every operator-tunable value is env-driven with a documented default (mirrors .env.example).
package main

import (
	"context"
	"errors"
	"fmt"
	"html/template"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// defaultMessage is the demo "deploy me" value. `make verify` rewrites THIS line with a unique
// marker, pushes it, and then asserts the marker appears on the deployed page — the same trick it
// plays on javawebapp's application.yml. Keep it on one line, in this exact shape.
const defaultMessage = "Hello from vks-airgap-cicd"

// env returns the value of key, or fallback when unset/empty.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

type page struct {
	AppName string
	Message string
	Version string
	Commit  string
}

// The page is self-contained — no external CSS/JS/CDN, because the cluster is air-gapped.
// Mirrors javawebapp's index.html so the two apps are visibly siblings.
var indexTmpl = template.Must(template.New("index").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>{{.AppName}} — VKS CI/CD demo</title>
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
        <h1>{{.AppName}}</h1>
        <p class="message">{{.Message}}</p>
        <dl>
            <dt>Version</dt><dd>{{.Version}}</dd>
            <dt>Commit</dt><dd>{{.Commit}}</dd>
        </dl>
    </main>
</body>
</html>
`))

// newMux builds the router. Split out from main so the tests exercise the REAL handlers
// (not a reimplementation of them) over httptest — hermetic, no network, no fixed port.
func newMux(p page) *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprint(w, `{"status":"UP"}`)
	})

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := indexTmpl.Execute(w, p); err != nil {
			slog.Error("render failed", "err", err)
			http.Error(w, "render failed", http.StatusInternalServerError)
		}
	})

	return mux
}

// healthcheck is the container HEALTHCHECK probe. The runtime image is distroless (no shell, no
// curl), so the binary probes ITSELF — `gowebapp -healthcheck` exits 0 iff /healthz answers 200.
// 127.0.0.1, never "localhost": on some images localhost resolves to ::1 first and an IPv4-only
// listener would refuse the probe, marking the container unhealthy forever.
func healthcheck(port string) int {
	c := &http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		fmt.Fprintln(os.Stderr, "healthcheck:", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintln(os.Stderr, "healthcheck: status", resp.StatusCode)
		return 1
	}
	return 0
}

func main() {
	port := env("APP_INTERNAL_PORT", "8080")

	if len(os.Args) > 1 && os.Args[1] == "-healthcheck" {
		os.Exit(healthcheck(port))
	}

	p := page{
		AppName: env("APP_NAME", "gowebapp"),
		Message: env("APP_MESSAGE", defaultMessage),
		Version: env("APP_VERSION", "dev"),
		Commit:  env("APP_COMMIT", "unknown"),
	}

	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	srv := &http.Server{
		// Bind all interfaces (the pod's), not localhost — otherwise the kubelet's probes and the
		// Service cannot reach it.
		Addr:              net.JoinHostPort("", port),
		Handler:           newMux(p),
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Graceful shutdown: k8s sends SIGTERM on rollout; finish in-flight requests instead of
	// dropping them (this is what makes the ArgoCD-driven rollout look clean).
	idle := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			slog.Error("shutdown", "err", err)
		}
		close(idle)
	}()

	slog.Info("starting", "app", p.AppName, "port", port, "version", p.Version, "commit", p.Commit)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("listen", "err", err)
		os.Exit(1)
	}
	<-idle
}
