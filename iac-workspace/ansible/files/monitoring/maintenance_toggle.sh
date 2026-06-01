#!/bin/bash
# ==============================================================================
# メンテナンス切替（Cloudflare API 直接方式）
# ProxyDown 発火/解決時に failover_webhook.py から呼ばれる。
# terraform を介さず、Cloudflare API で「メンテ用 Worker ルート」を作成/削除する。
#   on  : pattern=ruruthegeek.dpdns.org/* を maintenance-failover へルーティング（メンテ画面）
#   off : 上記ルートを削除（通常のオリジンへ戻す）
# 認証情報は /opt/monitoring/maintenance.env（Ansible が Vault から配置）から読む。
# ==============================================================================
set -euo pipefail

ENV_FILE="/opt/monitoring/maintenance.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${CF_API_TOKEN:?CF_API_TOKEN 未設定}"
: "${CF_ZONE_ID:?CF_ZONE_ID 未設定}"

MODE="${1:-}"
PATTERN="ruruthegeek.dpdns.org/*"
WORKER="maintenance-failover"
BASE="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/workers/routes"

api() {
  curl -s -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" "$@"
}

route_id() {
  api "$BASE" | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((r['id'] for r in (d.get('result') or []) if r.get('pattern')=='${PATTERN}'),''))"
}

notify() {
  [ -n "${DISCORD_WEBHOOK_URL:-}" ] || return 0
  curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"$1\"}" "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

case "$MODE" in
  on)
    if [ -z "$(route_id)" ]; then
      api -X POST "$BASE" -d "{\"pattern\":\"${PATTERN}\",\"script\":\"${WORKER}\"}" >/dev/null
      echo "maintenance ON (route created)"
      notify "[メンテナンス ON] Cloudflare Worker（メンテ画面）へ切替えました。"
    else
      echo "maintenance already ON"
    fi
    ;;
  off)
    id="$(route_id)"
    if [ -n "$id" ]; then
      api -X DELETE "${BASE}/${id}" >/dev/null
      echo "maintenance OFF (route deleted)"
      notify "[メンテナンス OFF] 通常のオリジンへ戻しました。"
    else
      echo "maintenance already OFF"
    fi
    ;;
  *)
    echo "usage: $0 [on|off]"; exit 1 ;;
esac
