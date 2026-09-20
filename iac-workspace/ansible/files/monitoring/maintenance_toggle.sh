#!/bin/bash
# ==============================================================================
# メンテナンス切替（Cloudflare API 直接方式）
# ProxyDown 発火/解決時に failover_webhook.py から呼ばれる。
# また maintenance_reconcile.sh（systemd timer）からも収束用途で呼ばれる。
# terraform を介さず、Cloudflare API で「メンテ用 Worker ルート」を作成/削除する。
#   on  : apex とサブドメイン全体を maintenance-failover へルーティング（メンテ画面）
#   off : 上記ルートを削除（通常のオリジンへ戻す）
# 認証情報は /opt/monitoring/maintenance.env（Ansible が Vault から配置）から読む。
#
# 冪等性と終了コード:
#   既に目的の状態（on 済み/off 済み）でも必ず exit 0 とする。
#   以前は変更なし時に最後の `[ "$changed" = 1 ] && notify ...` が失敗扱いとなり
#   exit 1 を返していた。webhook が 500 を返す → Alertmanager が同一受信者の通知を
#   無期限リトライし resolved（=メンテ OFF）が届かない、という障害の原因だった。
#   そのため「変更が無いこと」はエラーにしない。
#
# 注意: Cloudflare の Worker ルートパターンでは "ruruthegeek.dpdns.org/*" は
# apex のみに一致し、サブドメイン (pkhack./shake./ayahuya.) には一致しない。
# サブドメインも確実にメンテ画面へ落とすため "*.ruruthegeek.dpdns.org/*" を別途登録する。
# ==============================================================================
set -euo pipefail

ENV_FILE="${MAINTENANCE_ENV_FILE:-/opt/monitoring/maintenance.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${CF_API_TOKEN:?CF_API_TOKEN 未設定}"
: "${CF_ZONE_ID:?CF_ZONE_ID 未設定}"

MODE="${1:-}"
# apex とサブドメインの両方をカバーする（apex の /* はサブドメインに一致しないため両方必要）。
PATTERNS=("ruruthegeek.dpdns.org/*" "*.ruruthegeek.dpdns.org/*")
WORKER="maintenance-failover"
BASE="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/workers/routes"
# 自動 ON したことを示すマーカー。reconcile はこのファイルがある時だけ自動 OFF する
# （手動メンテを収束タイマーが勝手に解除しないための区別）。
STATE_FILE="${MAINTENANCE_STATE_FILE:-/opt/monitoring/state/maintenance_auto}"

# タイムアウトを必ず付ける（自宅回線断時に webhook が無期限に待たされると
# Alertmanager の通知パイプライン全体が詰まるため）。
api() {
  curl -fsS --connect-timeout 3 --max-time 8 \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" "$@"
}

# 指定パターンの既存ルート ID を返す（無ければ空文字）。
# API 到達不可・認証エラー・JSON 異常は非 0 で終了する（空文字と誤認しない）。
route_id() {
  api "${BASE}?per_page=100" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except ValueError as e:
    print("Cloudflare API 応答の JSON 解析に失敗: " + str(e), file=sys.stderr)
    sys.exit(1)
if not d.get("success"):
    print("Cloudflare API エラー: " + json.dumps(d.get("errors")), file=sys.stderr)
    sys.exit(1)
routes = d.get("result") or []
print(next((r["id"] for r in routes if r.get("pattern") == sys.argv[1]), ""))
' "$1"
}

notify() {
  [ -n "${DISCORD_WEBHOOK_URL:-}" ] || return 0
  curl -s --connect-timeout 3 --max-time 8 -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"$1\"}" "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

case "$MODE" in
  on)
    # 先にマーカーを作る。途中で API 失敗しても reconcile が後から収束できる。
    if ! touch "$STATE_FILE" 2>/dev/null; then
      echo "WARN: 状態マーカー ${STATE_FILE} を作成できません（reconcile による自動 OFF が効かない可能性）" >&2
    fi
    changed=0
    for pat in "${PATTERNS[@]}"; do
      if ! id="$(route_id "$pat")"; then
        echo "ERROR: Cloudflare API からルート一覧を取得できません: $pat" >&2
        exit 1
      fi
      if [ -z "$id" ]; then
        if ! api -X POST "$BASE" -d "{\"pattern\":\"${pat}\",\"script\":\"${WORKER}\"}" >/dev/null; then
          echo "ERROR: メンテルートの作成に失敗しました: $pat" >&2
          exit 1
        fi
        echo "maintenance ON (route created): $pat"
        changed=1
      else
        echo "maintenance already ON: $pat"
      fi
    done
    if [ "$changed" = 1 ]; then
      notify "[メンテナンス ON] Cloudflare Worker（メンテ画面）へ切替えました（apex + 全サブドメイン）。"
    fi
    ;;
  off)
    changed=0
    for pat in "${PATTERNS[@]}"; do
      if ! id="$(route_id "$pat")"; then
        echo "ERROR: Cloudflare API からルート一覧を取得できません: $pat" >&2
        exit 1
      fi
      if [ -n "$id" ]; then
        if ! api -X DELETE "${BASE}/${id}" >/dev/null; then
          echo "ERROR: メンテルートの削除に失敗しました: $pat" >&2
          exit 1
        fi
        echo "maintenance OFF (route deleted): $pat"
        changed=1
      else
        echo "maintenance already OFF: $pat"
      fi
    done
    rm -f "$STATE_FILE"
    if [ "$changed" = 1 ]; then
      notify "[メンテナンス OFF] 通常のオリジンへ戻しました。"
    fi
    ;;
  *)
    echo "usage: $0 [on|off]"; exit 1 ;;
esac
