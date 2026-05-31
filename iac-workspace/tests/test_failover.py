"""
フェイルオーバー（メンテ自動切替）ロジックの ローカル単体テスト（Cloudflare非接続）

failover_webhook.py をその場でインポートし、subprocess.run / os.path.exists を
モックして toggle_maintenance.sh を「実行しない」状態で、
- ProxyDown firing  -> toggle_maintenance.sh on
- ProxyDown resolved-> toggle_maintenance.sh off
- 無関係アラート     -> 何もしない
を検証する。実際の Cloudflare 切替は発生しない。
"""
import json
import sys
import threading
import urllib.request
import pathlib
import importlib
from http.server import HTTPServer
import pytest

MON = pathlib.Path(__file__).resolve().parents[1] / "ansible" / "files" / "monitoring"


@pytest.fixture()
def server(monkeypatch):
    sys.path.insert(0, str(MON))
    fw = importlib.import_module("failover_webhook")
    importlib.reload(fw)
    calls = []

    class _R:
        returncode = 0

    def fake_run(args, **kw):
        calls.append(list(args))
        return _R()

    # monkeypatch でテスト後に自動復元（グローバル汚染を防ぐ）。実スクリプトは起動しない。
    monkeypatch.setattr(fw.subprocess, "run", fake_run)
    monkeypatch.setattr(fw.os.path, "exists", lambda p: True)

    srv = HTTPServer(("127.0.0.1", 0), fw.WebhookHandler)
    port = srv.server_address[1]
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    yield port, calls
    srv.shutdown()
    sys.path.remove(str(MON))


def _post(port, payload):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status


def test_proxydown_firing_enables_maintenance(server):
    port, calls = server
    _post(port, {"alerts": [{"status": "firing", "labels": {"alertname": "ProxyDown"}}]})
    assert len(calls) == 1
    assert calls[0][-1] == "on"
    assert calls[0][0].endswith("toggle_maintenance.sh")


def test_proxydown_resolved_disables_maintenance(server):
    port, calls = server
    _post(port, {"alerts": [{"status": "resolved", "labels": {"alertname": "ProxyDown"}}]})
    assert len(calls) == 1
    assert calls[0][-1] == "off"


def test_unrelated_alert_does_nothing(server):
    port, calls = server
    _post(port, {"alerts": [{"status": "firing", "labels": {"alertname": "NodeDown"}}]})
    assert calls == []


def test_toggle_script_syntax_ok():
    """toggle_maintenance.sh の bash 構文チェック（実行はしない=Cloudflare非接続）。"""
    import subprocess
    script = MON.parents[2] / "toggle_maintenance.sh"
    r = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
