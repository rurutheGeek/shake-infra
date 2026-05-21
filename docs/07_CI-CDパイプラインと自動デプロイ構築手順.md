# 07 CI/CDパイプラインと自動デプロイ構築手順

本章では、GitHub ActionsのSelf-hosted runner（自己ホスト型ランナー）を監視サーバー（tarakoserver）に構築し、「方針1：インフラリポジトリにデプロイ専用の司令塔を作る」アプローチで自動デプロイ（CD）を実現する手順、および各連携トークンの役割やDiscord通知の設定について解説する。

## CI/CDアーキテクチャの概要

個人アカウント特有の制限（リポジリ単位のランナー登録）を回避しつつ、セキュアなVPN環境（Tailscale）への自動デプロイを実現するために、Repository Dispatch（リポジリ間通信API）を利用する。

1. アプリ用リポジリ (例: ubsleepy):
   - PR作成時に自動テスト（CI）を実行。
   - mainブランチにマージされると、GitHub Actionsがインフラ用リポジリへ「デプロイ要求シグナル（Repository Dispatch）」を送信する。
2. インフラ用リポジリ (iac-workspace):
   - `tarakoserver`上で待機しているSelf-hosted runnerがシグナルを受信。
   - ランナーがAnsibleを実行し、対象サーバーに対してコンテナの更新と再起動を行う（CD）。

## 1. GitHubパーソナルアクセストークンの発行
アプリリポジリからインフラリポジリへAPIシグナルを送るため、権限を持ったトークン（PAT）が必要。

1. GitHubの `Settings > Developer settings > Personal access tokens (Fine-grained tokens)` へアクセス。
2. Generate new token をクリック。
3. `Repository access` で `Only select repositories` を選び、対象となるインフラリポジリを選択。
4. `Permissions` > `Repository permissions` にて `Contents` を `Read and write` に設定し、生成されたトークンをメモする。
5. このトークンを各アプリリポジリの `Settings > Secrets and variables > Actions` に `INFRA_REPO_DISPATCH_TOKEN` などの名前で登録する。

## 2. インフラリポジリ（ここ）のランナートークン取得
tarakoserverをインフラリポジリ専属のランナーとして登録するため、ワンタイムトークンを取得する。

1. GitHubの当インフラ用リポジリを開く。
2. `Settings > Actions > Runners` へ移動。
3. `New self-hosted runner` をクリック。
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
3. プロンプトに従い、インフラリポジリのURLと手順2で取得したトークンを入力する。

※ 手動で実行する場合は以下のコマンドを用いる。
```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags github_runner -e "github_runner_token=取得したトークン" -e "github_repo_url=https://github.com/rurutheGeek/インフラリポジリ名"
```

## 4. アプリケーションリポジリのWorkflow設定例
アプリ側のリポジリ（例: `.github/workflows/deploy.yml`）に以下を記述する。

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
          repository: rurutheGeek/インフラリポジリ名
          event-type: deploy_ubsleepy # アプリごとに変える
```

## 5. インフラリポジリのWorkflow設定例
インフラリポジリ（ここ）の `.github/workflows/cd_deploy.yml` に以下を記述する。
これにより、tarakoserver上のRunnerが処理を受け取る。

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
        if: github.event.action == 'deploy_shakeweb' || (github.event_name == "workflow_dispatch" && github.event.inputs.target == 'shakeweb')
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
- 登録場所: アプリリポジリ（ubsleepy等）の `Settings > Secrets`
- 正体: インフラリポジリの操作権限を持った「Personal Access Token (Fine-grained)」
- 役割: アプリ側からインフラ側へ「デプロイしてくれ」というAPIを叩くための「許可証」。このトークンがないと、外部からインフラのワークフローを起動できない。

### ② DISCORD_WEBHOOK_URL
- 登録場所: インフラリポジリ（ここ）の `Settings > Secrets`
- 正体: Discordのチャンネル設定から発行したWebhookのURL（`https://discord.com/api/webhooks/...`）
- 役割: デプロイが成功、または失敗した際に、Discordのチャンネルへ自動で通知メッセージを送信する。

> ※補足: `tarakoserver` にデプロイされるGitHub Runnerには、Ansibleが他のサーバーへSSH接続するための秘密鍵（`id_rsa`）と、機密変数を復号するためのVaultパスワード（`.vault_pass`）が自動構築時にセキュアに配置されるため、これらをGitHub Secretsに登録する必要はない。

## 7. トークンとWebhook URLの自動登録（Terraform）

GitHubのブラウザ画面から手動でシークレットを登録する手間とミスを省くため、本プロジェクトではTerraform（GitHub Provider）を利用してSecretの一元管理・自動登録を行っている。

### ① 事前準備: Terraform用GitHubトークンの取得
TerraformがリポジリのSecretを操作できるよう、最初の一回のみ権限を持ったトークンを取得する。
1. GitHubの `Settings > Developer settings > Personal access tokens` へアクセスし、トークン（PAT）を発行する。
2. 権限としてリポジリの `Administration`, `Secrets` （Fine-grained PATの場合は該当項目）を付与し、生成された値をメモする。

### ② 事前準備: Discord Webhookの取得
1. 通知を送信したいDiscordのチャンネルの「チャンネルの編集（歯車マーク）」を開く。
2. 「連携サービス」>「ウェブフック」へ進み、「新しいウェブフック」を作成する。
3. ウェブフックの名前を設定し、「ウェブフックURLをコピー」をクリックする。

### ③ TerraformによるSecretの一括反映
取得した各種機密情報をTerraformの変数ファイル（例: `iac-workspace/terraform/terraform.tfvars`）に記述し、適用する。

```hcl
github_token              = "ghp_xxxxxxxxxxxx"                           # ①で取得したTerraform用トークン
discord_webhook_url       = "https://discord.com/api/webhooks/xxxx/xxxx" # ②で取得したDiscord Webhook URL
infra_repo_dispatch_token = "github_pat_xxxxxxxxx"                       # 手順1で取得したデプロイAPI用トークン
```

以下のコマンドを実行して反映させる。

```bash
cd iac-workspace/terraform
terraform init
terraform apply
```

この操作により、インフラリポジリに `DISCORD_WEBHOOK_URL` が、アプリリポジリ（ubsleepy等）に `INFRA_REPO_DISPATCH_TOKEN` が、それぞれGitHub ActionsのSecretsとして自動的に登録される。

## 8. インフラコードのCI自動テスト

本リポジリのAnsibleやTerraformのコード品質を保ち、デプロイ時の予期せぬエラーを防ぐため、Pull Request時に自動でコードテスト（CI）が実行されるように設定します。

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

## 9. `git-secrets` による機密情報漏洩対策

`git-secrets` は、AWSのアクセスキーやその他の機密情報が誤ってGitリポジトリにコミットされることを防ぐためのツールです。本プロジェクトでは、リポジトリローカルのプリコミットフックとして `git-secrets` を導入し、さらにAnsible Vaultの暗号化忘れや `terraform.tfvars` の誤コミットもチェックするよう設定しています。

### 導入手順 (開発者向け)

1. **`git-secrets` のインストール**:
   お使いのOSのパッケージマネージャーを使用して `git-secrets` をインストールします。
   （例: `sudo apt-get install git-secrets`）

2. **リポジトリへの `git-secrets` の有効化**:
   プロジェクトのルートディレクトリで以下のコマンドを実行します。
   これにより、Gitフック（`pre-commit`, `commit-msg`, `prepare-commit-msg`）が設定されます。
   ```bash
   git secrets --install
   ```

3. **デフォルトルールとカスタムルールの登録**:
   AWSの機密情報パターンと、本プロジェクト独自の機密情報パターンを登録します。
   ```bash
   git secrets --register-aws
   git secrets --add '^\$ANSIBLE_VAULT' # Ansible Vaultのヘッダパターン (暗号化チェック用)
   git secrets --add-forbidden 'iac-workspace/terraform/terraform.tfvars' # terraform.tfvars のコミットを禁止
   ```
   **注意**: `git secrets --add-forbidden` はファイルの中身ではなく、`git add` されたパスをチェックするカスタムフックを別途作成して導入する必要があります。現在の実装では、`git-secrets` のフックに続けて、Ansible Vault の暗号化チェックと `terraform.tfvars` のコミットブロックを行うカスタムスクリプトが `.git/hooks/pre-commit` に追記されています。

### チェックされる項目

*   **一般的な機密情報**: AWSアクセスキー、AWSシークレットキー、一般的なAPIキーパターンなど (`git secrets --register-aws` によるもの)。
*   **Ansible Vaultファイルの未暗号化**: `iac-workspace/ansible/group_vars/all/vault.yml` が平文でコミットされようとしていないか。
*   **Terraform変数ファイル**: `iac-workspace/terraform/terraform.tfvars` がコミットされようとしていないか。

これらのチェックは `git commit` 実行時に自動的に行われ、機密情報が含まれている場合はコミットが中断されます。