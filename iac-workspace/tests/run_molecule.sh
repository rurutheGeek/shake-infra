#!/bin/bash
# Molecule によるロール単体テスト（本番非接続・使い捨てコンテナ）。
# venv はリポジトリ外に作る（ansible-lint の誤走査回避）。引数でロール指定可。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"   # tests/
WS="$(dirname "$HERE")"                  # iac-workspace/
ROLE="${1:-exporters}"
VENV="${SHAKE_TEST_VENV:-$HOME/.cache/shake-infra-tests/venv}"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip
fi
"$VENV/bin/pip" -q install molecule "molecule-plugins[docker]" docker >/dev/null
# shellcheck disable=SC1091
source "$VENV/bin/activate"
ansible-galaxy collection install community.docker >/dev/null 2>&1 || true
cd "$WS/ansible/roles/$ROLE"
exec molecule test
