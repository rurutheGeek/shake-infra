#!/bin/bash
# ==============================================================================
# メンテナンス切替（Cloudflare API 直接方式）
# ProxyDown 発火/解決時に failover_webhook.py から呼ばれる。
# terraform を介さず、Cloudflare API で「メンテ用 Worker ルート」を作成/削除する。
#   on  : apex とサブドメイン全体を maintenance-failover へルーティング（メンテ画面）
#   off : 上記ルートを削除（通常のオリジンへ戻す）
# 認証情報は /opt/monitoring/maintenance.env（Ansible が Vault から配置）から読む。
#
# 注意: Cloudflare の Worker ルートパターンでは "ruruthegeek.dpdns.org/*" は
# apex のみに一致し、サブドメイン (pkhack./shake./ayahuya.) には一致しない。
# サブドメインも確実にメンテ画面へ落とすため "*.ruruthegeek.dpdns.org/*" を別途登録する。
# ==============================================================================
set -euo pipefail

ENV_FILE="/opt/monitoring/maintenance.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${CF_API_TOKEN:?CF_API_TOKEN 未設定}"
: "${CF_ZONE_ID:?CF_ZONE_ID 未設定}"

MODE="${1:-}"
# apex とサブドメインの両方をカバーする（apex の /* はサブドメインに一致しないため両方必要）。
PATTERNS=("ruruthegeek.dpdns.org/*" "*.ruruthegeek.dpdns.org/*")
WORKER="maintenance-failover"
BASE="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/workers/routes"

api() {
  curl -s -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" "$@"
}

# 指定パターンの既存ルート ID を返す（無ければ空文字）。
route_id() {
  api "$BASE" | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((r['id'] for r in (d.get('result') or []) if r.get('pattern')==sys.argv[1]),''))" "$1"
}

notify() {
  [ -n "${DISCORD_WEBHOOK_URL:-}" ] || return 0
  curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"$1\"}" "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

case "$MODE" in
  on)
    changed=0
    for pat in "${PATTERNS[@]}"; do
      if [ -z "$(route_id "$pat")" ]; then
        api -X POST "$BASE" -d "{\"pattern\":\"${pat}\",\"script\":\"${WORKER}\"}" >/dev/null
        echo "maintenance ON (route created): $pat"
        changed=1
      else
        echo "maintenance already ON: $pat"
      fi
    done
    [ "$changed" = 1 ] && notify "[メンテナンス ON] Cloudflare Worker（メンテ画面）へ切替えました（apex + 全サブドメイン）。"
    ;;
  off)
    changed=0
    for pat in "${PATTERNS[@]}"; do
      id="$(route_id "$pat")"
      if [ -n "$id" ]; then
        api -X DELETE "${BASE}/${id}" >/dev/null
        echo "maintenance OFF (route deleted): $pat"
        changed=1
      else
        echo "maintenance already OFF: $pat"
      fi
    done
    [ "$changed" = 1 ] && notify "[メンテナンス OFF] 通常のオリジンへ戻しました。"
    ;;
  *)
    echo "usage: $0 [on|off]"; exit 1 ;;
esac
