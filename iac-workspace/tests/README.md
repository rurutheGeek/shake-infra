# ローカル自動テスト（本番非接続）

すべて**使い捨ての Docker コンテナ／モック**で実行し、本番サーバー・Cloudflare・R2 には接続しません。
Docker が動くマシンで以下を実行するだけ:

```bash
./run.sh                       # venv 作成 + 全テスト
./run.sh test_postgres_role.py # 個別実行
```

## テスト一覧
| ファイル | 種別 | 内容 | 必要なもの |
| :-- | :-- | :-- | :-- |
| `test_postgres_role.py` | 収束/統合 | 捨てDBを起動し、init-dbでのユーザー作成・scram認証・**パスワード同期の冪等性**・**Vault変更時のドリフト是正**を検証（2026-06-01のDB障害の再発防止） | Docker |
| `test_blackbox_probe.py` | 監視 | go-httpbin(200/500)+blackboxで `probe_success` が 200→1/500→0 を検知することを実証＋本番 prometheus 設定を `promtool` で構文検証 | Docker |
| `test_failover.py` | 単体 | `failover_webhook.py` をモックし ProxyDown firing→`on`/resolved→`off`/無関係→無動作 を検証（Cloudflare非接続）＋`toggle_maintenance.sh` 構文 | Docker不要 |

## Molecule（ロール単体テスト）
使い捨てコンテナ内でロールを収束→**冪等性**(2回目=changed 0)→検証する。
```bash
./run_molecule.sh exporters   # roles/exporters/molecule/default
```
`exporters` ロールは docker/ufw タスクが「docker 未導入時に自動スキップ」されるため、
コンテナ内で node-exporter 導入+systemd 起動のみを検証できる（systemd 稼働のため privileged + cgroup マウント）。

## 設計メモ
- DBの認証は pg_hba で `127.0.0.1=trust`（無検証）なので、テストは**コンテナの非ループバックIP**へ接続して scram 経路を強制し、誤パスワード拒否も確認している。
- blackbox の本番監視は `job=blackbox_https`（別ジョブ）で、失敗が `ProxyDown`(=フェイルオーバー)を誤発火させない設計。
- これらは CI（ubuntu-latest 等、Docker 利用可）に組み込める。
