# GitHub Actions ワークフローリファレンス

本ドキュメントは、リポジトリの `.github/workflows/` に定義された CI/CD ワークフローの目的・トリガー・処理内容を一覧化したリファレンスである。各ワークフローは GitHub Actions の画面に日本語の表示名で現れる。表示名と実体ファイルの対応、利用するシークレット、Discord 通知の条件をまとめる。

詳細な設計思想は [07_CI（コード品質と静的検証）.md](07_CI（コード品質と静的検証）.md) と [08_CD（自動デプロイ）.md](08_CD（自動デプロイ）.md) を参照のこと。本書はそれらの「どのワークフローが何をするか」を素早く把握するための索引である。

## 0. ワークフロー一覧

| 表示名 | 実体ファイル | 主なトリガー | 目的 |
| :--- | :--- | :--- | :--- |
| インフラCI（コード検証） | `.github/workflows/ci_infra.yml` | main への PR / push | マージ前のコード品質・構文・脆弱性・テスト検証 |
| アプリからの自動デプロイ | `.github/workflows/cd_deploy.yml` | アプリ側からの連携 / 手動 | shake-web・pkhack・ayahuya・ubsleepy の本番デプロイ |
| Terraform ドリフト検知 | `.github/workflows/terraform_drift.yml` | 毎週月曜 / 手動 | コードとクラウド実態の乖離検知 |

実行環境は、インフラCIとドリフト検知が GitHub ホストランナー（ubuntu-latest）、自動デプロイのみ自宅の tarakoserver 上のセルフホストランナーである。

---

## 1. インフラCI（コード検証）

ファイル: `.github/workflows/ci_infra.yml`

### 目的
main ブランチへの変更（`iac-workspace/**` またはワークフロー自身の更新）を対象に、本番へ反映する前のコード検証を自動実行する。本番サーバーには接続しない。

### トリガー
- `iac-workspace/**` を含む main 向けの pull_request
- 同パスの main への push

### ジョブ構成
| ジョブ表示名 | ジョブID | 内容 |
| :--- | :--- | :--- |
| Ansible 静的解析・構文チェック | `ansible-ci` | `ansible-playbook --syntax-check` と `ansible-lint` を実行 |
| ローカル統合テスト（Docker） | `local-integration-tests` | `iac-workspace/tests/run.sh` を実行（後述の第4節） |
| Terraform 整形・検証 | `terraform-ci` | `terraform fmt -check` と `terraform validate`（バックエンド非接続） |
| Terraform Plan（PRのみ） | `terraform-plan` | PR 時のみ実行し、Plan 結果を PR にコメント |
| コンテナ・IaC 脆弱性スキャン | `trivy-scan` | Trivy による設定スキャン（HIGH/CRITICAL で失敗） |
| Discord 通知（失敗時） | `notify-failure` | いずれかのジョブが失敗したら Discord へ通知 |

### 失敗通知
`notify-failure` は全ジョブを `needs` に取り、`if: failure()` で動作する。いずれかのジョブが失敗したときだけ実行され、成功時はスキップされる。通知文面のワークフロー名は `${{ github.workflow }}` で自動反映される。

### 利用シークレット
TF_BACKEND_CONFIG / CF_R2_ACCESS_KEY_ID / CF_R2_SECRET_ACCESS_KEY / CLOUDFLARE_API_TOKEN（terraform-plan のみ）、DISCORD_WEBHOOK_URL（notify-failure）。

### 補足
`ansible-ci` は molecule のシナリオ（`converge.yml`）がロール本体を解決できるよう、環境変数 `ANSIBLE_ROLES_PATH: ansible/roles` を付与している。

---

## 2. アプリからの自動デプロイ

ファイル: `.github/workflows/cd_deploy.yml`

### 目的
アプリリポジトリ（shake-web / pkhack / ayahuya / ubsleepy）の更新を、インフラリポジトリのセルフホストランナー（tarakoserver）が受け取り、Ansible で本番へデプロイする。shake-web の 3 分割（pkhack/ayahuya/shake）に伴い、各アプリリポジトリが個別の dispatch イベントを送る。

### トリガー
- `repository_dispatch`（types: `deploy_shakeweb` / `deploy_pkhack` / `deploy_ayahuya` / `deploy_ubsleepy`）。アプリ側ワークフローが、`INFRA_REPO_DISPATCH_TOKEN`（Contents 書き込み権限を持つトークン）を用いてインフラリポジトリへ送信する。
- `workflow_dispatch`（手動）。対象アプリ（target: shakeweb / pkhack / ayahuya / ubsleepy）と、ドライラン（dry_run）の有無を選択できる。

### 処理ステップ
| ステップ表示名 | 内容 |
| :--- | :--- |
| リポジトリのチェックアウト | ソース取得 |
| Ansible 認証情報のセットアップ | シークレットから SSH 鍵・Vault パス・vars/vault・インベントリを生成 |
| Ansible コレクションのインストール | requirements.yml を適用 |
| ubsleepy のデプロイ | 対象が ubsleepy のとき `--tags ubsleepy` を実行 |
| shake-web のデプロイ | 対象が shakeweb のとき `--tags web` を実行 |
| pkhack のデプロイ | 対象が pkhack のとき `--tags web` を実行（pkhack repo を pull→`pkhack_app` 再ビルド） |
| ayahuya のデプロイ | 対象が ayahuya のとき `--tags web` を実行（ayahuya repo を pull→静的配信） |
| スモークテスト（shake-web / DB連携エンドポイント） | 実HTTPS経路で `/quiz/api/bsquiz/pokedex` を検証。200 以外ならデプロイを失敗扱い |
| スモークテスト（pkhack / ayahuya） | 各サブドメインの代表エンドポイント（`pkhack.…/quiz/api/bsquiz/pokedex`・`ayahuya.…/docs/words/`）を検証 |
| 認証情報のクリーンアップ | 生成した鍵類を削除（常時） |
| Discord 通知（成功時 / 失敗時） | 結果を Discord に通知 |

dry_run が true のときは Ansible を `--check`（シミュレーション）で実行し、スモークテストはスキップされる。

### 利用シークレット
ANSIBLE_SSH_KEY / ANSIBLE_VAULT_PASS / ANSIBLE_VARS / DISCORD_WEBHOOK_URL。

### 補足
ランナーは `vault.yml.enc` を復号して使用する。手動デプロイ（run_playbook.sh）が使う `vault.yml` と内容を一致させておくこと（[03_機密情報管理.md](03_機密情報管理.md) を参照）。

---

## 3. Terraform ドリフト検知

ファイル: `.github/workflows/terraform_drift.yml`

### 目的
Terraform のコードと、Cloudflare 等の実態との乖離（ドリフト）を定期的に検知し、差分があれば通知する。

### トリガー
- スケジュール: 毎週月曜 09:00 JST（cron は UTC 0:00）
- workflow_dispatch（手動）

### 処理ステップ
リモートステート（R2）へ接続して `terraform plan -detailed-exitcode` を実行し、終了コードで分岐する。

| plan の終了コード | 意味 | 動作 |
| :--- | :--- | :--- |
| 0 | 差分なし | 通知なし |
| 2 | 差分あり（ドリフト） | Discord 通知（ドリフト検出） |
| 1 | 実行エラー | Discord 通知（Plan エラー） |

### 利用シークレット
TF_BACKEND_CONFIG / CF_R2_ACCESS_KEY_ID / CF_R2_SECRET_ACCESS_KEY / CLOUDFLARE_API_TOKEN / DISCORD_WEBHOOK_URL。

---

## 4. ローカルテスト（インフラCIから呼ばれる）

ディレクトリ: `iac-workspace/tests/`

インフラCIの「ローカル統合テスト（Docker）」ジョブが実行する。すべて使い捨てコンテナ／モックで動作し、本番サーバー・Cloudflare・R2 には接続しない。ローカルでも同じスクリプトで再現できる。

### 実行コマンド
```bash
./iac-workspace/tests/run.sh             # pytest 一式（postgres / blackbox / failover）
./iac-workspace/tests/run_molecule.sh    # Molecule によるロール単体テスト（exporters）
```

### テスト内容
| ファイル | 種別 | 内容 |
| :--- | :--- | :--- |
| `test_postgres_role.py` | 収束/統合 | 捨てDBで scram 認証・パスワード同期の冪等性・Vault 変更時のドリフト是正を検証 |
| `test_blackbox_probe.py` | 監視 | go-httpbin の 200/500 を blackbox が検知できることを実証し、prometheus 設定を promtool で構文検証 |
| `test_failover.py` | 単体 | failover_webhook.py のメンテ切替ロジックを Cloudflare 非接続で検証 |
| `roles/exporters/molecule/` | ロール単体 | コンテナ内でロールを収束→冪等→検証（node-exporter 稼働） |

テスト用の Python 仮想環境はリポジトリ外（`$HOME/.cache`）に作成し、生成物は `.gitignore` で除外している。

---

## 5. 表示名と Discord 通知の早見表

| 通知文面の先頭 | 発火元ワークフロー | 条件 |
| :--- | :--- | :--- |
| `[CI FAILED]` | インフラCI（コード検証） | いずれかのジョブが失敗 |
| `[SUCCESS] デプロイ成功` | アプリからの自動デプロイ | デプロイ成功 |
| `[FAILED] デプロイ失敗` | アプリからの自動デプロイ | デプロイ失敗（スモークテスト失敗を含む） |
| `[DRIFT DETECTED]` | Terraform ドリフト検知 | plan 終了コード 2 |
| `[DRIFT CHECK ERROR]` | Terraform ドリフト検知 | plan 終了コード 1 |
