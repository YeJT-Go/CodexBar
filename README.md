# CodexBar

CodexBar 是一个自用的 macOS 菜单栏应用，用于显示 Codex 当前 5 小时与每周额度，例如 `5h 80% · 周 25%`，并在弹窗中统计今日 Token。应用每 60 秒自动刷新，也支持手动刷新。今日 Token 来自本机 `codex app-server` 的 `account/usage/read` 按日聚合结果；这是准实时数据，正在运行的任务可能要等结束后才会计入。

应用只复用本机 Codex CLI 的登录状态，不直接读取、保存或上传账号凭据。额度与 Token 独立更新：任一数据源暂时失败时，另一项仍可正常显示。

> 当前构建使用临时签名，未经 Apple 公证，仅适合本人设备使用。不要将生成的应用作为正式发行包分发。

## 前置条件

- macOS 14 或更高版本，Apple Silicon Mac。
- 完整安装 Xcode，并接受 Xcode 许可协议。
- 已安装并登录 Codex CLI；终端中运行 `codex --version` 应成功。
- Codex CLI 通常位于 `/opt/homebrew/bin/codex` 或 `/usr/local/bin/codex`。应用会检查常见 GUI PATH；若使用其他位置，请确保命令可被系统找到。

## 测试与构建

在项目目录运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash scripts/build-app.sh
```

构建结果位于 `.build/app/CodexBar.app`。构建脚本可从任意当前目录调用，并会自动使用 `/Applications/Xcode.app` 中的完整开发环境（如未显式设置 `DEVELOPER_DIR`）。

## 本地安装与首次启动

```bash
bash scripts/install-local.sh
```

脚本只会替换 `~/Applications/CodexBar.app`，随后启动应用。首次启动后，点击菜单栏额度文字可查看今日 Token、额度进度、重置时间和“登录时启动”开关。右上角“刷新”按钮在操作期间显示“刷新中…”，完成后显示结果反馈。自动启动可随时关闭。

## 常见问题

- **提示找不到 Codex CLI：**确认 `codex --version` 可运行，并检查 CLI 是否位于上述常见路径。
- **提示需要 Xcode：**确认 `/Applications/Xcode.app` 存在，并运行 `sudo /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license accept`。
- **今日 Token 显示 `--`：**表示按日统计暂不可用，并不代表使用量为零。确认 Codex CLI 已登录后点击“刷新”；额度仍会独立更新。
- **只显示周额度：**当前账号未返回 5 小时额度时，应用会隐藏 5 小时项目，菜单栏只显示周额度。
- **额度变灰或显示连接异常：**确认 Codex CLI 已登录，点击“刷新”；应用会保留最后一次成功数据并自动重连。
- **macOS 阻止启动：**这是未公证的自用构建。请仅在确认源码与本机构建可信后，在“系统设置 → 隐私与安全性”中允许启动。

## 卸载

先在菜单中关闭“登录时启动”并退出应用，然后将 `~/Applications/CodexBar.app` 移到废纸篓即可。项目目录中的 `.build` 仅为构建缓存，可按需删除。
