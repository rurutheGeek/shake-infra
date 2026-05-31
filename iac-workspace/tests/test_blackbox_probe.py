"""
blackbox HTTPS+エンドポイント監視の ローカル実証テスト（本番非接続）

- ローカルに go-httpbin(200/500 を返す) と blackbox-exporter を立て、
  blackbox の probe_success が 200→1 / 500→0 になることを確認
  （= DBが落ちて 500 になったら監視が検知できることの証明）
- 本番 prometheus.yml / prometheus_rules.yml を promtool で構文検証
"""
import os
import re
import subprocess
import time
import uuid
import pathlib
import pytest

MON = pathlib.Path(__file__).resolve().parents[1] / "ansible" / "files" / "monitoring"
SID = uuid.uuid4().hex[:8]
NET = f"bbtest_{SID}"
HTTPBIN = f"httpbin_{SID}"
BB = f"bb_{SID}"
BB_PORT = 19115


def _run(*args, **kw):
    return subprocess.run(["docker", *args], capture_output=True, text=True, **kw)


@pytest.fixture(scope="module")
def blackbox():
    _run("network", "create", NET)
    _run("run", "-d", "--name", HTTPBIN, "--network", NET, "mccutchen/go-httpbin:latest")
    _run("run", "-d", "--name", BB, "--network", NET, "-p", f"{BB_PORT}:9115",
         "prom/blackbox-exporter:latest")
    # blackbox 起動待ち
    ok = False
    for _ in range(30):
        r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                            f"http://localhost:{BB_PORT}/-/healthy"], capture_output=True, text=True)
        if r.stdout.strip() == "200":
            ok = True
            break
        time.sleep(1)

    def probe(path):
        target = f"http://{HTTPBIN}:8080{path}"
        url = f"http://localhost:{BB_PORT}/probe?module=http_2xx&target={target}"
        r = subprocess.run(["curl", "-s", url], capture_output=True, text=True)
        m = re.search(r"^probe_success\s+(\d)", r.stdout, re.M)
        return int(m.group(1)) if m else None

    if not ok:
        for c in (BB, HTTPBIN):
            print(_run("logs", "--tail", "20", c).stdout)
    yield probe
    for c in (BB, HTTPBIN):
        _run("rm", "-f", c)
    _run("network", "rm", NET)


def test_probe_detects_200(blackbox):
    assert blackbox("/status/200") == 1


def test_probe_detects_500(blackbox):
    """DBが落ちて 500 になったケース = 監視が異常(0)として検知できること。"""
    assert blackbox("/status/500") == 0


def test_prod_prometheus_config_valid():
    """本番 prometheus.yml + rules を promtool で検証（デプロイ前の構文チェック）。"""
    r = _run("run", "--rm", "-v", f"{MON}:/work", "-w", "/work", "--entrypoint", "promtool",
             "prom/prometheus:latest", "check", "config", "prometheus.yml")
    assert r.returncode == 0, f"promtool check config failed:\n{r.stdout}\n{r.stderr}"


def test_prod_alert_rules_valid():
    r = _run("run", "--rm", "-v", f"{MON}:/work", "-w", "/work", "--entrypoint", "promtool",
             "prom/prometheus:latest", "check", "rules", "prometheus_rules.yml")
    assert r.returncode == 0, f"promtool check rules failed:\n{r.stdout}\n{r.stderr}"
