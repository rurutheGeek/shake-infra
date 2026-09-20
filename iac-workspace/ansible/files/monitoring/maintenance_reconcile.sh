#!/bin/bash
# ==============================================================================
# メンテナンス状態の収束（Alertmanager 非依存のセーフティネット）
#
# systemd timer（maintenance-reconcile.timer）から 1 分毎に実行され、Prometheus の
# ProxyDown 発火状態を照会して maintenance_toggle.sh を on/off 冪等適用する。
# webhook の resolved 通知が欠落した場合・Alertmanager 再起動・Webhook 実行失敗の後でも
# 必ず状態を収束させる（「自動 OFF が resolved 通知に依存する」構造の解消）。
#
# 判定不能（Prometheus 停止・blackbox スクレイプ異常）のときは何もしない。
# 自動 ON の記録（maintenance_toggle.sh が作るマーカー）が無いルートは手動メンテの
# 可能性があるため OFF にしない。
# ==============================================================================
set -euo pipefail

PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
TOGGLE="${MAINTENANCE_TOGGLE:-/opt/monitoring/maintenance_toggle.sh}"
STATE_FILE="${MAINTENANCE_STATE_FILE:-/opt/monitoring/state/maintenance_auto}"

# PromQL の結果を1つの値として返す。結果が無ければ空文字、API/JSON 異常は非 0。
prom_value() {
  curl -fsS --connect-timeout 3 --max-time 8 --get \
    --data-urlencode "query=$1" "${PROM_URL}/api/v1/query" \
  | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except ValueError as e:
    print("Prometheus 応答の JSON 解析に失敗: " + str(e), file=sys.stderr)
    sys.exit(1)
if d.get("status") != "success":
    print("Prometheus API エラー: " + json.dumps(d.get("error")), file=sys.stderr)
    sys.exit(1)
result = (d.get("data") or {}).get("result") or []
print(result[0]["value"][1] if result else "")
'
}

# 1) blackbox 自体が生きているか。判定不能時に誤って OFF しないためのガード。
blackbox_up="$(prom_value 'min(up{job="blackbox"})')" || {
  echo "Prometheus へ到達できません。状態は変更しません。" >&2
  exit 0
}
if [ -z "$blackbox_up" ]; then
  echo "blackbox メトリクス未取得（判定不能）。状態は変更しません。" >&2
  exit 0
fi
if [ "$blackbox_up" != "1" ]; then
  echo "blackbox exporter がダウン（up=${blackbox_up}）。判定不能のため状態は変更しません。" >&2
  exit 0
fi

# 2) ProxyDown firing 件数（for: 30s のデバウンス込み）。
firing="$(prom_value 'count(ALERTS{alertname="ProxyDown",alertstate="firing"}) or vector(0)')" || {
  echo "Prometheus へ到達できません。状態は変更しません。" >&2
  exit 0
}
firing="${firing:-0}"

if ! [[ "$firing" =~ ^[0-9]+$ ]]; then
  echo "ProxyDown 発火件数を解釈できません（${firing}）。状態は変更しません。" >&2
  exit 0
fi

if [ "$firing" -gt 0 ]; then
  echo "ProxyDown firing (${firing}) -> maintenance on"
  exec "$TOGGLE" on
fi

if [ -e "$STATE_FILE" ]; then
  echo "ProxyDown not firing / 自動 ON の記録あり -> maintenance off"
  exec "$TOGGLE" off
fi

echo "ProxyDown not firing / 自動 ON の記録なし -> 変更なし（手動メンテを尊重）"
