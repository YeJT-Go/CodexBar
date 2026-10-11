# CodexBar 悬停额度浮卡实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 为 CodexBar 增加一个不抢焦点、无需隐私权限、可在实际触发屏幕右侧悬停显示的额度浮卡。

**架构：** 现有 `UsageViewModel` 继续作为唯一数据源；新增纯展示模型、纯显示状态机和纯屏幕布局计算，再由一个 `NSPanel` 控制器连接鼠标位置采样、系统通知和 AppKit 动画。SwiftUI 内容由原生 `NSVisualEffectView` 承载，菜单栏弹窗代码与阈值保持不变。

**技术栈：** Swift 6、SwiftUI、AppKit、Combine、XCTest、Swift Package Manager。

**规格：** `docs/superpowers/specs/2026-10-11-floating-quota-card-design.md`

## 全局约束

- macOS 14+，不引入第三方依赖。
- 浮卡宽 148 pt、右距 12 pt、热区 2 pt；约每 100 ms 读取一次鼠标位置。
- 离开后等待 3 秒，再以约 0.25 秒渐隐；持续在外部不得重置倒计时。
- 复用现有 `UsageViewModel`，不得新建客户端、额度轮询或 App Server 进程。
- 不恢复 Token 统计，不修改 `UsageLevel` 或菜单栏弹窗阈值。
- 不申请辅助功能、输入监控或录屏权限，不使用透明触发窗口。
- 只暂存任务列出的文件；不覆盖已有修改，不自动 push、merge 或 release。

## 文件结构

- `UI/FloatingQuotaPresentation.swift`：浮卡数据映射和独立颜色等级。
- `UI/FloatingCardVisibilityState.swift`：带令牌的显示状态机。
- `UI/FloatingCardScreenLayout.swift`：多屏命中和位置计算。
- `UI/FloatingQuotaCardView.swift`：两个圆环及状态提示。
- `UI/FloatingQuotaCardController.swift`：唯一 `NSPanel`、材质、采样、通知和动画。
- `CodexBarApp.swift`：向控制器注入已有模型并幂等启动。
- 五个对应 XCTest 文件；`README.md` 增加本地查看说明。

## 审查重点

- 相邻屏幕接缝只触发光标实际命中的屏幕（任务 3）。
- 卡片高于小屏可用高度时仍夹取在 `visibleFrame` 内（任务 3）。
- 睡眠发生在等待/渐隐阶段时，旧回调失效，唤醒不误显示（任务 5）。
- 5 小时缺失但每周有效时，上方为 `—`、下方保留真实值（任务 1）。
- 持续外部采样及快速进出不会重置倒计时或被旧回调误隐藏（任务 2）。

---

### Task 1：浮卡额度展示模型

**文件：**
- 新建：`Sources/CodexBar/UI/FloatingQuotaPresentation.swift`
- 测试：`Tests/CodexBarTests/FloatingQuotaPresentationTests.swift`

**接口：** 输入现有 `UsageState`；输出 `FloatingQuotaLevel.level(forRemaining:)`、`FloatingQuotaRingPresentation` 和 `FloatingQuotaCardPresentation.make(from:)`。

- [ ] **失败测试：** 覆盖 `0/19 → critical`、`20/50 → warning`、`51/100 → healthy`，进度夹取到 `0...1`，以及加载、不可用、过期、5 小时缺失但每周有效。
- [ ] **验证 RED：** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FloatingQuotaPresentationTests`；预期因类型缺失而失败。
- [ ] **最小实现：** 定义 `FloatingQuotaLevel`、`FloatingQuotaRingPresentation(title:remainingText:progress:level:accessibilityLabel:accessibilityValue:)` 与 `FloatingQuotaCardPresentation(fiveHour:weekly:statusText:)`。缺失进度必须为 `nil`，不可使用 `0` 代替。
- [ ] **验证 GREEN：** 重跑筛选测试，预期全部通过。
- [ ] **提交：** 只提交上述两个文件，消息 `feat: add floating quota presentation`。

### Task 2：可中断的显示状态机

**文件：**
- 新建：`Sources/CodexBar/UI/FloatingCardVisibilityState.swift`
- 测试：`Tests/CodexBarTests/FloatingCardVisibilityStateTests.swift`

**接口：** `FloatingCardVisibilityMachine.handle(_ event:) -> [FloatingCardVisibilityEffect]`；事件为 pointerChanged、hideDelayElapsed、fadeCompleted、reset，effect 为 show、scheduleHide、beginFade、restore、hide、cancelPending。

- [ ] **失败测试：** 覆盖初始隐藏、进入显示、离开只安排一次 3 秒等待、等待返回取消、渐隐返回恢复、旧等待/动画令牌失效、reset 隐藏。
- [ ] **验证 RED：** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FloatingCardVisibilityStateTests`，预期因状态机缺失而失败。
- [ ] **最小实现：** 状态为 hidden、visible、waiting(token)、fading(token)；只在新的显示/隐藏周期递增令牌，同一 waiting 收到外部事件不产生 effect。
- [ ] **验证 GREEN：** 使用完整 `DEVELOPER_DIR` 重跑筛选测试，预期全部通过。
- [ ] **提交：** 只提交状态机与测试，消息 `feat: add floating card visibility state`。

### Task 3：多屏命中与位置计算

**文件：**
- 新建：`Sources/CodexBar/UI/FloatingCardScreenLayout.swift`
- 测试：`Tests/CodexBarTests/FloatingCardScreenLayoutTests.swift`

**接口：** `FloatingScreen(id:frame:visibleFrame:scale:)`；`screen(at:in:)`、`isInRightEdge(_:of:width:)`、`panelOrigin(size:screen:trailingInset:)`。

- [ ] **失败测试：** 覆盖主屏、负 X、上下排列、相邻屏接缝、屏幕外点、右侧 Dock、1x/2x 像素对齐、卡片高于可用区域。
- [ ] **验证 RED：** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FloatingCardScreenLayoutTests`，预期类型缺失。
- [ ] **最小实现：** 使用全局逻辑点命中屏幕；热区默认 2 pt；以 `visibleFrame.maxX - 12 - width` 定位并夹取 Y，最后按 scale 对齐像素。
- [ ] **验证 GREEN：** 使用完整 `DEVELOPER_DIR` 重跑筛选测试，预期全部通过。
- [ ] **提交：** 只提交布局与测试，消息 `feat: calculate floating card screen layout`。

### Task 4：原生材质浮卡视图

**文件：**
- 新建：`Sources/CodexBar/UI/FloatingQuotaCardView.swift`
- 测试：`Tests/CodexBarTests/FloatingQuotaCardViewTests.swift`

**接口：** `FloatingQuotaCardView(model: UsageViewModel)` 观察现有模型；内部内容视图接收 `FloatingQuotaCardPresentation`，固定宽 148 pt、高度自适应。

- [ ] **失败测试：** 通过 `NSHostingView` 验证典型、缺失和过期 presentation 均产生 148 pt 宽且高度为正的内容；展示模型的辅助功能标签和值由任务 1 的测试固定。
- [ ] **验证 RED：** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FloatingQuotaCardViewTests`，预期视图缺失。
- [ ] **最小实现：** 两个 `Circle.trim` 圆环纵向排列，起点在顶部；百分比居中、名称在下，`nil` 进度为空环，过期提示置底。颜色只由浮卡等级决定。
- [ ] **验证 GREEN：** 运行 `swift test --filter FloatingQuota`，预期任务 1 与任务 4 测试全部通过。
- [ ] **提交：** 只提交视图与测试，消息 `feat: render floating quota card`。

### Task 5：NSPanel 控制器与系统事件

**文件：**
- 新建：`Sources/CodexBar/UI/FloatingQuotaCardController.swift`
- 测试：`Tests/CodexBarTests/FloatingQuotaCardControllerTests.swift`

**接口：** `@MainActor final class FloatingQuotaCardController` 提供幂等 `start()`、`stop()`；构造器注入现有模型、`FloatingCardEnvironment`、`FloatingCardScheduling` 和 `FloatingCardPanelPresenting`，默认实现分别连接 AppKit、Timer/Task 和唯一 NSPanel。

- [ ] **失败测试：** fake 环境/面板/调度器验证重复 start 只有一个采样器、实际触发屏变化时复用同一面板、热区或面板内均保持显示、3 秒后才渐隐、睡眠令牌失效、唤醒重采样、断屏重算、stop 只释放浮卡资源。
- [ ] **验证 RED：** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FloatingQuotaCardControllerTests`，预期接口缺失。
- [ ] **最小实现：** 100 ms 采样 `NSEvent.mouseLocation`；一个不可成为 key/main 的无标题 `NSPanel` 只覆盖浮卡边界；`NSVisualEffectView` 承载 hosting view，配置圆角、亮边、阴影、floating level 和 Space 行为；动画完成前检查令牌。
- [ ] **系统适配：** 监听辅助显示选项、睡眠/唤醒和屏幕参数变化；减少透明度时覆盖不透明系统窗口背景，减少动态效果时取消或缩短渐隐。
- [ ] **验证 GREEN：** 运行 `swift test --filter Floating`，预期全部浮卡测试通过，代码中不出现权限申请 API。
- [ ] **提交：** 只提交控制器与测试，消息 `feat: coordinate floating quota panel`。

### Task 6：应用集成、文档与完整验证

**文件：**
- 修改：`Sources/CodexBar/CodexBarApp.swift`
- 修改：`README.md`
- 验证：全部 `Tests/CodexBarTests/*.swift`

**接口：** 以 `AppDependencies.makeUsageViewModel()` 创建的同一个实例构造菜单栏、生命周期协调器和浮卡控制器；控制器不持有 `AppLifecycleCoordinator`。

- [ ] **集成：** 在 `CodexBarApp.init` 注入现有 model，并在现有启动入口调用控制器的幂等 start；这是组合根的简单接线，不为构造器转发编写脆弱测试。
- [ ] **文档：** README 说明右边缘触发、3 秒延迟、无额外隐私权限、浮卡不显示 Token，以及 `open .build/app/CodexBar.app` 查看方式。
- [ ] **完整验证：** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`、`bash scripts/build-app.sh`、`git diff --check`；预期测试 0 失败、Release 构建成功、无空白错误。
- [ ] **真实检查：** 获得 GUI 运行授权后，逐项记录通过/失败/未运行：默认隐藏、边缘触发、3 秒延迟、快速返回、菜单栏弹窗、焦点、深浅模式、减少透明度、睡眠唤醒、多屏、全屏。
- [ ] **提交：** 只提交 App 入口与 README，消息 `feat: integrate floating quota card`。
- [ ] **工作区复核：** 确认旧的 `.superpowers/sdd/.../task-1-report.md`、`MenuBarView.swift`、`MenuBarPresentationTests.swift` 修改仍保留且未误提交；不执行 push、merge 或 release。
