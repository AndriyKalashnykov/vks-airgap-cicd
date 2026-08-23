// Tests for gowebapp. HERMETIC: httptest only — no network, no fixed port, no machine state, so
// they behave identically on a dev box, in the Tekton `go-test` task, and on a cold CI runner.
package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestHealthz(t *testing.T) {
	srv := httptest.NewServer(newMux(page{}))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /healthz: want 200, got %d", resp.StatusCode)
	}
}

// The deployed page MUST render the message: `make verify` proves the whole GitOps loop by
// pushing a unique marker into it and asserting the marker appears on the live page. If the
// message stopped rendering, that check would be measuring nothing.
func TestIndexRendersMessage(t *testing.T) {
	want := "marker-4711-hello"
	srv := httptest.NewServer(newMux(page{AppName: "gowebapp", Message: want, Version: "1.2.3", Commit: "abc1234"}))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /: want 200, got %d", resp.StatusCode)
	}

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	body := string(raw)

	for _, s := range []string{want, "gowebapp", "1.2.3", "abc1234"} {
		if !strings.Contains(body, s) {
			t.Errorf("page does not render %q", s)
		}
	}
}

func TestEnvFallback(t *testing.T) {
	t.Setenv("APP_MESSAGE", "")
	if got := env("APP_MESSAGE", defaultMessage); got != defaultMessage {
		t.Errorf("empty env must fall back: got %q, want %q", got, defaultMessage)
	}
	t.Setenv("APP_MESSAGE", "from-env")
	if got := env("APP_MESSAGE", defaultMessage); got != "from-env" {
		t.Errorf("set env must win: got %q", got)
	}
}

// --- THE SHARED-UI CONTRACT (plan Phase B) -----------------------------------------------------
// Owner requirement: every app renders the SAME layout, differing only in app-specific data. Today
// the Java Thymeleaf template and this inline one hold the CSS block VERBATIM TWICE, with nothing
// asserting they stay identical -- measured byte-identical 2026-08-22, which is exactly when to
// gate it, not after the first drift. Six apps means six copies.
//
// The contract is deliberately an OBSERVABLE one: each app RENDERS with the fixed inputs below and
// writes the result to $UI_CONTRACT_OUT. A language-agnostic gate then masks the app-specific
// fields and requires every app's output to be byte-identical. That measures "same look and feel"
// as a user would see it, rather than comparing template SOURCES -- which cannot work across
// Thymeleaf / html/template / Razor / Jinja2 / JSX.
//
// A GENERATOR + drift gate would PREVENT drift rather than detect it, and is the right SECOND step.
// It is not the first one: it presumes a single markup source, and each app dir IS its own Gitea
// repo, so the markup has to live in each app.
//
// Skips when the env var is unset, so a normal `go test` is unaffected.
func TestUIContractRender(t *testing.T) {
	out := os.Getenv("UI_CONTRACT_OUT")
	if out == "" {
		t.Skip("UI_CONTRACT_OUT unset — this is the contract producer, not a unit test")
	}
	// FIXED inputs, shared verbatim by every app's producer. They are masked by the gate, so their
	// VALUES do not matter -- but they must be the same everywhere so the masking is uniform.
	p := page{AppName: "APPNAME", Message: "MESSAGE", Version: "VERSION", Commit: "COMMIT"}
	var buf bytes.Buffer
	if err := indexTmpl.Execute(&buf, p); err != nil {
		t.Fatalf("render: %v", err)
	}
	if err := os.WriteFile(out, buf.Bytes(), 0o644); err != nil {
		t.Fatalf("write %s: %v", out, err)
	}
}
