"""
メンテ切替（maintenance_toggle.sh）と収束（maintenance_reconcile.sh）の
ローカル単体テスト（Cloudflare / Prometheus 非接続）。

PATH 上の `curl` を偽装し、Cloudflare API と Prometheus API の応答を
JSON ファイルで制御する。実際の API は一切叩かない。

検証内容:
- on/off が冪等（既に目的の状態でも exit 0）→ 旧バグの再発防止
- 自動 ON マーカーの作成/削除
- API 異常時は非 0（webhook 側で検知できる）
- reconcile: firing→on / 非 firing+自動ON記録→off / 手動メンテは温存 /
  判定不能（blackbox停止・Prometheus停止）は何もしない
"""
import json
import os
import pathlib
import subprocess
import pytest

MON = pathlib.Path(__file__).resolve().parents[1] / "ansible" / "files" / "monitoring"
TOGGLE = MON / "maintenance_toggle.sh"
RECONCILE = MON / "maintenance_reconcile.sh"
PATTERNS = ["ruruthegeek.dpdns.org/*", "*.ruruthegeek.dpdns.org/*"]

FAKE_CURL = r'''#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["FAKE_CF_STATE"]) as f:
    state = json.load(f)


def arg_value(flag):
    return args[args.index(flag) + 1] if flag in args else None


url = next((a for a in args if a.startswith("http")), "")

if "api/v1/query" in url:
    if state.get("prom_fail"):
        sys.exit(22)
    query = arg_value("--data-urlencode") or ""
    if "ALERTS" in query:
        val = state.get("firing", "0")
    elif "up{" in query:
        val = state.get("blackbox_up", "1")
    else:
        val = ""
    if val is None:
        print(json.dumps({"status": "success", "data": {"result": []}}))
    else:
        print(json.dumps({"status": "success", "data": {
            "result": [{"metric": {}, "value": [0, str(val)]}]}}))
    sys.exit(0)

if state.get("fail_http"):
    sys.stderr.write("curl: (22) The requested URL returned error: 500\n")
    sys.exit(22)

method = arg_value("-X") or "GET"
if method == "GET":
    result = [{"id": "id-" + p, "pattern": p} for p in state["routes"]]
    print(json.dumps({"success": True, "result": result}))
elif method == "POST":
    body = json.loads(arg_value("-d"))
    if body["pattern"] not in state["routes"]:
        state["routes"].append(body["pattern"])
    with open(os.environ["FAKE_CF_STATE"], "w") as f:
        json.dump(state, f)
    print(json.dumps({"success": True, "result": body}))
elif method == "DELETE":
    rid = url.split("/workers/routes/", 1)[1]
    state["routes"] = [p for p in state["routes"] if "id-" + p != rid]
    with open(os.environ["FAKE_CF_STATE"], "w") as f:
        json.dump(state, f)
    print(json.dumps({"success": True, "result": {}}))
else:
    sys.exit(2)
'''

FAKE_TOGGLE = '''#!/bin/bash
echo "$1" >> "${TOGGLE_LOG:?TOGGLE_LOG not set}"
exit "${TOGGLE_EXIT:-0}"
'''


def write_state(root, routes=(), blackbox_up="1", firing="0",
                fail_http=False, prom_fail=False):
    (root / "cf_state.json").write_text(json.dumps({
        "routes": list(routes),
        "blackbox_up": blackbox_up,
        "firing": firing,
        "fail_http": fail_http,
        "prom_fail": prom_fail,
    }))


def read_state(root):
    return json.loads((root / "cf_state.json").read_text())


def marker(root):
    return root / "state" / "maintenance_auto"


def make_toggle(root):
    log = root / "toggle.log"
    script = root / "toggle.sh"
    script.write_text(FAKE_TOGGLE)
    script.chmod(0o755)
    return log


@pytest.fixture()
def sandbox(tmp_path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    curl = bindir / "curl"
    curl.write_text(FAKE_CURL)
    curl.chmod(0o755)
    (tmp_path / "state").mkdir()
    (tmp_path / "maintenance.env").write_text(
        "CF_API_TOKEN=test-token\nCF_ZONE_ID=test-zone\n")
    write_state(tmp_path)
    return tmp_path


def run_script(root, script, args=(), toggle_log=None,
               toggle_exit=None, extra_env=None):
    env = os.environ.copy()
    env["PATH"] = f"{root / 'bin'}:{env['PATH']}"
    env["MAINTENANCE_ENV_FILE"] = str(root / "maintenance.env")
    env["MAINTENANCE_STATE_FILE"] = str(marker(root))
    env["FAKE_CF_STATE"] = str(root / "cf_state.json")
    if toggle_log is not None:
        env["MAINTENANCE_TOGGLE"] = str(root / "toggle.sh")
        env["TOGGLE_LOG"] = str(toggle_log)
    if toggle_exit is not None:
        env["TOGGLE_EXIT"] = str(toggle_exit)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(["bash", str(script), *args],
                          capture_output=True, text=True, env=env)


def test_on_creates_routes_and_exits_0(sandbox):
    r = run_script(sandbox, TOGGLE, ["on"])
    assert r.returncode == 0, r.stderr
    assert read_state(sandbox)["routes"] == PATTERNS
    assert marker(sandbox).exists()
    assert "route created" in r.stdout


def test_on_when_already_on_exits_0(sandbox):
    """旧バグ: 変更なし時に exit 1 → webhook 500 → resolved が届かない。"""
    write_state(sandbox, routes=PATTERNS)
    r = run_script(sandbox, TOGGLE, ["on"])
    assert r.returncode == 0, r.stderr
    assert read_state(sandbox)["routes"] == PATTERNS
    assert "already ON" in r.stdout


def test_off_when_already_off_exits_0(sandbox):
    r = run_script(sandbox, TOGGLE, ["off"])
    assert r.returncode == 0, r.stderr
    assert "already OFF" in r.stdout


def test_off_removes_routes_and_marker_exits_0(sandbox):
    write_state(sandbox, routes=PATTERNS)
    marker(sandbox).touch()
    r = run_script(sandbox, TOGGLE, ["off"])
    assert r.returncode == 0, r.stderr
    assert read_state(sandbox)["routes"] == []
    assert not marker(sandbox).exists()


def test_api_failure_exits_nonzero(sandbox):
    write_state(sandbox, fail_http=True)
    r = run_script(sandbox, TOGGLE, ["on"])
    assert r.returncode != 0
    assert "ERROR" in r.stderr


def test_reconcile_firing_calls_on(sandbox):
    log = make_toggle(sandbox)
    write_state(sandbox, firing="1")
    r = run_script(sandbox, RECONCILE, toggle_log=log)
    assert r.returncode == 0, r.stderr
    assert log.read_text().split() == ["on"]


def test_reconcile_not_firing_with_marker_calls_off(sandbox):
    log = make_toggle(sandbox)
    write_state(sandbox, firing="0")
    marker(sandbox).touch()
    r = run_script(sandbox, RECONCILE, toggle_log=log)
    assert r.returncode == 0, r.stderr
    assert log.read_text().split() == ["off"]


def test_reconcile_not_firing_without_marker_does_nothing(sandbox):
    """手動メンテ（自動ONの記録なし）は収束タイマーが解除しない。"""
    log = make_toggle(sandbox)
    write_state(sandbox, firing="0")
    r = run_script(sandbox, RECONCILE, toggle_log=log)
    assert r.returncode == 0, r.stderr
    assert not log.exists()


def test_reconcile_blackbox_down_does_nothing(sandbox):
    log = make_toggle(sandbox)
    write_state(sandbox, blackbox_up="0", firing="0")
    marker(sandbox).touch()
    r = run_script(sandbox, RECONCILE, toggle_log=log)
    assert r.returncode == 0, r.stderr
    assert not log.exists()


def test_reconcile_prometheus_unreachable_does_nothing(sandbox):
    log = make_toggle(sandbox)
    write_state(sandbox, prom_fail=True)
    marker(sandbox).touch()
    r = run_script(sandbox, RECONCILE, toggle_log=log)
    assert r.returncode == 0, r.stderr
    assert not log.exists()


def test_reconcile_propagates_toggle_failure(sandbox):
    log = make_toggle(sandbox)
    write_state(sandbox, firing="1")
    r = run_script(sandbox, RECONCILE, toggle_log=log, toggle_exit=1)
    assert r.returncode == 1
    assert log.read_text().split() == ["on"]
