#!/bin/bash
# =====================================================================
# IaC Workspace - インフラ展開＆検証自動化スクリプト
# =====================================================================

set -e
cd "$(dirname "$0")"

# Vaultパスワードファイルを環境変数に設定（毎回の手入力を省略）
export ANSIBLE_VAULT_PASSWORD_FILE=".vault_pass"

echo "-------------------------------------------------------------"
echo "  IaC Workspace - インフラ検証および本番適用ツール"
echo "-------------------------------------------------------------"
echo " [1] テスト・検証フェーズ"
echo " [2] デプロイ反映フェーズ"
echo " [3] サーバー電源・ライフサイクル操作"
echo "-------------------------------------------------------------"
printf "実行する大項目の番号を入力してください (1-3): "
read -r MAIN_MODE

case "$MAIN_MODE" in
  1)
    echo "-------------------------------------------------------------"
    echo "  テスト・検証フェーズ"
    echo "-------------------------------------------------------------"
    echo " [1] 静的解析実行 (ansible-lint による品質確認)"
    echo " [2] 構文チェック (Ansible標準のシンタックスチェック)"
    echo " [3] 模擬実行 (Dry Run / Check Mode) ※実機に変更は加えません"
    echo "-------------------------------------------------------------"
    printf "実行するテストの番号を入力してください (1-3): "
    read -r SUB_MODE
    case "$SUB_MODE" in
      1)
        echo -e "\n>>> Ansible Lint を実行します..."
        if command -v uv &> /dev/null; then
          uv run ansible-lint ansible/
        else
          ansible-lint ansible/
        fi
        echo ">>> 静的解析は正常にパスしました！品質に問題はありません。"
        ;;
      2)
        echo -e "\n>>> 構文（シンタックス）チェックを実行します..."
        ansible-playbook -i ansible/inventory.ini ansible/site.yml --syntax-check
        echo ">>> 全Playbookの構文にエラーはありません。"
        ;;
      3)
        echo -e "\n>>> 模擬実行（Check Mode）を開始します..."
        ansible-playbook -i ansible/inventory.ini ansible/site.yml --check
        echo ">>> 模擬実行が完了しました。"
        ;;
      *)
        echo "[Error] 無効な番号です。"; exit 1 ;;
    esac
    ;;

  2)
    echo "-------------------------------------------------------------"
    echo "  デプロイ反映フェーズ"
    echo "-------------------------------------------------------------"
    echo " [1] 本番反映実行 (全サービスの一括展開)"
    echo " [2] Webアプリのみデプロイ"
    echo " [3] DB (PostgreSQL) のみデプロイ"
    echo " [4] Minecraft のみデプロイ"
    echo " [5] Discord Bot のみデプロイ"
    echo " [6] 自動バックアップ のみデプロイ"
    echo " [7] UPS監視 のみデプロイ"
    echo "-------------------------------------------------------------"
    printf "デプロイ対象の番号を入力してください (1-7): "
    read -r SUB_MODE
    case "$SUB_MODE" in
      1)
        echo -e "\n警告: 本番環境への実際の適用処理です"
        printf "本当に実行してよろしいですか？ (y/n): "
        read -r CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy] ]]; then
          echo ">>> 本番環境への適用を開始します..."
          ansible-playbook -i ansible/inventory.ini ansible/site.yml
          echo ">>> 適用処理が正常に完了しました。"
        else
          echo ">>> 中断しました。"
        fi
        ;;
      2)
        echo -e "\n>>> Webアプリのみデプロイを開始します..."
        ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags web
        ;;
      3)
        echo -e "\n>>> PostgreSQLのみデプロイを開始します..."
        ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags postgres
        ;;
      4)
        echo -e "\n>>> Minecraftのみデプロイを開始します..."
        ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags minecraft
        ;;
      5)
        echo -e "\n>>> Discord Botのみデプロイを開始します..."
        ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags ubsleepy
        ;;
      6)
        echo -e "\n>>> 自動バックアップのみデプロイを開始します..."
        ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags ubsleepy_backup
        ;;
      7)
        echo -e "\n>>> UPS監視のみデプロイを開始します..."
        ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags ups_exporter
        ;;
      *)
        echo "[Error] 無効な番号です。"; exit 1 ;;
    esac
    ;;

  3)
    echo "-------------------------------------------------------------"
    echo "  サーバー電源・ライフサイクル操作"
    echo "-------------------------------------------------------------"
    echo " [1] 安全なシャットダウン実行 (コンテナ停止後に電源OFF)"
    echo " [2] 安全な再起動実行 (コンテナ停止後にOS再起動)"
    echo "-------------------------------------------------------------"
    printf "実行する電源操作の番号を入力してください (1-2): "
    read -r SUB_MODE
    case "$SUB_MODE" in
      1)
        echo "-------------------------------------------------------------"
        echo "  安全なシャットダウン実行"
        echo "-------------------------------------------------------------"
        echo " [1] 全サーバーを一括シャットダウン"
        echo " [2] shakeserver (メイン) のみシャットダウン"
        echo " [3] tarakoserver (監視) のみシャットダウン"
        echo " [4] negitoroserver (プロキシ) のみシャットダウン"
        echo "-------------------------------------------------------------"
        printf "対象の番号を入力してください (1-4): "
        read -r TARGET
        case "$TARGET" in
          1) LIMIT="" ;;
          2) LIMIT="--limit shakeserver" ;;
          3) LIMIT="--limit tarakoserver" ;;
          4) LIMIT="--limit negitoroserver" ;;
          *) echo "[Error] 無効な番号です。"; exit 1 ;;
        esac
        
        # シャットダウンの意思確認（安全設計）
        echo -e "\n!!! 警告: サーバーのシャットダウンを行います !!!"
        printf "本当に対象ノードの電源を落としてよろしいですか？ (y/n): "
        read -r CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy] ]]; then
          echo -e "\n>>> 安全なシャットダウンを開始します..."
          ansible-playbook -i ansible/inventory.ini ansible/playbooks/shutdown_servers.yml $LIMIT
          echo ">>> シャットダウン命令の送信が完了しました。"
        else
          echo ">>> 中断しました。"
        fi
        ;;

      2)
        echo "-------------------------------------------------------------"
        echo "  安全な再起動実行"
        echo "-------------------------------------------------------------"
        echo " [1] 全サーバーを一括再起動"
        echo " [2] shakeserver (メイン) のみ再起動"
        echo " [3] tarakoserver (監視) のみ再起動"
        echo " [4] negitoroserver (プロキシ) のみ再起動"
        echo "-------------------------------------------------------------"
        printf "対象の番号を入力してください (1-4): "
        read -r TARGET
        case "$TARGET" in
          1) HOSTS="all" ;;
          2) HOSTS="shakeserver" ;;
          3) HOSTS="tarakoserver" ;;
          4) HOSTS="negitoroserver" ;;
          *) echo "[Error] 無効な番号です。"; exit 1 ;;
        esac
        echo -e "\n>>> 安全な再起動を開始します..."
        ansible $HOSTS -i ansible/inventory.ini -m reboot --become -B 2 -P 0
        echo ">>> 対象ホストへ再起動命令を送信しました。OSが完全に起動してVPNに再接続されるまで数分間お待ちください。"
        ;;
      *)
        echo "[Error] 無効な番号です。"; exit 1 ;;
    esac
    ;;

  *)
    echo -e "\n[Error] 無効な番号が選択されました。"
    exit 1
    ;;
esac
