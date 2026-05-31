"""
postgres ロール ローカル統合テスト（本番非接続）

使い捨ての docker-compose で PostgreSQL を起動し、postgres ロールが行う
- init-db によるアプリユーザー(pkdb_reader)作成 + scram 認証
- パスワード同期(ALTER USER)の冪等性
- Vault 値変更時のドリフト是正（今日の障害の再発防止の核心）
を検証する。prod のサーバー/Cloudflare/R2 には一切接続しない。

実行: tests/run.sh  （venv 作成 + pytest 実行）
"""
import os
import shutil
import subprocess
import tempfile
import time
import uuid
import pathlib
import pytest

ROLE_FILES = pathlib.Path(__file__).resolve().parents[1] / "ansible" / "files" / "postgres"
PROJECT = "pgtest_" + uuid.uuid4().hex[:8]

# テスト用シークレット（初期値）
INIT = {
    "POSTGRES_USER": "postgres",
    "POSTGRES_PASSWORD": "superpw_init",  # pragma: allowlist secret
    "POSTGRES_DB": "testdb",
    "PKDB_READER_USER": "pkdb_reader",
    "PKDB_READER_PASSWORD": "readerP1_init",  # pragma: allowlist secret
    "PKDB_EDITOR_USER": "pkdb_editor",
    "PKDB_EDITOR_PASSWORD": "editorP1_init",  # pragma: allowlist secret
    # db-backup サービス用ダミー（db のみ起動するので未使用だが compose 解析の警告抑止）
    "CF_BUCKET_NAME": "dummy", "CF_ACCOUNT_ID": "dummy",
    "CF_ACCESS_KEY": "dummy", "CF_SECRET_KEY": "dummy",  # pragma: allowlist secret
    "PG_UID": str(os.getuid()), "PG_GID": str(os.getgid()),
}


def _run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def _compose(workdir, *args):
    return _run(["docker", "compose", "-p", PROJECT, *args], cwd=workdir)


@pytest.fixture(scope="module")
def pg(tmp_path_factory):
    work = pathlib.Path(tempfile.mkdtemp(prefix="pgrole_"))
    # 本物の compose を流用しつつ container_name を除去（prod の shake_postgres と衝突回避）
    compose_src = (ROLE_FILES / "docker-compose.yml").read_text()
    compose = "\n".join(l for l in compose_src.splitlines() if "container_name:" not in l)
    (work / "docker-compose.yml").write_text(compose)
    # init-db は 01_setup_users.sh のみ（巨大ダンプは認証テストに不要・高速化）
    (work / "init-db").mkdir()
    shutil.copy(ROLE_FILES / "init-db" / "01_setup_users.sh", work / "init-db" / "01_setup_users.sh")
    os.chmod(work / "init-db" / "01_setup_users.sh", 0o755)
    (work / "data").mkdir()
    (work / ".env").write_text("\n".join(f"{k}={v}" for k, v in INIT.items()) + "\n")

    up = _compose(work, "up", "-d", "db")
    assert up.returncode == 0, f"compose up failed:\n{up.stderr}"

    cid = _compose(work, "ps", "-q", "db").stdout.strip()
    # healthy 待ち（最大 60s）
    for _ in range(60):
        h = _run(["docker", "inspect", "-f", "{{.State.Health.Status}}", cid])
        if h.stdout.strip() == "healthy":
            break
        time.sleep(1)
    else:
        logs = _run(["docker", "logs", "--tail", "40", cid])
        _compose(work, "down", "-v")
        pytest.fail(f"postgres not healthy:\n{logs.stdout}\n{logs.stderr}")

    db_ip = _compose(work, "exec", "-T", "db", "hostname", "-i").stdout.strip().split()[0]

    class H:
        def alter(self, user, pw):
            # postgres ロールの同期タスクと同じ ALTER（init後のドリフト是正）
            sql = f"ALTER USER \"{user}\" WITH PASSWORD '{pw}';"
            r = _compose(work, "exec", "-T", "db", "psql", "-U", "postgres",
                         "-d", INIT["POSTGRES_DB"], "-v", "ON_ERROR_STOP=1", "-c", sql)
            assert r.returncode == 0, r.stderr
        def auth(self, user, pw):
            # アプリ実経路を再現: 非ループバックIP宛 = pg_hba の scram ルールを通る
            r = _compose(work, "exec", "-T", "-e", f"PGPASSWORD={pw}", "db",
                         "psql", "-U", user, "-h", db_ip, "-d", INIT["POSTGRES_DB"],
                         "-tAc", "select 1;")
            return r.returncode == 0 and r.stdout.strip() == "1"

    yield H()
    _compose(work, "down", "-v")
    shutil.rmtree(work, ignore_errors=True)


def test_init_creates_reader_with_scram(pg):
    """init-db が pkdb_reader を作成し、正しいパスワードで scram 認証できる。"""
    assert pg.auth("pkdb_reader", INIT["PKDB_READER_PASSWORD"]) is True
    # 誤パスワードは拒否 = trust ではなく scram が効いている証明
    assert pg.auth("pkdb_reader", "wrong_password") is False


def test_password_sync_is_idempotent(pg):
    """同じパスワードで ALTER を二度流しても認証が維持される（冪等）。"""
    pw = "readerP2_synced"
    pg.alter("pkdb_reader", pw)
    assert pg.auth("pkdb_reader", pw) is True
    pg.alter("pkdb_reader", pw)  # 2回目
    assert pg.auth("pkdb_reader", pw) is True


def test_password_drift_is_corrected(pg):
    """Vault のパスワード変更を ALTER で反映＝旧値は失効・新値で認証成功（今日の障害の核心）。"""
    old, new = "readerP2_synced", "readerP3_rotated"
    pg.alter("pkdb_reader", new)
    assert pg.auth("pkdb_reader", new) is True
    assert pg.auth("pkdb_reader", old) is False
