// Tests for gowebapp. HERMETIC: httptest only — no network, no fixed port, no machine state, so
// they behave identically on a dev box, in the Tekton `go-test` task, and on a cold CI runner.
package main

import (
	"io"
	"net/http"
	"net/http/httptest"
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
