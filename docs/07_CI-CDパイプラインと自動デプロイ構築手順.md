# 07 CI/CDパイプラインと自動デプロイ構築手順

本章では、GitHub ActionsのSelf-hosted runner（自己ホスト型ランナー）を監視サーバー（tarakoserver）に構築し、「方針1：インフラリポジトリにデプロイ専用の司令塔を作る」アプローチで自動デプロイ（CD）を実現する手順、および各連携トークンの役割やDiscord通知の設定について解説する。

## CI/CDアーキテクチャの概要

個人アカウント特有の制限（リポジトリ単位のランナー登録）を回避しつつ、セキュアなVPN環境（Tailscale）への自動デプロイを実現するために、Repository Dispatch（リポジトリ間通信API）を利用する。

1. アプリ用リポジトリ (例: ubsleepy):
   - PR作成時に自動テスト（CI）を実行。
   - mainブランチにマージされると、GitHub Actionsがインフラ用リポジトリへ「デプロイ要求シグナル（Repository Dispatch）」を送信する。
2. インフラ用リポジトリ (iac-workspace):
   - `tarakoserver`上で待機しているSelf-hosted runnerがシグナルを受信。
   - ランナーがAnsibleを実行し、対象サーバーに対してコンテナの更新と再起動を行う（CD）。

## 1. GitHubパーソナルアクセストークンの発行
アプリリポジトリからインフラリポジトリへAPIシグナルを送るため、権限を持ったトークン（PAT）が必要。

1. GitHubの設定 > Developer settings > Personal access tokens (Fine-grained tokens) へアクセス。
2. Generate new token をクリック。
3. `Repository access` で `Only select repositories` を選び、対象となるインフラ用リポジトリを選択。
4. `Permissions` > `Repository permissions` にて Contents を Read and write に設定し、生成されたトークンをメモする。
5. このトークンを各アプリリポジトリの `Settings > Secrets and variables > Actions` に `INFRA_REPO_DISPATCH_TOKEN` などの名前で登録する。

## 2. インフラリポジトリ（ここ）のランナートークン取得
tarakoserverをインフラリポジトリ専属のランナーとして登録するため、ワンタイムトークンを取得する。

1. GitHubの当インフラ用リポジトリを開く。
2. `Settings > Actions > Runners` へ移動。
3. New self-hosted runner をクリック。
4. OSに `Linux`、Architectureに `ARM64`（Raspberry Piの場合。環境に合わせて変更）を選択。
5. 画面に表示される `Configure` セクションの `./config.sh --url ... --token XXXXXXXXXXXXXXXXX` の トークン部分のみ（XXXXX...） をメモする（後続のAnsibleで利用）。

## 3. tarakoserverへのRunner導入
Ansibleを用いてRunnerの導入を自動化している。用意されている運用スクリプトから対話的に実行可能。

1. 作業環境のシェルから `run_playbook.sh` を実行する。
   ```bash
   cd iac-workspace
   ./run_playbook.sh
   ```
2. メニューから `[2] デプロイ反映フェーズ` -> `[8] GitHub Runner (CI/CD) のセットアップ` を選択する。
3. プロンプトに従い、インフラリポジトリのURLと手順2で取得したトークンを入力する。

※ 手動で実行する場合は以下のコマンドを用いる。
```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags github_runner -e "github_runner_token=取得したトークン" -e "github_repo_url=https://github.com/rurutheGeek/インフラリポジトリ名"
```

## 4. アプリケーションリポジトリのWorkflow設定例
アプリ側のリポジトリ（例: `.github/workflows/deploy.yml`）に以下を記述する。

```yaml
name: Trigger Deploy

on:
  push:
    branches:
      - main

jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Infrastructure Deployment
        uses: peter-evans/repository-dispatch@v2
        with:
          token: ${{ secrets.INFRA_REPO_DISPATCH_TOKEN }}
          repository: rurutheGeek/インフラリポジトリ名
          event-type: deploy_ubsleepy # アプリごとに変える
```

## 5. インフラリポジトリのWorkflow設定例
インフラリポジトリ（ここ）の `.github/workflows/cd_deploy.yml` に以下を記述する。
これにより、tarakoserver上のRunnerが処理を受け取る。

```yaml
name: Auto Deploy from Apps

on:
  repository_dispatch:
    types:
      - deploy_ubsleepy
      # - deploy_shakeweb などのように追加していく

jobs:
  deploy:
    # 自身のサーバー上のランナーで実行する指定
    runs-on: self-hosted
    steps:
      - name: Checkout Repo
        uses: actions/checkout@v3

      - name: Setup Vault Password
        run: echo "${{ secrets.ANSIBLE_VAULT_PASSWORD }}" > ./iac-workspace/.vault_pass

      - name: Deploy ubsleepy
        if: github.event.action == 'deploy_ubsleepy'
        run: |
          cd iac-workspace
          ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags ubsleepy

      - name: Cleanup Vault Password
        if: always()
        run: rm -f ./iac-workspace/.vault_pass

      - name: Discord Notification (Success)
        if: success()
        run: |
          curl -H "Content-Type: application/json" \
               -X POST \
               -d '{"content": "[SUCCESS] デプロイ成功\n対象: `'""${{ github.event.action }}"'\nRunner: `tarakoserver`\n詳細: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}"}' \
               ${{ secrets.DISCORD_WEBHOOK_URL }}

      - name: Discord Notification (Failure)
        if: failure()
        run: |
          curl -H "Content-Type: application/json" \
               -X POST \
               -d '{"content": "[FAILED] デプロイ失敗\n対象: `'"${{ github.event.action }}"'`\nRunner: `tarakoserver`\nログを確認してください: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}"}' \
               ${{ secrets.DISCORD_WEBHOOK_URL }}
```

## 6. 各種トークン・シークレットの役割

この仕組みを安全に動かすため、2つの重要な機密情報（シークレット）をGitHubに登録する必要がある。

### ① INFRA_REPO_DISPATCH_TOKEN
- 登録場所: アプリリポジトリ（ubsleepy等）の `Settings > Secrets`
- 正体: インフラリポジトリの操作権限を持った「Personal Access Token (Fine-grained)」
- 役割: アプリ側からインフラ側へ「デプロイしてくれ」というAPIを叩くための「許可証」。このトークンがないと、外部からインフラのワークフローを起動できない。

### ② DISCORD_WEBHOOK_URL
- 登録場所: インフラリポジトリ（ここ）の `Settings > Secrets`
- 正体: Discordのチャンネル設定から発行したWebhookのURL（`https://discord.com/api/webhooks/...`）
- 役割: デプロイが成功、または失敗した際に、Discordのチャンネルへ自動で通知メッセージを送信する。

> ※補足: `tarakoserver` にデプロイされるGitHub Runnerには、Ansibleが他のサーバーへSSH接続するための秘密鍵（`id_rsa`）と、機密変数を復号するためのVaultパスワード（`.vault_pass`）が自動構築時にセキュアに配置されるため、これらをGitHub Secretsに登録する必要はない。

## 7. アプリ側のマージ条件について（mainブランチは必須か？）

結論から言うと、必ずしも main ブランチである必要はない。

アプリ側の `.github/workflows/deploy.yml`（APIを送信するワークフロー）の `on`（トリガー条件）を書き換えることで、どのブランチのアクションでデプロイするかを自由に決定できる。

### [パターンA] mainにマージされた時のみデプロイ（推奨・本番環境向け）
最も一般的な構成。品質が担保されたコードのみが本番サーバーに反映される。
```yaml
on:
  push:
    branches:
      - main
```

### [パターンB] 特定の開発用ブランチが更新された時にデプロイ（検証環境向け）
たとえば `develop` や `staging` というブランチを作っておき、そこにPushされた際にデプロイする設定。
```yaml
on:
  push:
    branches:
      - develop
```

### [パターンC] 手動で任意のタイミングでデプロイ
ブランチに関わらず、GitHubのブラウザ画面から「Run workflow」ボタンを押した時にだけ実行する設定。
```yaml
on:
  workflow_dispatch:
```

共同開発の初期段階で、頻繁にサーバー上で動作確認をしたい場合は、パターンB（開発用ブランチ）やパターンC（手動実行）を組み合わせるとスムーズである。

## 8. Discord通知のセットアップ手順

1. 通知を送信したいDiscordのチャンネルの「チャンネルの編集（歯車マーク）」を開く。
2. 「連携サービス」>「ウェブフック」へ進み、「新しいウェブフック」を作成する。
3. ウェブフックの名前（例: `GitHub Deploy Bot`）を設定し、「ウェブフックURLをコピー」をクリックする。
4. インフラリポジトリの `Settings > Secrets and variables > Actions` を開く。
5. `New repository secret` を作成し、名前に `DISCORD_WEBHOOK_URL`、値にコピーしたURLを貼り付けて保存する。
