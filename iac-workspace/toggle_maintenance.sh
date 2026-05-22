#!/bin/bash

# ==============================================================================
# Cloudflare Maintenance Mode Toggle Script
# ==============================================================================
# このスクリプトは、Terraformを使用してCloudflareのトラフィックを
# 自宅サーバーからメンテナンス用Worker（503/ゲーム画面）へ切り替えます。
# ==============================================================================

set -e

# 作業ディレクトリをTerraformのパスに設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"

cd "$TF_DIR"

# 引数のチェック
if [ -z "$1" ]; then
    echo "使用方法: $0 [on|off]"
    echo "  on  : メンテナンスモードを有効にする（Cloudflare Workerへルーティング）"
    echo "  off : メンテナンスモードを無効にする（通常の自宅サーバーへルーティング）"
    exit 1
fi

MODE=$(echo "$1" | tr '[:upper:]' '[:lower:]')

if [ "$MODE" = "on" ]; then
    echo "🚧 メンテナンスモードを有効にします..."
    TF_VAR_maintenance_mode="true"
elif [ "$MODE" = "off" ]; then
    echo "✅ メンテナンスモードを無効にします..."
    TF_VAR_maintenance_mode="false"
else
    echo "エラー: 引数は 'on' または 'off' を指定してください。"
    exit 1
fi

# Terraformの実行
echo "Terraform apply を実行中..."
terraform apply -var="maintenance_mode=${TF_VAR_maintenance_mode}" -auto-approve

echo ""
if [ "$MODE" = "on" ]; then
    MESSAGE="🚧 **[メンテナンスモード ON]** トラフィックはCloudflare Worker（メンテナンス/ミニゲーム画面）にルーティングされています。"
    echo "✅ メンテナンスモードが [ON] になりました。"
    echo "トラフィックはCloudflare Worker（メンテナンス画面）にルーティングされています。"
else
    MESSAGE="✅ **[メンテナンスモード OFF]** トラフィックは通常のサーバーへルーティングされています。"
    echo "✅ メンテナンスモードが [OFF] になりました。"
    echo "トラフィックは通常のサーバーへルーティングされています。"
fi

# Discordへの通知
if [ -f "terraform.tfvars" ]; then
    DISCORD_WEBHOOK_URL=$(grep 'discord_webhook_url' terraform.tfvars | awk -F '"' '{print $2}')
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        echo "Discordへ通知を送信しています..."
        curl -s -X POST -H "Content-Type: application/json" -d "{\"content\": \"$MESSAGE\"}" "$DISCORD_WEBHOOK_URL" > /dev/null
        echo "通知完了。"
    else
        echo "警告: terraform.tfvars に discord_webhook_url が設定されていないため、Discord通知はスキップされました。"
    fi
else
    echo "警告: terraform.tfvars が見つからないため、Discord通知はスキップされました。"
fi

