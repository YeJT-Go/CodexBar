#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
source_app="${CODEXBAR_SOURCE_APP:-$project_root/.build/app/CodexBar.app}"

if [[ -z "${HOME:-}" || "$HOME" != /* || ! -d "$HOME" ]]; then
    echo "错误：HOME 必须是已存在的绝对目录，拒绝安装。" >&2
    exit 1
fi

canonical_home="$(cd -- "$HOME" && pwd -P)"
if [[ "$canonical_home" != /* || "$canonical_home" == "/" ]]; then
    echo "错误：规范化后的 HOME 不安全，拒绝安装。" >&2
    exit 1
fi

applications_dir="$canonical_home/Applications"
mkdir -p "$applications_dir"
canonical_applications_dir="$(cd -- "$applications_dir" && pwd -P)"
if [[ "$canonical_applications_dir" != "$applications_dir" ]]; then
    echo "错误：Applications 目录不是 HOME 下的规范目录，拒绝安装。" >&2
    exit 1
fi

destination_app="$canonical_applications_dir/CodexBar.app"
if [[ "$destination_app" != "$canonical_home/Applications/CodexBar.app" ]]; then
    echo "错误：安装目标不符合预期，拒绝继续。" >&2
    exit 1
fi

if [[ ! -d "$source_app" ]]; then
    echo "错误：未找到 $source_app，请先运行 scripts/build-app.sh。" >&2
    exit 1
fi

staging_dir=""
backup_dir=""
staged_app=""
backup_app=""
backup_move_started=0
activation_started=0
committed=0

is_safe_temporary_dir() {
    local path="$1"
    local name="${path##*/}"
    local parent="${path%/*}"
    [[ "$parent" == "$canonical_applications_dir" ]] &&
        [[ "$name" == .CodexBar.install.* || "$name" == .CodexBar.backup.* ]]
}

remove_temporary_dir() {
    local path="$1"
    if [[ -n "$path" && -e "$path" ]]; then
        if ! is_safe_temporary_dir "$path"; then
            echo "错误：拒绝清理非预期临时目录 $path" >&2
            return 1
        fi
        rm -rf -- "$path"
    fi
}

remove_destination_app() {
    if [[ "$destination_app" != "$canonical_applications_dir/CodexBar.app" ]]; then
        echo "错误：拒绝删除非预期应用路径 $destination_app" >&2
        return 1
    fi
    rm -rf -- "$destination_app"
}

is_complete_app() {
    local app="$1"
    [[ -d "$app" ]] &&
        [[ -x "$app/Contents/MacOS/CodexBar" ]] &&
        [[ -f "$app/Contents/Info.plist" ]] &&
        plutil -lint "$app/Contents/Info.plist" >/dev/null 2>&1 &&
        codesign --verify --deep --strict "$app" >/dev/null 2>&1
}

run_hook() {
    local point="$1"
    if [[ -n "${CODEXBAR_INSTALL_HOOK:-}" ]]; then
        "$CODEXBAR_INSTALL_HOOK" "$point" "$$"
    fi
}

rollback() {
    local status=$?
    trap - EXIT INT TERM HUP
    set +e

    if [[ "$committed" -eq 1 ]]; then
        exit "$status"
    fi

    if [[ "$status" -ne 0 && "$activation_started" -eq 1 && ! -e "$staged_app" && -e "$destination_app" ]]; then
        if is_complete_app "$destination_app"; then
            remove_destination_app
        elif is_safe_temporary_dir "$staging_dir"; then
            mv -- "$destination_app" "$staged_app"
        fi
    fi
    if [[ "$status" -ne 0 && "$backup_move_started" -eq 1 && -e "$backup_app" && ! -e "$destination_app" ]]; then
        if mv -- "$backup_app" "$destination_app"; then
            backup_move_started=0
        else
            echo "错误：自动恢复失败，旧版本保留在 $backup_app" >&2
        fi
    fi
    remove_temporary_dir "$staging_dir"
    if [[ "$backup_move_started" -eq 0 || ! -e "$backup_app" ]]; then
        remove_temporary_dir "$backup_dir"
    fi
    exit "$status"
}

trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

staging_dir="$(mktemp -d "$canonical_applications_dir/.CodexBar.install.XXXXXX")"
backup_dir="$(mktemp -d "$canonical_applications_dir/.CodexBar.backup.XXXXXX")"
staged_app="$staging_dir/CodexBar.app"
backup_app="$backup_dir/CodexBar.app"

if ! is_safe_temporary_dir "$staging_dir" || ! is_safe_temporary_dir "$backup_dir"; then
    echo "错误：临时目录不符合安全约束，拒绝继续。" >&2
    exit 1
fi
if [[ "$staged_app" != "$staging_dir/CodexBar.app" || "$backup_app" != "$backup_dir/CodexBar.app" ]]; then
    echo "错误：临时应用路径不符合预期，拒绝继续。" >&2
    exit 1
fi

ditto "$source_app" "$staged_app"

if [[ ! -x "$staged_app/Contents/MacOS/CodexBar" ]]; then
    echo "错误：暂存应用缺少可执行文件。" >&2
    exit 1
fi
if [[ ! -f "$staged_app/Contents/Info.plist" ]]; then
    echo "错误：暂存应用缺少 Info.plist。" >&2
    exit 1
fi
plutil -lint "$staged_app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$staged_app"

if [[ -e "$destination_app" ]]; then
    backup_move_started=1
    mv -- "$destination_app" "$backup_app"
    run_hook "after-backup-move"
fi

activation_started=1
mv -- "$staged_app" "$destination_app"
committed=1
trap - EXIT INT TERM HUP

if ! remove_temporary_dir "$staging_dir"; then
    echo "警告：无法清理暂存目录 $staging_dir" >&2
fi
if ! remove_temporary_dir "$backup_dir"; then
    echo "警告：无法清理旧版本备份 $backup_dir" >&2
fi

open "$destination_app"

echo "已安装并启动：$destination_app"
