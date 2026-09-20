"""
フェイルオーバー（メンテ自動切替）ロジックの ローカル単体テスト（Cloudflare非接続）

failover_webhook.py をその場でインポートし、subprocess.run / os.path.exists を
モックして maintenance_toggle.sh を「実行しない」状態で、
- ProxyDown firing  -> maintenance_toggle.sh on
- ProxyDown resolved-> maintenance_toggle.sh off
- firing+resolved 混在 -> firing 優先で on
- 無関係アラート     -> 何もしない
- 切替スクリプト失敗 -> それでも 200 を返す（Alertmanager の resolved 配信を塞がない）
を検証する。実際の Cloudflare 切替は発生しない。
"""
import json
import sys
import threading
import urllib.error
import urllib.request
import pathlib
import importlib
from http.server import HTTPServer
import pytest

MON = pathlib.Path(__file__).resolve().parents[1] / "ansible" / "files" / "monitoring"


class _Result:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


@pytest.fixture()
def make_server(monkeypatch):
    servers = []

    def _make(run_impl=None, script_exists=True):
        sys.path.insert(0, str(MON))
        fw = importlib.import_module("failover_webhook")
        importlib.reload(fw)
        calls = []

        if run_impl is None:
            def run_impl(args, **kw):
                return _Result()

        def recording_run(args, **kw):
            calls.append(list(args))
            return run_impl(args, **kw)

        monkeypatch.setattr(fw.subprocess, "run", recording_run)
        monkeypatch.setattr(fw.os.path, "exists", lambda p: script_exists)

        srv = HTTPServer(("127.0.0.1", 0), fw.WebhookHandler)
        port = srv.server_address[1]
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers.append(srv)
        return port, calls

    yield _make
    for srv in servers:
        srv.shutdown()
    if str(MON) in sys.path:
        sys.path.remove(str(MON))


def _post(port, payload):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status


def test_proxydown_firing_enables_maintenance(make_server):
    port, calls = make_server()
    assert _post(port, {"alerts": [{"status": "firing", "labels": {"alertname": "ProxyDown"}}]}) == 200
    assert len(calls) == 1
    assert calls[0][-1] == "on"
    assert calls[0][0].endswith("maintenance_toggle.sh")


def test_proxydown_resolved_disables_maintenance(make_server):
    port, calls = make_server()
    assert _post(port, {"alerts": [{"status": "resolved", "labels": {"alertname": "ProxyDown"}}]}) == 200
    assert len(calls) == 1
    assert calls[0][-1] == "off"


def test_mixed_firing_and_resolved_prefers_firing(make_server):
    port, calls = make_server()
    _post(port, {"alerts": [
        {"status": "resolved", "labels": {"alertname": "ProxyDown"}},
        {"status": "firing", "labels": {"alertname": "ProxyDown"}},
    ]})
    assert len(calls) == 1
    assert calls[0][-1] == "on"


def test_unrelated_alert_does_nothing(make_server):
    port, calls = make_server()
    assert _post(port, {"alerts": [{"status": "firing", "labels": {"alertname": "NodeDown"}}]}) == 200
    assert calls == []


def test_script_failure_still_returns_200(make_server):
    """切替が exit 1 でも 200。500 を返すと Alertmanager が resolved を配信できなくなる。"""
    def failing_run(args, **kw):
        return _Result(returncode=1, stderr="Cloudflare API unreachable")

    port, calls = make_server(failing_run)
    assert _post(port, {"alerts": [{"status": "resolved", "labels": {"alertname": "ProxyDown"}}]}) == 200
    assert len(calls) == 1
    assert calls[0][-1] == "off"


def test_run_exception_still_returns_200(make_server):
    def exploding_run(args, **kw):
        raise OSError("script disappeared")

    port, _ = make_server(exploding_run)
    assert _post(port, {"alerts": [{"status": "firing", "labels": {"alertname": "ProxyDown"}}]}) == 200


def test_missing_script_still_returns_200(make_server):
    port, calls = make_server(script_exists=False)
    assert _post(port, {"alerts": [{"status": "firing", "labels": {"alertname": "ProxyDown"}}]}) == 200
    assert calls == []


def test_invalid_payload_returns_400(make_server):
    port, _ = make_server()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/", data=b"not-json",
        headers={"Content-Type": "application/json"}, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(req, timeout=5)
    assert exc.value.code == 400


def test_scripts_syntax_ok():
    """メンテ切替/収束スクリプトの bash 構文チェック（実行はしない=Cloudflare非接続）。"""
    import subprocess
    repo = MON.parents[2]  # iac-workspace
    for script in (
        MON / "maintenance_toggle.sh",
        MON / "maintenance_reconcile.sh",
        repo / "toggle_maintenance.sh",
    ):
        r = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        assert r.returncode == 0, f"{script}: {r.stderr}"
