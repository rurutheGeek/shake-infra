"""
Alertmanager 設定（alertmanager.yml.j2）の検証（本番非接続）

- テンプレートをダミーの Discord Webhook URL で描画し、prom/alertmanager イメージの
  `amtool check-config` で構文検証する（inhibit_rules を含む）。
- 通知量の方針（repeat_interval と抑制）が後退しないよう最低限の表明を置く。
"""
import os
import pathlib
import subprocess
import tempfile

ROLE = pathlib.Path(__file__).resolve().parents[1] / "ansible" / "roles" / "monitoring"
TEMPLATE = ROLE / "templates" / "alertmanager.yml.j2"
DUMMY_WEBHOOK = "https://discord.com/api/webhooks/000000000000000000/dummy"


def _render() -> str:
    return TEMPLATE.read_text(encoding="utf-8").replace(
        "{{ discord_webhook_url }}", DUMMY_WEBHOOK)


def test_template_has_no_unrendered_variables():
    rendered = _render()
    assert "{{" not in rendered
    assert "{%" not in rendered


def test_notification_policy_stays_quiet():
    """1障害で通知が溢れない方針（12h再送・ProxyDown中の派生抑制）を固定する。"""
    rendered = _render()
    assert "repeat_interval: 12h" in rendered
    assert "inhibit_rules:" in rendered
    assert 'alertname =~ "WebSiteDown|WebDbEndpointDown"' in rendered


def test_prod_alertmanager_config_valid():
    """描画した alertmanager.yml を amtool で検証（デプロイ前の構文チェック）。"""
    with tempfile.TemporaryDirectory() as tmp:
        # コンテナ（nobody）から読めるようにする。既定の 0700 のままだと
        # amtool が "permission denied" になる。
        os.chmod(tmp, 0o755)
        config = pathlib.Path(tmp) / "alertmanager.yml"
        config.write_text(_render(), encoding="utf-8")
        config.chmod(0o644)
        result = subprocess.run(
            ["docker", "run", "--rm", "-v", f"{tmp}:/work", "-w", "/work",
             "--entrypoint", "amtool", "prom/alertmanager:latest",
             "check-config", "alertmanager.yml"],
            capture_output=True, text=True,
        )
    assert result.returncode == 0, (
        f"amtool check-config failed:\n{result.stdout}\n{result.stderr}")
