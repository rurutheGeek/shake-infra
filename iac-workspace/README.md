# IaC Workspace (Infrastructure as Code) 設計書・構成定義書

本リポジトリは、自宅ラボおよび各拠点に分散配置された複数の Raspberry Pi ノード群を対象として、OSの基本設定、メッシュVPN構築、監視基盤の展開、および各種コンテナサービス（Web, DB, Minecraft等）の運用管理を完全自動化するための構成管理コード（IaC）群を管理する。

---

## 1. 構築・運用マニュアル案内（docs/）

インフラの構築・移行・運用手順は、以下のマニュアルに時系列順に記載されています。

1. **[01_IaC環境構築と初期プロビジョニング手順.md](../docs/01_IaC環境構築と初期プロビジョニング手順.md)**
   開発環境の準備、Terraform による DNS・R2 自動構築、Ansible 共通設定（スワップ無効化を含む）の適用手順。
2. **[02_TailscaleによるセキュアVPNネットワーク構築手順.md](../docs/02_TailscaleによるセキュアVPNネットワーク構築手順.md)**
   Tailscale VPN を用いた各ノード間のプライベートネットワーク自動構築手順。
3. **[03_監視基盤の構築とDiscordアラート連携手順.md](../docs/03_監視基盤の構築とDiscordアラート連携手順.md)**
   Prometheus / Grafana による多層監視、cAdvisor によるコンテナ監視の自動展開、および統合スクリプトによるデプロイ手順。
4. **[04_リバースプロキシ構築とAnsibleVault機密情報管理手順.md](../docs/04_リバースプロキシ構築とAnsibleVault機密情報管理手順.md)**
   プロキシの構築とSSL秘密鍵管理、および各内部ノードへのトラフィックルーティング手順。
5. **[05_各種アプリのコンテナ移行とバックアップ自動化手順.md](../docs/05_各種アプリのコンテナ移行とバックアップ自動化手順.md)**
   PostgreSQL、Minecraft、Discord Bot コンテナの移行、および Systemd タイマーによる R2 自動バックアップ手順。
6. **[06_インフラ運用の自動化とシステム堅牢化手順.md](../docs/06_インフラ運用の自動化とシステム堅牢化手順.md)**
   DR（ディザスタリカバリ）検証、Ansible Lint 静的解析、自動セキュリティアップデート、Terraform 状態ファイルの R2 クラウド共有化、および Discord 自動電源通知・SWAP無効化の設計仕様。

---

## 2. 統合管理スクリプト（run_playbook.sh）の実行手順

本インフラの構成管理、品質検証、および電源制御は、ルートディレクトリにある `run_playbook.sh` を使用して対話的に実行します。

### 2.1 起動コマンド
```bash
./run_playbook.sh
```

### 2.2 メニュー構成
スクリプトを実行後、表示されるメニューから番号を選択して実行します。

[1] テスト・検証フェーズ
- [1] 静的解析実行（ansible-lint による検証）
- [2] 構文チェック（Ansible 標準のシンタックス確認）
- [3] 模擬実行（Dry Run / Check mode によるシミュレーション）

[2] デプロイ反映フェーズ
- [1] 本番反映実行（全サービスの一括デプロイ）
- [2] Webアプリのみデプロイ
- [3] DB (PostgreSQL) のみデプロイ
- [4] Minecraft のみデプロイ
- [5] Discord Bot のみデプロイ
- [6] 自動バックアップ のみデプロイ
- [7] UPS監視 のみデプロイ

[3] サーバー電源・ライフサイクル操作
- [1] 安全なシャットダウン実行（コンテナ停止後にホストOSを終了。最終確認プロンプトあり）
- [2] 安全な再起動実行（コンテナ停止後にホストOSを再起動。VPN切断によるハングアップ防止機能付き）

---

## 3. ディレクトリツリー全体像

```text
iac-workspace/
├── .ansible-lint              # Ansible Lintの静的解析ルール定義ファイル
├── README.md                  # 本構成定義書
│
├── ansible/                   # Ansible（サーバー構成管理）ルート
│   ├── site.yml               # 全ノードの役割定義を行うメイン・プレイブック
│   ├── inventory.ini          # 接続対象ホストとIPアドレス・SSHユーザーの定義
│   ├── group_vars/
│   │   └── all/
│   │       ├── vars.yml       # 全ホスト共通の環境変数（公開可能情報）
│   │       └── vault.yml      # 暗号化された機密情報（暗号化パスワード等）
│   ├── templates/             # 動的生成される各種設定ファイルの雛形（Jinja2）
│   │   ├── common/            # 自動アップデート設定等のテンプレート
│   │   ├── minecraft/         # Minecraft用 .env 等のテンプレート
│   │   ├── postgres/          # PostgreSQL用 .env 等のテンプレート
│   │   └── web/               # Webアプリケーション用 .env 等のテンプレート
│   ├── files/                 # 固定静的ファイル（スクリプト・Compose定義等）
│   │   ├── minecraft/         # Minecraftバックアップ・リストア関連の資材
│   │   ├── monitoring/        # Prometheus/Grafana等コンテナ設定ファイル
│   │   ├── postgres/          # DB初期化用SQL群
│   │   ├── proxy/             # Nginx Stream / SSLH 等の定義ファイル
│   │   └── web/               # Webアプリの Docker Compose ファイル等
│   ├── secrets/               # 手動で配置する機密バイナリ（SSL秘密鍵等）
│   │   └── web/
│   └── roles/                 # 再利用可能な構成要素（ロール）の本体
│       ├── common/            # 全ノード共通: パッケージ更新、自動パッチ、スワップ無効化
│       ├── exporters/         # 全ノード共通: Prometheus監視エージェントの導入
│       ├── monitoring/        # 監視ノード用: Prometheus, Grafanaスタックの展開
│       ├── proxy/             # プロキシ用: UFW、Nginx Stream、SSLHによる集約
│       ├── ups_exporter/      # 電源監視用: UPSステータス監視モジュールの導入
│       ├── web/               # Webサーバー用: Node.js/Docker構成のWebアプリデプロイ
│       ├── postgres/          # データベース用: コンテナ化されたDBとデータ永続化
│       └── minecraft/         # ゲームサーバー用: Pixelmonコンテナの起動とデータ復元
│
└── terraform/                 # Terraform（クラウド・ネットワーク構成管理）ルート
    ├── main.tf                # Cloudflare DNSレコード、R2バケット等のリソース定義
    └── backend.hcl            # 状態ファイル（Remote State）接続用のシークレット定義
```

---

## 4. 主要コンポーネントの詳細定義

### 4.1 共通インフラ・環境定義
| 対象パス | 役割と定義内容 |
| :--- | :--- |
| `.ansible-lint` | 静的解析器の設定。コードがAnsibleの最新のベストプラクティスに準拠しているかを自動検査する。 |
| `ansible/site.yml` | リポジトリのマスターエントリーポイント。どのサーバーグループに対してどのRole（役割）を割り当てるかを一元管理する設計図。 |
| `ansible/inventory.ini` | 管理対象サーバーのエイリアスとIPアドレス（実IP/Tailscale IP）、管理者SSH接続情報の管理簿。 |

### 4.2 環境変数と機密情報の管理（Vars / Vault）
Ansible設計規約に基づき、環境ごとに流し込まれる値は「構造（テンプレート）」と「データ（値）」に論理分離されている。

| 分類 | ファイルパス | 説明 |
| :--- | :--- | :--- |
| **構造定義 (Jinja2)** | `ansible/templates/**/*.j2` | 各種サービスが読み込む `.env` などのテンプレート。変数部分を `{{ var_name }}` と記述。 |
| **公開値データ** | `ansible/group_vars/all/vars.yml` | DBポート、ユーザー名、R2バケット名、各種公開URLなど、外部公開が可能な固定値データ。 |
| **暗号化機密データ** | `ansible/group_vars/all/vault.yml` | DBのマスターパスワード、Cloudflare APIアクセスキーなど。AES256形式（Ansible Vault）で暗号化保管。 |

### 4.3 Ansible Roles（部品モジュール群）
サーバーに適用する設定群を責務ごとにカプセル化したもの。

| ロール名 | 対象サーバー | 主なタスク内容 |
| :--- | :--- | :--- |
| `common` | 全サーバー | `unattended-upgrades` による自動セキュリティパッチ適用、スワップ機能の完全無効化、および Python インタープリタ自動検出警告の抑制。 |
| `exporters` | 全サーバー | `node_exporter` や `blackbox_exporter` 等を導入し、メトリクス計測を可能にする。 |
| `monitoring` | 監視特化ノード | `prometheus` と `grafana` をコンテナで構築。ダッシュボードへデータを視覚統合する。 |
| `proxy` | ゲートウェイノード | フロントの443/80番ポートへのアクセスを検知。`SSLH` と `Nginx stream` で各内部サービスへ振り分け。 |
| `postgres` | データベースノード | Dockerボリュームによるデータ永続化と `initdb.d` による初期構築を伴う安全な RDBMS 展開。 |
| `minecraft` | ゲームサーバーノード | R2に格納された最新のバックアップアーカイブの特定、自動ダウンローダーとデータ展開、コンテナ起動。 |
| `web` | Webアプリケーション | リポジトリからのGit Pull、SSHデプロイキーの管理、Docker Compose経由でのアプリ実行。 |
| `ups_exporter` | 電源監視ノード | パッケージマネージャ `uv` を用いたモダンなPython仮想環境の構築、I2Cバス経由でのUPS電池情報取得、systemdでのデーモン常駐化。 |
| `ubsleepy` | メインサーバー | Discord Bot コンテナの展開。`stat` モジュールによる逆流防止、および `unarchive` の `cp932` 指定による日本語ファイル名対応。 |
| `ubsleepy_backup` | メインサーバー | `systemd timer` を用いた日次バックアップの構築。R2への自動転送とDiscordアラート送信ロジックの展開。 |

### 4.4 Terraform (Cloud Orchestration)
外部ネットワークインフラ（CDN・DNS・Cloudストレージ）の構成コード。

| ファイル名 | 説明 |
| :--- | :--- |
| `terraform/main.tf` | ドメイン（Aレコード、SRVレコード等）の登録、およびバックアップ保管先であるCloudflare R2バケットのライフサイクル管理。 |
| `terraform/backend.hcl` | ローカルに置くべきでないステートファイル（`terraform.tfstate`）を、Cloudflare R2 of Remote Stateへセキュアにマイグレーションするための接続情報管理用ファイル。 |

---

## 5. セキュリティガイドライン

1. 機密バイナリの取扱  
   ansible/secrets/ 配下に配置する証明書秘密鍵等のバイナリは、Git管理下に置く場合は必ず ansible-vault encrypt で事前暗号化を実行すること。
2. ローカルファイルの除外  
   terraform/backend.hcl など、機密平文情報が記述されたローカルファイルは、絶対にリポジトリにコミットしない運用とする。
3. CI/CDとの連携  
   コード変更時は、事前にローカルまたはCI上で ansible-lint によるチェックを通過した上でマージを行うこと。
