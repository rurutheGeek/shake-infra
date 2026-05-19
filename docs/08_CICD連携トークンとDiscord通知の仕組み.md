# CI/CDの仕組みと連携トークンの役割について

このドキュメントでは、複数のアプリケーションリポジトリからインフラリポジトリへデプロイ命令を送信する仕組み（Repository Dispatch）と、各トークンの役割、Discord通知の設定、およびブランチ戦略について解説する。

## 1. 全体アーキテクチャと仕組み

本プロジェクトでは、リポジトリが「インフラ（Ansible）」と「アプリケーション（ubsleepy等）」に分かれている。
アプリ側のコードが更新された際、VPN内（Tailscale）にある自宅サーバーに対して、インターネット上のGitHub Actionsから直接SSHでデプロイ処理を実行することはできない。

これを解決するため、Repository Dispatch（リポジトリ間通信API）を利用している。

1. アプリ側のGitHub Actionsがテストをパスすると、インフラリポジトリに対して「API（POSTリクエスト）」を送信する。
2. インフラリポジトリは、特定のAPI（例: `deploy_ubsleepy`）を受信すると、専用のワークフロー（`cd_deploy.yml`）を起動する。
3. このワークフローは、自宅の監視サーバー（tarakoserver）にインストールされた「Self-hosted runner（エージェント）」上で実行される。
4. RunnerがVPN内部から各サーバーに対してAnsibleを実行し、コンテナイメージの取得や再起動を行う。

## 2. 各種トークン・シークレットの役割

この仕組みを安全に動かすため、3つの重要な機密情報（シークレット）をGitHubに登録する必要がある。

### ① INFRA_REPO_DISPATCH_TOKEN
- 登録場所: アプリリポジトリ（ubsleepy等）の `Settings > Secrets`
- 正体: インフラリポジトリの操作権限を持った「Personal Access Token (Fine-grained)」
- 役割: アプリ側からインフラ側へ「デプロイしてくれ」というAPIを叩くための「許可証」。このトークンがないと、外部からインフラのワークフローを起動できない。

### ② ANSIBLE_VAULT_PASSWORD
- 登録場所: インフラリポジトリ（ここ）の `Settings > Secrets`
- 正体: `iac-workspace/.vault_pass` に記述しているAnsibleの復号パスワード
- 役割: tarakoserver上のRunnerがAnsibleを実行する際、暗号化された変数（CloudflareのAPIキーなど）を読み取るために必要。ワークフローの中で一時的にファイルとして生成し、実行後に削除される。

### ③ DISCORD_WEBHOOK_URL
- 登録場所: インフラリポジトリ（ここ）の `Settings > Secrets`
- 正体: Discordのチャンネル設定から発行したWebhookのURL（`https://discord.com/api/webhooks/...`）
- 役割: デプロイが成功、または失敗した際に、Discordのチャンネルへ自動で通知メッセージを送信する。

## 3. アプリ側のマージ条件について（mainブランチは必須か？）

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

## 4. Discord通知のセットアップ手順

1. 通知を送信したいDiscordのチャンネルの「チャンネルの編集（歯車マーク）」を開く。
2. 「連携サービス」>「ウェブフック」へ進み、「新しいウェブフック」を作成する。
3. ウェブフックの名前（例: `GitHub Deploy Bot`）を設定し、「ウェブフックURLをコピー」をクリックする。
4. インフラリポジトリの `Settings > Secrets and variables > Actions` を開く。
5. `New repository secret` を作成し、名前に `DISCORD_WEBHOOK_URL`、値にコピーしたURLを貼り付けて保存する。
