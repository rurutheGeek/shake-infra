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
これにより、tarakoserver上のRunnerが処理を受け取り、環境のセットアップとデプロイを行う。

```yaml
name: Auto Deploy from Apps

on:
  workflow_dispatch:
    inputs:
      target:
        description: 'Target application to deploy'
        required: true
        type: choice
        options:
          - ubsleepy
          - shakeweb
  repository_dispatch:
    types:
      - deploy_ubsleepy
      - deploy_shakeweb

jobs:
  deploy:
    runs-on: self-hosted
    steps:
      - name: Checkout Repo
        uses: actions/checkout@v3

      - name: Install Ansible Collections
        run: |
          cd iac-workspace/ansible
          ansible-galaxy collection install -r requirements.yml

      - name: Deploy ubsleepy
        if: github.event.action == 'deploy_ubsleepy' || (github.event_name == 'workflow_dispatch' && github.event.inputs.target == 'ubsleepy')
        run: |
          cd iac-workspace
          export ANSIBLE_HOST_KEY_CHECKING=False
          export ANSIBLE_VAULT_PASSWORD_FILE="~/.vault_pass"
          ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags ubsleepy

      - name: Deploy shake-web
        if: github.event.action == 'deploy_shakeweb' || (github.event_name == 'workflow_dispatch' && github.event.inputs.target == 'shakeweb')
        run: |
          cd iac-workspace
          export ANSIBLE_HOST_KEY_CHECKING=False
          export ANSIBLE_VAULT_PASSWORD_FILE="~/.vault_pass"
          ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags web

      - name: Discord Notification (Success)
        if: success()
        run: |
          TARGET="${{ github.event.action }}"
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            TARGET="manual-${{ github.event.inputs.target }}"
          fi
          if [ -n "${{ secrets.DISCORD_WEBHOOK_URL }}" ]; then
            curl -H "Content-Type: application/json" \
                 -X POST \
                 -d '{"content": "[SUCCESS] デプロイ成功\n対象: `'"$TARGET"'`\nRunner: `tarakoserver`\n詳細: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}"}' \
                 "${{ secrets.DISCORD_WEBHOOK_URL }}"
          else
            echo "DISCORD_WEBHOOK_URL is not set. Skipping notification."
          fi

      - name: Discord Notification (Failure)
        if: failure()
        run: |
          TARGET="${{ github.event.action }}"
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            TARGET="manual-${{ github.event.inputs.target }}"
          fi
          if [ -n "${{ secrets.DISCORD_WEBHOOK_URL }}" ]; then
            curl -H "Content-Type: application/json" \
                 -X POST \
                 -d '{"content": "[FAILED] デプロイ失敗\n対象: `'"$TARGET"'`\nRunner: `tarakoserver`\nログを確認してください: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}"}' \
                 "${{ secrets.DISCORD_WEBHOOK_URL }}"
          else
            echo "DISCORD_WEBHOOK_URL is not set. Skipping notification."
          fi
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

## 7. Discord通知のセットアップ手順

1. 通知を送信したいDiscordのチャンネルの「チャンネルの編集（歯車マーク）」を開く。
2. 「連携サービス」>「ウェブフック」へ進み、「新しいウェブフック」を作成する。
3. ウェブフックの名前（例: `GitHub Deploy Bot`）を設定し、「ウェブフックURLをコピー」をクリックする。
4. インフラリポジトリの `Settings > Secrets and variables > Actions` を開く。
5. `New repository secret` を作成し、名前に `DISCORD_WEBHOOK_URL`、値にコピーしたURLを貼り付けて保存する。

## 8. インフラコードのCI自動テスト

本リポジトリのAnsibleやTerraformのコード品質を保ち、デプロイ時の予期せぬエラーを防ぐため、Pull Request時に自動でコードテスト（CI）が実行されるように設定します。

### CIワークフローの概要

`.github/workflows/ci_infra.yml` に定義されたCIは以下のテストを自動で行います。

*   **トリガー**: Pull Requestが `main` ブランチに対して作成または更新された時、および `main` ブランチに直接プッシュされた時（`iac-workspace` ディレクトリ配下の変更が対象）。
*   **実行環境**: GitHub Actionsの `ubuntu-latest` 環境。
*   **テスト内容**:
    *   **Ansibleの構文チェックとLint**:
        *   Ansibleコードの文法エラーがないか (`ansible-playbook --syntax-check`)。
        *   Ansibleのベストプラクティスに準拠しているか (`ansible-lint`)。
    *   **Terraformのフォーマットとバリデーション**:
        *   Terraformコードの記述スタイルが標準的か (`terraform fmt -check`)。
        *   Terraformのコードに論理的な誤りや設定ミスがないか (`terraform validate`)。

### ワークフローファイルの内容

`.github/workflows/ci_infra.yml`
```yaml
name: CI for Infrastructure

on:
  pull_request:
    branches:
      - main
    paths:
      - 'iac-workspace/**'
      - '.github/workflows/ci_infra.yml'
  push:
    branches:
      - main
    paths:
      - 'iac-workspace/**'
      - '.github/workflows/ci_infra.yml'

jobs:
  ansible-ci:
    name: Ansible Lint & Syntax Check
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: iac-workspace/ansible
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.10'

      - name: Install Ansible and dependencies
        run: |
          python -m pip install --upgrade pip
          pip install ansible-core ansible-lint

      - name: Install Ansible Collections
        run: ansible-galaxy collection install -r requirements.yml

      - name: Run Ansible Syntax Check
        # インベントリがないと構文チェックが通らないモジュールがあるためダミーインベントリを使用（実接続はしない）
        run: ansible-playbook -i inventory.ini site.yml --syntax-check

      - name: Run Ansible Lint
        # .ansible-lint の設定を読み込ませるため上の階層から実行
        working-directory: iac-workspace
        run: ansible-lint ansible/site.yml

  terraform-ci:
    name: Terraform Format & Validate
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: iac-workspace/terraform
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3

      - name: Terraform Format Check
        run: terraform fmt -check

      - name: Terraform Init
        # S3バックエンド等に接続せずに初期化
        run: terraform init -backend=false

      - name: Terraform Validate
        run: terraform validate
```

このCIを導入することで、インフラコードの変更に対する品質と安全性が大幅に向上します。