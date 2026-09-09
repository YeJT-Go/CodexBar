#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
source_app="$project_root/.build/app/CodexBar.app"

if [[ -z "${HOME:-}" || "$HOME" == "/" ]]; then
    echo "错误：HOME 未设置或不安全，拒绝安装。" >&2
    exit 1
fi

applications_dir="$HOME/Applications"
destination_app="$applications_dir/CodexBar.app"
expected_destination="$HOME/Applications/CodexBar.app"

if [[ "$destination_app" != "$expected_destination" ]]; then
    echo "错误：安装目标不符合预期，拒绝继续。" >&2
    exit 1
fi

if [[ ! -d "$source_app" ]]; then
    echo "错误：未找到 $source_app，请先运行 scripts/build-app.sh。" >&2
    exit 1
fi

mkdir -p "$applications_dir"
rm -rf -- "$destination_app"
ditto "$source_app" "$destination_app"
open "$destination_app"

echo "已安装并启动：$destination_app"
