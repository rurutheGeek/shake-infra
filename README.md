# shake インフラ基盤構成管理リポジトリ

複数台の Raspberry Pi で構成される自宅サーバー環境（shake基盤）のインフラ構築・構成管理、および各種コンテナアプリケーションのデプロイを完全自動化するための IaC（Infrastructure as Code）リポジトリです。

---

## システムアーキテクチャ

- プロビジョニング (Terraform): Cloudflare DNSレコード管理、R2バケット（バックアップ・データ保管用）の自動構築。
- ネットワーク (Tailscale): 各ノード間をセキュアなプライベートメッシュVPNで接続。
- 構成管理・デプロイ (Ansible): OS基本設定、ファイアウォール（UFW）、監視エージェント、および各アプリケーションコンテナの展開・制御。
  - 稼働サービス: PostgreSQL 15, Minecraft Reforged, Discord Bot (ubsleepy)
    - 監視基盤: Prometheus + Grafana によるメトリクス可視化、Grafana Loki + Promtail によるログ集約、およびUPS（無停電電源装置）のステータス監視。
    - 自動バックアップ: Systemd Timer と連動した R2 への日次自動バックアップと、Discord への結果通知。
    - 高可用性 (自動フェイルオーバー): 自宅サーバーダウン時に Cloudflare Workers（ミニゲーム付きメンテナンス画面）へルーティングを完全自動で切り替え。

---

## ディレクトリ構成

```text
infra/
├── docs/                                 # 構築・移行手順マニュアル（全7章）
├── iac-workspace/                        # IaC (構成管理) コード本体
│   ├── ansible/                          # サーバー構成・デプロイ定義 (Playbook/Roles)
│   ├── local_config/                     # 使用者ごとの個人設定コンフィグおよび機密情報（平文はGit管理外）
│   │   ├── ansible/                      # Ansible用の設定・変数・鍵情報
│   │   └── terraform/                    # Terraform用の変数・バックエンド設定
│   └── terraform/                        # Cloudflare リソース定義
└── output/                               # 運用ログ・作業日誌
```

より詳細なIaC設計や各Roleの役割、機密情報の管理手法については [iac-workspace/README.md](iac-workspace/README.md) を参照してください。

---

## ドキュメント一覧

初期セットアップから日々の運用、障害復旧（DR）までの手順を時系列でまとめています。運用引き継ぎの際はこちらを参照してください。

1. [IaC環境構築と初期プロビジョニング手順](docs/01_IaC環境構築と初期プロビジョニング手順.md)
2. [TailscaleによるセキュアVPNネットワーク構築手順](docs/02_TailscaleによるセキュアVPNネットワーク構築手順.md)
3. [監視基盤の構築とDiscordアラート連携手順](docs/03_監視基盤の構築とDiscordアラート連携手順.md)
4. [リバースプロキシ構築とAnsibleVault機密情報管理手順](docs/04_リバースプロキシ構築とAnsibleVault機密情報管理手順.md)
5. [各種アプリのコンテナ移行とバックアップ自動化手順](docs/05_各種アプリのコンテナ移行とバックアップ自動化手順.md)
6. [インフラ運用の自動化とシステム堅牢化手順](docs/06_インフラ運用の自動化とシステム堅牢化手順.md)
7. [CI/CDパイプラインと自動デプロイ構築手順](docs/07_CI-CDパイプラインと自動デプロイ構築手順.md)

---

## クイックスタート

本プロジェクトでは、インフラのデプロイや安全な電源操作を直感的に実行できる統合管理スクリプト [run_playbook.sh](iac-workspace/run_playbook.sh) を提供しています。

### 1. 認証情報の準備

1. Terraform 実行用の環境変数 (terraform.tfvars) を用意します。
2. Ansible 実行用の Vault パスワードファイル (.vault_pass) を iac-workspace/local_config/ansible/credentials/ 配下に配置します。
3. 機密情報（パスワードやAPIキー）を定義した vault.yml を暗号化します。
   ```bash
   ansible-vault encrypt iac-workspace/local_config/ansible/credentials/vault.yml
   ```

### 2. 統合管理スクリプトの実行

対話式メニューに従ってアクションを選択するだけで、安全に構成管理を適用できます。

```bash
cd iac-workspace
./run_playbook.sh
```

【主なメニュー構成】
- [1] テスト・検証フェーズ: 構文チェックやドライラン（模擬実行）による安全性の確認。
- [2] デプロイ反映フェーズ: 全サービスの一括展開、または特定アプリ（Web, DB, Minecraft, バックアップ等）の個別反映。
- [3] サーバー電源・ライフサイクル操作: コンテナ群を安全に停止させた上での、ホストOSの一括シャットダウン・再起動（予期せぬ電源断のDiscord通知機能付き）。