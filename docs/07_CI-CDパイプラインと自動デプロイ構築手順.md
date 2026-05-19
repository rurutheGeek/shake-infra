# 07 CI/CDパイプラインと自動デプロイ構築手順

本章では、GitHub ActionsのSelf-hosted runner（自己ホスト型ランナー）を監視サーバー（tarakoserver）に構築し、「方針1：インフラリポジトリにデプロイ専用の司令塔を作る」アプローチで自動デプロイ（CD）を実現する手順を解説する。

## CI/CDアーキテクチャの概要

個人アカウント特有の制限（リポジトリ単位のランナー登録）を回避しつつ、セキュアなVPN環境（Tailscale）への自動デプロイを実現するために、**Repository Dispatch**（リポジトリ間通信API）を利用する。

1. **アプリ用リポジトリ (例: ubsleepy)**:
   - PR作成時に自動テスト（CI）を実行。
   - mainブランチにマージされると、GitHub Actionsがインフラ用リポジトリへ「デプロイ要求シグナル（Repository Dispatch）」を送信する。
2. **インフラ用リポジトリ (iac-workspace)**:
   - `tarakoserver`上で待機しているSelf-hosted runnerがシグナルを受信。
   - ランナーがAnsibleを実行し、対象サーバーに対してコンテナの更新と再起動を行う（CD）。

## 1. GitHubパーソナルアクセストークンの発行
アプリリポジトリからインフラリポジトリへAPIシグナルを送るため、権限を持ったトークン（PAT）が必要。

1. GitHubの設定 > Developer settings > Personal access tokens (Fine-grained tokens) へアクセス。
2. **Generate new token** をクリック。
3. `Repository access` で `Only select repositories` を選び、対象となる**インフラ用リポジトリ**を選択。
4. `Permissions` > `Repository permissions` にて **Contents** を `Read and write`（または `Actions` を `Read and write`）に設定し、生成されたトークンをメモする。
5. このトークンを各アプリリポジトリの **Settings > Secrets and variables > Actions** に `INFRA_REPO_DISPATCH_TOKEN` などの名前で登録する。

## 2. インフラリポジトリ（ここ）のランナートークン取得
tarakoserverをインフラリポジトリ専属のランナーとして登録するため、ワンタイムトークンを取得する。

1. GitHubの当インフラ用リポジトリを開く。
2. **Settings > Actions > Runners** へ移動。
3. **New self-hosted runner** をクリック。
4. OSに `Linux`、Architectureに `ARM64`（Raspberry Piの場合。環境に合わせて変更）を選択。
5. 画面に表示される `Configure` セクションの `./config.sh --url ... --token XXXXXXXXXXXXXXXXX` の **トークン部分のみ（XXXXX...）** をメモする（後続のAnsibleで利用）。

## 3. tarakoserverへのRunner導入
Ansibleを用いてRunnerの導入を自動化している。以下のコマンドで対象のサーバーにRunnerをインストールし、サービスとして常駐させる。

```bash
cd iac-workspace
ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags github_runner -e "github_runner_token=手順2で取得したトークン" -e "github_repo_url=https://github.com/rurutheGeek/インフラリポジトリ名"
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

      - name: Deploy ubsleepy
        if: github.event.action == 'deploy_ubsleepy'
        run: |
          # ランナーからAnsibleを実行して特定アプリだけデプロイ
          ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags ubsleepy
```

※ Runner上でAnsibleを実行するため、事前にRunner動作ユーザー(`ansible_admin`等)環境に `.vault_pass` を配置するか、Secretsを利用して環境変数に渡す対応が必要となる場合がある。
