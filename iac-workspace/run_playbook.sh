#!/bin/bash
# =====================================================================
# IaC Workspace - インフラ展開＆検証自動化スクリプト
#
# 使い方 (対話モード):
#   ./run_playbook.sh
#
# 使い方 (引数モード・確認フェーズなしで即実行):
#   ./run_playbook.sh <大項目> <小項目> [対象番号]
#   ./run_playbook.sh 2 8 <REPO_URL> <RUNNER_TOKEN>
#
# 例:
#   ./run_playbook.sh 1 2          # 構文チェック
#   ./run_playbook.sh 2 5          # Discord Bot デプロイ
#   ./run_playbook.sh 3 1 2        # shakeserver のみシャットダウン
#   ./run_playbook.sh 2 8 https://github.com/org/repo <TOKEN>
# =====================================================================

set -e

# エラー終了時に一時停止し、bash を起動してWSLが閉じるのを防ぐ
cleanup() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    echo
    echo "[エラーが発生したため、処理を中断しました（ステータスコード: $exit_code）]"
    echo "Enterキーを押すとシェルに戻ります..."
    read -r < /dev/tty   # stdin が閉じていても端末から直接読む
    exec bash < /dev/tty  # --login なしで起動（プロファイルによる即終了を回避）
  fi
}
trap cleanup EXIT

cd "$(dirname "$0")"

# Vaultパスワードファイルを環境変数に設定（毎回の手入力を省略）
export ANSIBLE_VAULT_PASSWORD_FILE="local_config/ansible/credentials/.vault_pass"

PLAYBOOK="ansible-playbook -i local_config/ansible/inventory.ini \
  -e @local_config/ansible/vars.yml \
  -e @local_config/ansible/credentials/vault.yml \
  ansible/site.yml"

# 引数モード判定
USE_ARGS=false
[ -n "$1" ] && USE_ARGS=true

echo "-------------------------------------------------------------"
echo "  IaC Workspace - インフラ検証および本番適用ツール"
echo "-------------------------------------------------------------"

# =====================================================================
# MAIN_MODE の取得
# =====================================================================
if $USE_ARGS; then
  MAIN_MODE="$1"
else
  echo " [1] テスト・検証フェーズ"
  echo " [2] デプロイ反映フェーズ"
  echo " [3] サーバー電源・ライフサイクル操作"
  echo "-------------------------------------------------------------"
  printf "実行する大項目の番号を入力してください (1-3): "
  read -r MAIN_MODE
fi

case "$MAIN_MODE" in
  1) MAIN_LABEL="テスト・検証フェーズ" ;;
  2) MAIN_LABEL="デプロイ反映フェーズ" ;;
  3) MAIN_LABEL="サーバー電源・ライフサイクル操作" ;;
  *) echo "[Error] 無効な大項目番号です: $MAIN_MODE"; exit 1 ;;
esac

# =====================================================================
# SUB_MODE・追加パラメータの取得
# =====================================================================
TARGET_LABEL=""

case "$MAIN_MODE" in

  # ------------------------------------------------------------------
  1) # テスト・検証フェーズ
  # ------------------------------------------------------------------
    if ! $USE_ARGS; then
      echo "-------------------------------------------------------------"
      echo "  テスト・検証フェーズ"
      echo "-------------------------------------------------------------"
      echo " [1] 静的解析実行 (ansible-lint による品質確認)"
      echo " [2] 構文チェック (Ansible標準のシンタックスチェック)"
      echo " [3] 模擬実行 (Dry Run / Check Mode) ※実機に変更は加えません"
      echo "-------------------------------------------------------------"
      printf "実行するテストの番号を入力してください (1-3): "
      read -r SUB_MODE
    else
      SUB_MODE="${2:-}"
    fi
    case "$SUB_MODE" in
      1) SUB_LABEL="静的解析実行 (ansible-lint による品質確認)" ;;
      2) SUB_LABEL="構文チェック (Ansible標準のシンタックスチェック)" ;;
      3) SUB_LABEL="模擬実行 (Dry Run / Check Mode)" ;;
      *) echo "[Error] 無効な小項目番号です: $SUB_MODE"; exit 1 ;;
    esac
    ;;

  # ------------------------------------------------------------------
  2) # デプロイ反映フェーズ
  # ------------------------------------------------------------------
    if ! $USE_ARGS; then
      echo "-------------------------------------------------------------"
      echo "  デプロイ反映フェーズ"
      echo "-------------------------------------------------------------"
      echo " [1]  本番反映実行 (全サービスの一括展開)        (タグなし)"
      echo " [2]  Webアプリのみデプロイ                      (--tags web)"
      echo " [3]  DB (PostgreSQL) のみデプロイ               (--tags postgres)"
      echo " [4]  Minecraft のみデプロイ                     (--tags minecraft)"
      echo " [5]  Discord Bot のみデプロイ                   (--tags ubsleepy)"
      echo " [6]  自動バックアップ のみデプロイ              (--tags ubsleepy_backup)"
      echo " [7]  UPS監視 のみデプロイ                       (--tags ups_exporter)"
      echo " [8]  GitHub Runner (CI/CD) のセットアップ       (--tags github_runner)"
      echo " [9]  Docker環境のセットアップ                   (--tags docker)"
      echo " [10] 監視スタック のみデプロイ                  (--tags monitoring)"
      echo "-------------------------------------------------------------"
      printf "デプロイ対象の番号を入力してください (1-10): "
      read -r SUB_MODE
    else
      SUB_MODE="${2:-}"
    fi
    case "$SUB_MODE" in
      1)  SUB_LABEL="本番反映実行 (全サービスの一括展開)" ;;
      2)  SUB_LABEL="Webアプリのみデプロイ (--tags web)" ;;
      3)  SUB_LABEL="DB (PostgreSQL) のみデプロイ (--tags postgres)" ;;
      4)  SUB_LABEL="Minecraft のみデプロイ (--tags minecraft)" ;;
      5)  SUB_LABEL="Discord Bot のみデプロイ (--tags ubsleepy)" ;;
      6)  SUB_LABEL="自動バックアップのみデプロイ (--tags ubsleepy_backup)" ;;
      7)  SUB_LABEL="UPS監視のみデプロイ (--tags ups_exporter)" ;;
      8)  SUB_LABEL="GitHub Runner のセットアップ (--tags github_runner)" ;;
      9)  SUB_LABEL="Docker環境のセットアップ (--tags docker)" ;;
      10) SUB_LABEL="監視スタックのみデプロイ (--tags monitoring)" ;;
      *) echo "[Error] 無効な小項目番号です: $SUB_MODE"; exit 1 ;;
    esac

    # GitHub Runner は URL とトークンが必要
    if [ "$SUB_MODE" = "8" ]; then
      if $USE_ARGS; then
        REPO_URL="${3:-}"
        RUNNER_TOKEN="${4:-}"
      else
        printf "GitHubインフラリポジトリのURLを入力してください (例: https://github.com/rurutheGeek/infra-repo): "
        read -r REPO_URL
        printf "Runner登録用トークンを入力してください: "
        read -r RUNNER_TOKEN
      fi
      if [ -z "$REPO_URL" ] || [ -z "$RUNNER_TOKEN" ]; then
        echo "[Error] URLまたはトークンが入力されていません。中断します。"
        exit 1
      fi
    fi
    ;;

  # ------------------------------------------------------------------
  3) # サーバー電源・ライフサイクル操作
  # ------------------------------------------------------------------
    if ! $USE_ARGS; then
      echo "-------------------------------------------------------------"
      echo "  サーバー電源・ライフサイクル操作"
      echo "-------------------------------------------------------------"
      echo " [1] 安全なシャットダウン実行 (コンテナ停止後に電源OFF)"
      echo " [2] 安全な再起動実行 (コンテナ停止後にOS再起動)"
      echo "-------------------------------------------------------------"
      printf "実行する電源操作の番号を入力してください (1-2): "
      read -r SUB_MODE
    else
      SUB_MODE="${2:-}"
    fi

    case "$SUB_MODE" in
      1) SUB_LABEL="安全なシャットダウン実行" ;;
      2) SUB_LABEL="安全な再起動実行" ;;
      *) echo "[Error] 無効な小項目番号です: $SUB_MODE"; exit 1 ;;
    esac

    # 操作対象ホストの取得
    if ! $USE_ARGS; then
      echo "-------------------------------------------------------------"
      echo "  $SUB_LABEL"
      echo "-------------------------------------------------------------"
      echo " [1] 全サーバーを一括"
      echo " [2] shakeserver (メイン) のみ"
      echo " [3] tarakoserver (監視) のみ"
      echo " [4] negitoroserver (プロキシ) のみ"
      echo "-------------------------------------------------------------"
      printf "対象の番号を入力してください (1-4): "
      read -r TARGET
    else
      TARGET="${3:-}"
    fi

    case "$TARGET" in
      1) TARGET_LABEL="全サーバー一括";              LIMIT="";                          HOSTS="all" ;;
      2) TARGET_LABEL="shakeserver (メイン)";        LIMIT="--limit shakeserver";       HOSTS="shakeserver" ;;
      3) TARGET_LABEL="tarakoserver (監視)";         LIMIT="--limit tarakoserver";      HOSTS="tarakoserver" ;;
      4) TARGET_LABEL="negitoroserver (プロキシ)";   LIMIT="--limit negitoroserver";    HOSTS="negitoroserver" ;;
      *) echo "[Error] 無効なターゲット番号です: $TARGET"; exit 1 ;;
    esac
    ;;
esac

# =====================================================================
# 実行内容の表示
# =====================================================================
echo "-------------------------------------------------------------"
echo "  実行内容"
echo "-------------------------------------------------------------"
printf "  大項目 [%s] %s\n" "$MAIN_MODE" "$MAIN_LABEL"
printf "  小項目 [%s] %s\n" "$SUB_MODE"  "$SUB_LABEL"
if [ -n "$TARGET_LABEL" ]; then
  printf "  対象   [%s] %s\n" "$TARGET" "$TARGET_LABEL"
fi
if [ "$MAIN_MODE" = "2" ] && [ "$SUB_MODE" = "8" ]; then
  printf "  URL    %s\n" "$REPO_URL"
fi
echo "-------------------------------------------------------------"

# 危険操作（本番デプロイ・電源操作）は対話モードのみ確認プロンプトを出す
# 引数モードでは警告を表示するが自動続行
if [ "$MAIN_MODE" = "2" ] && [ "$SUB_MODE" = "1" ]; then
  echo "警告: 本番環境への実際の適用処理です"
  if ! $USE_ARGS; then
    printf "本当に実行してよろしいですか？ (y/n): "
    read -r CONFIRM
    [[ "$CONFIRM" =~ ^[Yy] ]] || { echo ">>> 中断しました。"; exit 0; }
  fi
fi

if [ "$MAIN_MODE" = "3" ]; then
  echo "!!! 警告: サーバーの電源操作を行います !!!"
  if ! $USE_ARGS; then
    printf "本当に実行してよろしいですか？ (y/n): "
    read -r CONFIRM
    [[ "$CONFIRM" =~ ^[Yy] ]] || { echo ">>> 中断しました。"; exit 0; }
  fi
fi

# =====================================================================
# 実行
# =====================================================================
case "$MAIN_MODE" in

  1)
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
        $PLAYBOOK --syntax-check
        echo ">>> 全Playbookの構文にエラーはありません。"
        ;;
      3)
        echo -e "\n>>> 模擬実行（Check Mode）を開始します..."
        $PLAYBOOK --check
        echo ">>> 模擬実行が完了しました。"
        ;;
    esac
    ;;

  2)
    case "$SUB_MODE" in
      1)
        echo -e "\n>>> 本番環境への適用を開始します..."
        $PLAYBOOK
        echo ">>> 適用処理が正常に完了しました。"
        ;;
      2)
        echo -e "\n>>> Webアプリのみデプロイを開始します..."
        $PLAYBOOK --tags web
        ;;
      3)
        echo -e "\n>>> PostgreSQLのみデプロイを開始します..."
        $PLAYBOOK --tags postgres
        ;;
      4)
        echo -e "\n>>> Minecraftのみデプロイを開始します..."
        $PLAYBOOK --tags minecraft
        ;;
      5)
        echo -e "\n>>> Discord Botのみデプロイを開始します..."
        $PLAYBOOK --tags ubsleepy
        ;;
      6)
        echo -e "\n>>> 自動バックアップのみデプロイを開始します..."
        $PLAYBOOK --tags ubsleepy_backup
        ;;
      7)
        echo -e "\n>>> UPS監視のみデプロイを開始します..."
        $PLAYBOOK --tags ups_exporter
        ;;
      8)
        echo -e "\n>>> GitHub Runnerのデプロイを実行します..."
        $PLAYBOOK --tags github_runner \
          -e "github_repo_url=$REPO_URL" \
          -e "github_runner_token=$RUNNER_TOKEN"
        echo ">>> Runnerのセットアップが完了しました！"
        ;;
      9)
        echo -e "\n>>> Docker環境のセットアップを開始します..."
        $PLAYBOOK --tags docker
        ;;
      10)
        echo -e "\n>>> 監視スタック（Prometheus / Grafana / Loki / Promtail）のみデプロイを開始します..."
        $PLAYBOOK --tags monitoring
        ;;
    esac
    ;;

  3)
    case "$SUB_MODE" in
      1)
        echo -e "\n>>> 安全なシャットダウンを開始します..."
        ansible-playbook \
          -i local_config/ansible/inventory.ini \
          -e @local_config/ansible/vars.yml \
          -e @local_config/ansible/credentials/vault.yml \
          ansible/playbooks/shutdown_servers.yml $LIMIT
        echo ">>> シャットダウン命令の送信が完了しました。"
        ;;
      2)
        echo -e "\n>>> 安全な再起動を開始します..."
        ansible "$HOSTS" \
          -i local_config/ansible/inventory.ini \
          -m reboot --become -B 2 -P 0
        echo ">>> 対象ホストへ再起動命令を送信しました。OSが完全に起動してVPNに再接続されるまで数分間お待ちください。"
        ;;
    esac
    ;;
esac
