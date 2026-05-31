#!/bin/bash
# ローカル統合テスト実行（本番非接続）。venv を作って pytest を回すだけ。
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
  python3 -m venv .venv
  ./.venv/bin/pip -q install --upgrade pip
  ./.venv/bin/pip -q install pytest
fi
exec ./.venv/bin/pytest -v "$@"
