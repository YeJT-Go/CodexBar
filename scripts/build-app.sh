#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "$project_root"

swift build -c release --product CodexBar
binary_dir="$(swift build -c release --show-bin-path)"
binary_path="$binary_dir/CodexBar"
app_dir="$project_root/.build/app/CodexBar.app"

if [[ ! -x "$binary_path" ]]; then
    echo "错误：未找到构建产物 $binary_path" >&2
    exit 1
fi

rm -rf -- "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_path" "$app_dir/Contents/MacOS/CodexBar"
cp "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"

codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "已生成：$app_dir"
