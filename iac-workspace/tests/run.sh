#!/bin/bash
# ローカル統合テスト実行（本番非接続）。venv はリポジトリ外に作る
# （pre-commit の ansible-lint がツリー内 venv を走査して誤検知するのを防ぐ）。
set -euo pipefail
cd "$(dirname "$0")"
VENV="${SHAKE_TEST_VENV:-$HOME/.cache/shake-infra-tests/venv}"
if [ ! -x "$VENV/bin/pytest" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip
  "$VENV/bin/pip" -q install pytest
fi
exec "$VENV/bin/pytest" -v "$@"
