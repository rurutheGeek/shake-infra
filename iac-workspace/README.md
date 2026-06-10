# IaC Workspace (Infrastructure as Code) 設計書・構成定義書

本リポジトリは、自宅ラボおよび各拠点に分散配置された複数の Raspberry Pi ノード群を対象として、OSの基本設定、メッシュVPN構築、監視基盤の展開、および各種コンテナサービス（Web, DB, Minecraft等）の運用管理を完全自動化するための構成管理コード（IaC）群を管理する。

---

## 1. 構築・運用マニュアル案内（docs/）

インフラの構築・移行・運用手順は、以下のマニュアルに時系列順に記載されています。

1. [01_IaC環境構築と初期プロビジョニング.md](../docs/01_IaC環境構築と初期プロビジョニング.md)
   WSL2/Ansible/Terraform の準備、ansible.cfg 性能最適化、SSH 鍵の生成、全ノード共通の自動アップデートとスワップ無効化、変数設計。
2. [02_ネットワーク基盤.md](../docs/02_ネットワーク基盤.md)
   ノードの物理配置と役割マッピング、Tailscale メッシュ VPN、SSLH+Nginx Stream のリバースプロキシ、UFW の 3 階層 IP 戦略。
3. [03_機密情報管理.md](../docs/03_機密情報管理.md)
   Ansible Vault・Terraform GitHub Provider による Secret 自動登録（8 種）・pre-commit/detect-secrets による漏洩防止の 3 層構造。
4. [04_監視・ログ・通知基盤.md](../docs/04_監視・ログ・通知基盤.md)
   Prometheus/Grafana/Loki/Alertmanager/cAdvisor/UPS Exporter の展開、ライフサイクル通知、コンテナ死活監視と Discord アラート。
5. [05_アプリのコンテナ化と運用.md](../docs/05_アプリのコンテナ化と運用.md)
   PostgreSQL/Minecraft/Web+Alexa/Discord Bot のコンテナ化、SHA 比較スマート同期、SSL 期限監視、世代管理付き自動バックアップ。
6. [06_高可用性とシステム堅牢化.md](../docs/06_高可用性とシステム堅牢化.md)
   Cloudflare Workers 自動フェイルオーバー、Unattended Upgrades、SWAP 完全無効化、Terraform Remote State と週次 Drift 検知、安全シャットダウン、月次リストアテスト。
7. [07_CI（コード品質と静的検証）.md](../docs/07_CI（コード品質と静的検証）.md)
   ansible-lint、terraform fmt/validate、Terraform Plan の PR 自動コメント、Trivy 脆弱性スキャン。
8. [08_CD（自動デプロイ）.md](../docs/08_CD（自動デプロイ）.md)
   セルフホストランナーの Docker 化、Repository Dispatch によるアプリ→インフラの連携、strategy:free による並列実行。
9. [09_技術スタックと選定根拠.md](../docs/09_技術スタックと選定根拠.md)
   Tailscale/SSLH/Prometheus/Loki/R2/Cloudflare Workers/uv/Trivy など各ツールの採用理由と代替案比較。
10. [10_今後の展望.md](../docs/10_今後の展望.md)
    未着手の補強項目とロードマップ。

---

## 2. 統合管理スクリプト（run_playbook.sh）の実行手順

本インフラの構成管理、品質検証、および電源制御は、ルートディレクトリにある [run_playbook.sh](run_playbook.sh) を使用して対話的に実行します。

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
- [1]  本番反映実行（全サービスの一括デプロイ）
- [2]  Webアプリのみデプロイ
- [3]  DB (PostgreSQL) のみデプロイ
- [4]  Minecraft のみデプロイ
- [5]  Discord Bot のみデプロイ
- [6]  自動バックアップのみデプロイ
- [7]  UPS監視のみデプロイ
- [8]  GitHub Runner (CI/CD) のセットアップ
- [9]  Docker環境のセットアップ
- [10] 監視スタックのみデプロイ

[3] サーバー電源・ライフサイクル操作
- [1] 安全なシャットダウン実行（コンテナ停止後にホストOSを終了。最終確認プロンプトあり）
- [2] 安全な再起動実行（コンテナ停止後にホストOSを再起動。VPN切断によるハングアップ防止機能付き）

  ※サーバー電源・ライフサイクル操作の対象として、全サーバー一括または特定ホスト（shakeserver / tarakoserver / negitoroserver）を選択できる。

---

## 3. ディレクトリツリー全体像

```text
iac-workspace/
├── .ansible-lint              # Ansible Lintの静的解析ルール定義ファイル
├── README.md                  # 本構成定義書
├── local_config/              # 使用者ごとの個人設定コンフィグおよび機密情報（平文はGit管理外）
│   ├── ansible/               # Ansible用の設定ファイル
│   │   ├── inventory.ini.example # インベントリ定義用テンプレート
│   │   ├── vars.yml.example   # 公開変数用テンプレート
│   │   └── credentials/       # SSH鍵やパスワードなどの機密ファイル
│   │       ├── id_rsa.example # SSH秘密鍵用テンプレート
│   │       ├── vault_pass.example # Ansible Vaultパスワード用テンプレート
│   │       ├── vault.yml.example # 暗号化変数用テンプレート
│   │       ├── id_rsa.enc     # 暗号化されたデフォルトの秘密鍵
│   │       ├── vault_pass.enc # 暗号化されたデフォルトのパスワード
│   │       ├── vault.yml.enc  # 暗号化されたデフォルトの変数
│   │       └── key.pem.example # Webサーバー用SSL秘密鍵のテンプレート
│   │
│   └── terraform/             # Terraform用の設定ファイル
│       ├── terraform.tfvars.example # Terraform変数用テンプレート
│       └── backend.hcl.example # Terraformバックエンド用テンプレート
│
├── ansible/                   # Ansible（サーバー構成管理）ルート
│   ├── site.yml               # 全ノードの役割定義を行うメイン・プレイブック
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
    └── worker_scripts/        # 障害時に配信されるメンテナンス画面のJS/HTML
```

---

## 4. 主要コンポーネントの詳細定義

### 4.1 共通インフラ・環境定義
| 対象パス | 役割と定義内容 |
| :--- | :--- |
| `[.ansible-lint](.ansible-lint)` | 静的解析器の設定。コードがAnsibleの最新のベストプラクティスに準拠しているかを自動検査する。 |
| `[ansible/site.yml](ansible/site.yml)` | リポジトリのマスターエントリーポイント。どのサーバーグループに対してどのRole（役割）を割り当てるかを一元管理する設計図。 |
| `ansible/inventory.ini` | 管理対象サーバーのエイリアスとIPアドレス（実IP/Tailscale IP）、管理者SSH接続情報の管理簿。 |

### 4.2 環境変数と機密情報の管理（Vars / Vault）
Ansible設計規約に基づき、環境ごとに流し込まれる値は「構造（テンプレート）」と「データ（値）」に論理分離されている。

| 分類 | ファイルパス | 説明 |
| :--- | :--- | :--- |
| 構造定義 (Jinja2) | `[ansible/templates](ansible/templates)/**/*.j2` | 各種サービスが読み込む `.env` などのテンプレート。変数部分を `{{ var_name }}` と記述。 |
| 公開値データ | `local_config/ansible/vars.yml` | DBポート、ユーザー名、R2バケット名、各種公開URLなど、外部公開が可能な固定値データ。 |
| 暗号化機密データ | `local_config/ansible/credentials/vault.yml` | DBのマスターパスワード、Cloudflare APIアクセスキーなど。AES256形式（Ansible Vault）で暗号化保管。 |
| 個人設定データ（平文） | `local_config/ansible/` および `local_config/terraform/` 配下 | 各自の環境におけるホスト構成、初期IPアドレス、SSH秘密鍵や暗号パスワード、Terraform変数など。平文の実ファイルはGit管理外とする。 |

### 4.3 Ansible Roles（部品モジュール群）
サーバーに適用する設定群を責務ごとにカプセル化したもの。

| ロール名 | 対象サーバー | 主なタスク内容 |
| :--- | :--- | :--- |
| `[common](ansible/roles/common)` | 全サーバー | `unattended-upgrades` による自動セキュリティパッチ適用、スワップ機能の完全無効化、および Python インタープリタ自動検出警告の抑制。 |
| `[exporters](ansible/roles/exporters)` | 全サーバー | `node_exporter` や `blackbox_exporter` 等を導入し、メトリクス計測を可能にする。 |
| `[monitoring](ansible/roles/monitoring)` | 監視特化ノード | `prometheus` と `grafana` をコンテナで構築。ダッシュボードへデータを視覚統合する。 |
| `[proxy](ansible/roles/proxy)` | ゲートウェイノード | フロントの443/80番ポートへのアクセスを検知。`SSLH` と `Nginx stream` で各内部サービスへ振り分け。 |
| `[postgres](ansible/roles/postgres)` | データベースノード | Dockerボリュームによるデータ永続化と `initdb.d` による初期構築を伴う安全な RDBMS 展開。 |
| `[minecraft](ansible/roles/minecraft)` | ゲームサーバーノード | R2に格納された最新のバックアップアーカイブの特定、自動ダウンローダーとデータ展開、コンテナ起動。 |
| `[web](ansible/roles/web)` | Webアプリケーション | 複数リポジトリ（shake-web / pkhack / ayahuya / pokebs_alexaskill）の Git Pull、SSHデプロイキー管理、Docker Compose 経由でのアプリ実行。単一 Nginx がサブドメイン（apex / pkhack. / shake. / ayahuya.）を server_name で振り分ける（shake-web 3分割）。 |
| `[ups_exporter](ansible/roles/ups_exporter)` | 電源監視ノード | パッケージマネージャ `uv` を用いたモダンなPython仮想環境の構築、I2Cバス経由でのUPS電池情報取得、systemdでのデーモン常駐化。 |
| `[ubsleepy](ansible/roles/ubsleepy)` | メインサーバー | Discord Bot コンテナの展開。`stat` モジュールによる逆流防止、および `unarchive` の `cp932` 指定による日本語ファイル名対応。 |
| `[ubsleepy_backup](ansible/roles/ubsleepy_backup)` | メインサーバー | `systemd timer` を用いた日次バックアップの構築。R2への自動転送とDiscordアラート送信ロジックの展開。 |

### 4.4 Terraform (Cloud Orchestration)
外部ネットワークインフラ（CDN・DNS・Cloudストレージ）の構成コード。

| ファイル名 | 説明 |
| :--- | :--- |
| `[terraform/main.tf](terraform/main.tf)` | ドメイン（Aレコード、SRVレコード等）の登録、バックアップ保管先であるCloudflare R2バケットの管理、および自動フェイルオーバー用Cloudflare Workersのルーティング定義。 |
| `terraform/backend.hcl` | ローカルに置くべきでないステートファイル（`terraform.tfstate`）を、Cloudflare R2 の Remote Stateへセキュアにマイグレーションするための接続情報管理用ファイル。 |
| `[terraform/worker_scripts](terraform/worker_scripts)/` | 障害時にCloudflare Edgeから直接配信される503メンテナンス画面（ミニゲーム付き）のHTML/JSファイル群。 |

---

## 5. 高可用性（自動フェイルオーバー）の仕組み

監視基盤（Prometheus/Alertmanager）とTerraformを連携させ、完全無料・自動の障害切り替えを実現しています。

1. ダウン検知: `tarakoserver` のPrometheusが自宅のプロキシサーバーへのHTTP疎通を監視。
2. 自動ON: 30秒間のダウンを検知すると、AlertmanagerがローカルのPython製Webhookサーバーへ通知。Webhookサーバーが自動的に [toggle_maintenance.sh](toggle_maintenance.sh) on を実行し、Cloudflareのルーティングを事前にデプロイされたミニゲーム付きメンテナンス画面（Workers）へ瞬時に切り替えます。
3. 自動OFF: プロキシサーバーが復旧すると解決アラートが発火し、Webhookサーバーが [toggle_maintenance.sh](toggle_maintenance.sh) off を実行。自動で元のルーティングへ戻します。
※ 実行と同時にDiscordへもステータスが通知されます。

---

## 6. セキュリティガイドライン

1. 機密バイナリの取扱  
   local_config/ansible/credentials/ 配下に配置する証明書秘密鍵等のバイナリは、Git管理下に置く場合は必ず ansible-vault encrypt で事前暗号化を実行すること。
2. ローカルファイルの除外  
   local_config/ansible/ や local_config/terraform/ 配下に配置する inventory.ini, id_rsa, .vault_pass, vault.yml, key.pem, terraform.tfvars, backend.hcl などの各自のコンフィグおよび機密平文情報は、絶対にリポジトリにコミットしない運用とする。 [.gitignore](.gitignore) により自動で除外設定がなされている。
3. CI/CDとの連携  
   コード変更時は、事前にローカルまたはCI上で ansible-lint によるチェックを通過した上でマージを行うこと。
