"""Tests for pythonwebapp. HERMETIC: Flask's test client — no network, no fixed port, no machine
state, so they behave identically on a dev box, in the Tekton task, and on a cold CI runner."""

import os

from app import new_app, render


def _client(p=None):
    return new_app(p or {"app_name": "a", "message": "m", "app_version": "0.1.0", "version": "v", "commit": "c"}).test_client()


def test_healthz_answers_200_with_the_shared_body():
    r = _client().get("/healthz")
    assert r.status_code == 200
    assert r.get_data(as_text=True).strip() == '{"status":"UP"}'


def test_index_renders_message_version_and_commit():
    # The deployed page MUST render the message: `make verify` proves the whole GitOps loop by
    # pushing a unique marker into it and asserting the marker appears on the live page. If the
    # message stopped rendering, that check would be measuring nothing.
    p = {"app_name": "pythonwebapp", "message": "marker-4711-hello", "app_version": "0.1.0", "version": "1.2.3", "commit": "abc1234"}
    body = _client(p).get("/").get_data(as_text=True)
    for want in p.values():
        assert want in body


def test_html_significant_characters_are_escaped():
    out = render({"app_name": "a", "message": "<script>x</script>", "app_version": "0.1.0", "version": "v", "commit": "c"})
    assert "&lt;script&gt;" in out


def test_ui_contract_producer():
    """THE SHARED-UI CONTRACT PRODUCER (see scripts/check-ui-contract.sh).

    Renders through the REAL handler and writes the page to $UI_CONTRACT_OUT. Skipped when unset so
    a normal test run is unaffected. The literals must be IDENTICAL across all six apps AND MUTUALLY
    DISTINCT — distinctness is the only reason a field SWAP is caught by the diff.
    """
    out = os.environ.get("UI_CONTRACT_OUT")
    if not out:
        return
    body = _client({"app_name": "APPNAME", "message": "MESSAGE", "app_version": "APPVERSION", "version": "VERSION", "commit": "COMMIT"}) \
        .get("/").get_data(as_text=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(body)
