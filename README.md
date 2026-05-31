# shake インフラ基盤構成管理リポジトリ

複数台の Raspberry Pi で構成される自宅サーバー環境（shake 基盤）のインフラ構築・構成管理、および各種コンテナアプリケーションのデプロイを完全自動化する IaC（Infrastructure as Code）リポジトリです。

本 README はプロジェクトの入口です。全体像の把握と各ドキュメントへの案内を目的とし、詳細な構成定義や手順は配下のドキュメントに委ねます。

---

## システム構成図

物理・論理の 2 視点で全体像をまとめています。拡大版・各図の解説・再生成手順は [docs/00_構成図.md](docs/00_構成図.md) を参照してください。

### 物理構成（拠点・機材・電源・ネットワーク）
![物理構成図](docs/diagrams/physical.svg)

### 論理構成（サービス・トラフィック・データフロー）
![論理構成図](docs/diagrams/logical.svg)

---

## システムアーキテクチャ（概要）

- プロビジョニング (Terraform): Cloudflare DNS レコード管理、R2 バケット（バックアップ・データ保管用）の自動構築。
- ネットワーク (Tailscale): 3 拠点のノード間をポート開放なしのメッシュ VPN で接続。外部公開は大学拠点のプロキシ（Raspberry Pi Zero 2 W）に集約し、自宅へグローバル IP を露出させない。
- 構成管理・デプロイ (Ansible): OS 基本設定、ファイアウォール（UFW）、監視エージェント、各アプリケーションコンテナの展開・制御。
- 稼働サービス: PostgreSQL 15 / Minecraft (Pixelmon Reforged) / Web + Alexa Skill / Discord Bot (UBSLEEPY)。
- 監視・通知: Prometheus + Grafana + Loki + Alertmanager によるメトリクス・ログ統合、UPS ステータス監視、Discord への能動通知。
- 自動バックアップ: DB・Minecraft ワールド・Bot セーブをそれぞれ日次で Cloudflare R2 へ転送（月次リストアテスト付き）。
- 高可用性: ノードダウン時に Cloudflare Workers（メンテナンス画面）へルーティングを自動フェイルオーバー。

---

## ドキュメント案内

### 構成図
- [docs/00_構成図.md](docs/00_構成図.md) — 物理／論理構成図（Mermaid・D2）と各図の解説。図のソース・出力は [docs/diagrams/](docs/diagrams/) に格納。

### 構築・運用マニュアル（全 10 章 / docs/）
初期セットアップから日々の運用、障害復旧（DR）までの手順を時系列でまとめています。運用引き継ぎの際はこちらを参照してください。

1. [IaC環境構築と初期プロビジョニング](docs/01_IaC環境構築と初期プロビジョニング.md) — WSL2/Ansible/Terraform の準備と全ノード共通設定
2. [ネットワーク基盤](docs/02_ネットワーク基盤.md) — Tailscale VPN、リバースプロキシ、UFW の IP 戦略
3. [機密情報管理](docs/03_機密情報管理.md) — Ansible Vault、Terraform Secret 自動登録、漏洩防止
4. [監視・ログ・通知基盤](docs/04_監視・ログ・通知基盤.md) — Prometheus/Grafana/Loki/Alertmanager/Discord
5. [アプリのコンテナ化と運用](docs/05_アプリのコンテナ化と運用.md) — PostgreSQL/Minecraft/Web+Alexa/Discord Bot
6. [高可用性とシステム堅牢化](docs/06_高可用性とシステム堅牢化.md) — Cloudflare Workers failover/SWAP/Drift/リストアテスト
7. [CI（コード品質と静的検証）](docs/07_CI（コード品質と静的検証）.md) — ansible-lint / terraform validate / Trivy / Plan PR コメント
8. [CD（自動デプロイ）](docs/08_CD（自動デプロイ）.md) — Self-hosted Runner / Repository Dispatch / strategy:free
9. [技術スタックと選定根拠](docs/09_技術スタックと選定根拠.md) — 各ツール採用理由と代替案比較
10. [今後の展望](docs/10_今後の展望.md) — 未着手の補強項目とロードマップ

マニュアルの執筆ガイドライン（章構成・記述規約）は [docs/README.md](docs/README.md) を参照してください。

### IaC 設計・構成定義
- [iac-workspace/README.md](iac-workspace/README.md) — ディレクトリツリー全体像、Ansible Roles 一覧、Terraform 定義、統合管理スクリプト（run_playbook.sh）のメニュー詳細、セキュリティガイドライン。

### リファレンス
- [docs/GitHubActionsワークフローリファレンス.md](docs/GitHubActionsワークフローリファレンス.md) — CI/CD ワークフロー（日本語表示名・トリガー・ジョブ構成・利用シークレット・Discord 通知条件）の一覧。

---

## リポジトリ構成

```text
infra/
├── docs/            # 構築・運用マニュアル（全10章）と構成図
│   └── diagrams/    # 構成図のソース（.d2）と出力（.svg）
├── iac-workspace/   # IaC（構成管理）コード本体（Ansible / Terraform）
└── output/          # 運用ログ・作業日誌
```

各ディレクトリの詳細は配下の README を参照してください。

---

## クイックスタート

本プロジェクトの構成管理・品質検証・電源操作は、統合管理スクリプト [run_playbook.sh](iac-workspace/run_playbook.sh) を通じて対話的に実行します。

```bash
cd iac-workspace
./run_playbook.sh
```

認証情報の準備（Terraform 変数、Ansible Vault パスワード、vault.yml の暗号化）と、メニューの詳細な内訳については [iac-workspace/README.md](iac-workspace/README.md) を参照してください。
