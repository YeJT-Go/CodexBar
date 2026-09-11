# CodexBar 今日 Token 与弹窗重设计实施计划

> **面向智能体执行者：** REQUIRED SUB-SKILL：使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，按任务逐项实施本计划。步骤使用复选框跟踪。

**目标：** 接入账户级今日 Token 数据，并将弹窗实现为用户已确认的方案 A 增强版。

**架构：** 新增独立 Token DTO、解析器和状态，客户端通过既有 JSON-RPC 连接读取 `account/usage/read`。视图模型在一次刷新中分别处理额度与 Token 结果，使局部失败可降级；SwiftUI 只消费展示模型并按额度等级着色。

**技术栈：** Swift 6、SwiftUI、Foundation、Codex App Server JSON-RPC、Swift Package Manager、XCTest。

**规格：** `docs/superpowers/specs/2026-09-11-today-token-popover-redesign.md`

## 全局约束

- 菜单栏文案仍为 `5h <百分比>% · 周 <百分比>%`；5 小时缺失时只显示 `周 <百分比>%`。
- `51%...100%` 绿色、`21%...50%` 黄色、`0%...20%` 红色、过期或缺失灰色。
- 今日 Token 来自 `account/usage/read` 的本地日期桶，每 60 秒与额度一起刷新，手动刷新立即触发。
- `dailyUsageBuckets` 存在但没有今日记录时为 `0`；整个字段缺失或畸形时为未知。
- 额度与 Token 独立容错；任一失败不得覆盖另一项的成功结果。
- 不读取凭据文件、不记录原始响应、不保存 Token 历史、不启用实验能力、不新增第三方依赖。
- 保持 macOS 14 最低平台兼容，所有后续文档与用户文案使用中文。
- 只暂存和提交本计划列出的文件，不包含现有图标资源、安装脚本和旧 SDD 报告修改。

---

### Task 1：建立 Token 领域模型并调整颜色边界

**文件：**
- 创建：`Sources/CodexBar/Domain/TokenUsageModels.swift`
- 创建：`Sources/CodexBar/Domain/TokenUsageParser.swift`
- 修改：`Sources/CodexBar/Domain/RateLimitModels.swift`
- 创建：`Tests/CodexBarTests/TokenUsageParserTests.swift`
- 修改：`Tests/CodexBarTests/RateLimitParserTests.swift`

**接口：**
- 产出：`AccountTokenUsageResponse`、`AccountTokenUsageSummaryDTO`、`AccountTokenUsageDailyBucketDTO`。
- 产出：`DailyTokenUsage(tokens:dateKey:fetchedAt:)` 与 `TokenUsageState`。
- 产出：`TokenUsageParser.parse(_:now:calendar:) throws -> DailyTokenUsage`。
- 变更：`UsageLevel.level(forRemaining:)` 使用 51/21 边界。

- [ ] **步骤 1：写失败测试，锁定今日桶和颜色边界**

```swift
func testParsesLocalTodayBucket() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let response = AccountTokenUsageResponse(
        summary: .init(lifetimeTokens: 184_260, peakDailyTokens: 184_260,
                       currentStreakDays: 1, longestStreakDays: 1,
                       longestRunningTurnSec: 60),
        dailyUsageBuckets: [
            .init(startDate: "2026-09-11", tokens: 184_260)
        ]
    )
    let usage = try TokenUsageParser().parse(
        response,
        now: Date(timeIntervalSince1970: 1_789_117_200),
        calendar: calendar
    )
    XCTAssertEqual(usage.tokens, 184_260)
    XCTAssertEqual(usage.dateKey, "2026-09-11")
}

func testMissingTodayBucketMeansZeroWhenBucketsArePresent() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = Date(timeIntervalSince1970: 1_789_117_200)
    let response = AccountTokenUsageResponse(
        summary: .init(lifetimeTokens: nil, peakDailyTokens: nil,
                       currentStreakDays: nil, longestStreakDays: nil,
                       longestRunningTurnSec: nil),
        dailyUsageBuckets: []
    )
    XCTAssertEqual(
        try TokenUsageParser().parse(response, now: now, calendar: calendar).tokens,
        0
    )
}

func testColorBoundariesMatchApprovedRules() {
    XCTAssertEqual(UsageLevel.level(forRemaining: 51), .healthy)
    XCTAssertEqual(UsageLevel.level(forRemaining: 50), .warning)
    XCTAssertEqual(UsageLevel.level(forRemaining: 21), .warning)
    XCTAssertEqual(UsageLevel.level(forRemaining: 20), .critical)
}
```

另加两个测试：`dailyUsageBuckets == nil` 抛出 `.missingDailyBuckets`；今日桶为负数时抛出 `.invalidTokenCount`。

- [ ] **步骤 2：运行测试并确认因新类型缺失、旧颜色边界错误而失败**

运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'TokenUsageParserTests|RateLimitParserTests'
```

预期：新 Token 类型无法解析，且 50/20 边界断言失败。

- [ ] **步骤 3：实现最小领域代码**

```swift
struct AccountTokenUsageDailyBucketDTO: Codable, Equatable, Sendable {
    let startDate: String
    let tokens: Int64
}

struct AccountTokenUsageSummaryDTO: Codable, Equatable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let longestRunningTurnSec: Int64?
}

struct AccountTokenUsageResponse: Codable, Equatable, Sendable {
    let summary: AccountTokenUsageSummaryDTO
    let dailyUsageBuckets: [AccountTokenUsageDailyBucketDTO]?
}

struct DailyTokenUsage: Equatable, Sendable {
    let tokens: Int64
    let dateKey: String
    let fetchedAt: Date
}

enum TokenUsageState: Equatable, Sendable {
    case loading
    case current(DailyTokenUsage)
    case stale(DailyTokenUsage, String)
    case unavailable(String)
}
```

`TokenUsageParser` 用传入 `Calendar` 提取本地年月日并生成 `yyyy-MM-dd`；字段存在但未匹配时返回 0，字段缺失或负数抛出明确错误。将额度判断改为 `value > 50 ? .healthy : value > 20 ? .warning : .critical`。

- [ ] **步骤 4：运行聚焦测试并提交**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'TokenUsageParserTests|RateLimitParserTests'
git add Sources/CodexBar/Domain/TokenUsageModels.swift Sources/CodexBar/Domain/TokenUsageParser.swift Sources/CodexBar/Domain/RateLimitModels.swift Tests/CodexBarTests/TokenUsageParserTests.swift Tests/CodexBarTests/RateLimitParserTests.swift
git commit -m "feat: model daily Codex token usage"
```

### Task 2：接入 `account/usage/read`

**文件：**
- 修改：`Sources/CodexBar/Infrastructure/CodexAppServerClient.swift`
- 修改：`Sources/CodexBar/Infrastructure/CodexExecutableLocator.swift`
- 修改：`Sources/CodexBar/CodexBarApp.swift`
- 修改：`Tests/CodexBarTests/CodexAppServerClientTests.swift`
- 修改：`Tests/CodexBarTests/UsageViewModelTests.swift`

**接口：**
- 消费：Task 1 的 `AccountTokenUsageResponse`。
- 产出：`CodexUsageProviding.fetchAccountUsage() async throws -> AccountTokenUsageResponse`。
- 产出：`CodexClientError.malformedAccountUsageResponse`。

- [ ] **步骤 1：写失败测试，固定方法名、完整解码与断线重试**

```swift
func testFetchAccountUsageDecodesDailyBuckets() async throws {
    let value: JSONValue = .object([
        "summary": .object([
            "lifetimeTokens": .number(184_260),
            "peakDailyTokens": .number(90_000),
            "currentStreakDays": .number(3),
            "longestStreakDays": .number(7),
            "longestRunningTurnSec": .number(600)
        ]),
        "dailyUsageBuckets": .array([
            .object(["startDate": .string("2026-09-11"), "tokens": .number(184_260)])
        ])
    ])
    let rpc = RecordingRPCConnection(responses: ["account/usage/read": [.success(value)]])
    let response = try await CodexAppServerClient(connection: rpc).fetchAccountUsage()
    XCTAssertEqual(response.dailyUsageBuckets?.first?.tokens, 184_260)
    let requestCount = await rpc.requestCount(for: "account/usage/read")
    XCTAssertEqual(requestCount, 1)
}
```

另加两个测试：响应缺少必需 `summary` 时抛出 `.malformedAccountUsageResponse`；首次读取收到 `.disconnected` 后重新初始化并仅重试一次。

- [ ] **步骤 2：运行测试并确认协议方法缺失**

运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CodexAppServerClientTests
```

预期：编译失败，指出 `fetchAccountUsage` 不存在。

- [ ] **步骤 3：实现账户用量读取并更新不可用提供者**

```swift
protocol CodexUsageProviding: Sendable {
    func connect() async throws
    func fetchRateLimits() async throws -> RateLimitsResponse
    func fetchAccountUsage() async throws -> AccountTokenUsageResponse
    func updates() -> AsyncStream<RateLimitsResponse>
    func stop() async
}
```

客户端请求 `account/usage/read`、参数 `nil`，复用现有“断线后 connect 并重试一次”规则；解码失败转换为 `.malformedAccountUsageResponse`。`initialize` 继续发送 `experimentalApi: false`。`UnavailableUsageProvider` 的新方法抛出相同启动错误。为保持本任务可独立编译，在 `UsageViewModelTests` 的假提供者中增加返回空桶响应的 `fetchAccountUsage()`；Task 3 再将其扩展为可配置结果与计数器。

- [ ] **步骤 4：运行聚焦测试并提交**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CodexAppServerClientTests
git add Sources/CodexBar/Infrastructure/CodexAppServerClient.swift Sources/CodexBar/Infrastructure/CodexExecutableLocator.swift Sources/CodexBar/CodexBarApp.swift Tests/CodexBarTests/CodexAppServerClientTests.swift Tests/CodexBarTests/UsageViewModelTests.swift
git commit -m "feat: read account token usage"
```

### Task 3：在视图模型中独立编排额度与 Token

**文件：**
- 修改：`Sources/CodexBar/Usage/UsageViewModel.swift`
- 修改：`Tests/CodexBarTests/UsageViewModelTests.swift`

**接口：**
- 消费：`fetchRateLimits()`、`fetchAccountUsage()`、`TokenUsageParser.parse`。
- 产出：`@Published private(set) var tokenState: TokenUsageState`。
- 保持：`state`、`isRefreshing`、`refreshFeedback` 的既有调用方式。

- [ ] **步骤 1：写失败测试，覆盖成功与局部失败**

```swift
func testSuccessfulRefreshPublishesQuotaAndTodayTokens() async {
    let fixedNow = Date(timeIntervalSince1970: 1_789_117_200)
    let provider = FakeUsageProvider(
        fetchResults: [.success(makeResponse(fiveHourUsed: 20, weeklyUsed: 75))],
        tokenResults: [.success(makeTokenResponse(date: "2026-09-11", tokens: 184_260))]
    )
    let model = UsageViewModel(client: provider, store: InMemoryUsageStore(), now: { fixedNow })
    await model.refresh()
    guard case .current = model.state,
          case let .current(token) = model.tokenState else {
        return XCTFail("额度与 Token 都应成功发布")
    }
    XCTAssertEqual(token.tokens, 184_260)
    XCTAssertEqual(provider.fetchCount, 1)
    XCTAssertEqual(provider.tokenFetchCount, 1)
}

func testTokenFailureDoesNotMakeSuccessfulQuotaStale() async {
    let provider = FakeUsageProvider(
        fetchResults: [.success(makeResponse(fiveHourUsed: 20, weeklyUsed: 75))],
        tokenResults: [.failure(TestFailure.offline)]
    )
    let model = UsageViewModel(client: provider, store: InMemoryUsageStore())
    await model.refresh()
    guard case .current = model.state, case .unavailable = model.tokenState else {
        return XCTFail("Token 失败必须独立降级")
    }
}
```

再覆盖：额度失败但 Token 成功；Token 已有成功值后失败变为 `.stale`；两个并发 `refresh()` 只执行一组额度与 Token 请求；`stop()` 后迟到结果不得更新任一状态。

- [ ] **步骤 2：运行测试并确认 tokenState 与假提供者接口缺失**

运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UsageViewModelTests
```

预期：编译失败，指出 `tokenState` 或 `tokenResults` 不存在。

- [ ] **步骤 3：实现一次刷新中的双结果编排**

新增内部 `RefreshOutcome`，分别承载额度解析结果与 Token 解析结果。一次共享的 `refreshTask` 顺序执行两项请求，防止同一 actor 上并发重连竞态；发布阶段分别更新 `state` 与 `tokenState`。Token 失败保留本进程最后值为 `.stale`，但不写入 `UsageStore`。反馈文案使用“正在获取最新数据…”、“已刷新 · <时间>”、“额度已刷新，Token 暂不可用”或“Token 已刷新，额度暂不可用”。

- [ ] **步骤 4：运行聚焦测试并提交**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UsageViewModelTests
git add Sources/CodexBar/Usage/UsageViewModel.swift Tests/CodexBarTests/UsageViewModelTests.swift
git commit -m "feat: refresh quota and tokens independently"
```

### Task 4：实现方案 A 弹窗与动态颜色

**文件：**
- 修改：`Sources/CodexBar/UI/MenuBarView.swift`
- 修改：`Tests/CodexBarTests/MenuBarPresentationTests.swift`

**接口：**
- 消费：`UsageState`、`TokenUsageState`、`isRefreshing`、`refreshFeedback`。
- 产出：`TokenUsagePresentation.make(from:locale:)`。
- 保持：`MenuBarPresentation.accentLevel` 的 5 小时优先、每周回退规则。

- [ ] **步骤 1：写失败测试，锁定 Token 展示与新边界**

```swift
func testTokenPresentationFormatsCurrentValueWithGrouping() {
    let usage = DailyTokenUsage(tokens: 184_260, dateKey: "2026-09-11", fetchedAt: Date())
    let value = TokenUsagePresentation.make(
        from: .current(usage),
        locale: Locale(identifier: "en_US")
    )
    XCTAssertEqual(value.valueText, "184,260 tokens")
    XCTAssertNil(value.warningText)
}

func testTokenPresentationDoesNotInventZeroForUnavailableData() {
    let value = TokenUsagePresentation.make(from: .unavailable("响应缺少字段"))
    XCTAssertEqual(value.valueText, "--")
    XCTAssertNotNil(value.warningText)
}
```

更新额度阈值断言为 51/50/21/20，并保持“5 小时缺失时由每周驱动主色”的测试。

- [ ] **步骤 2：运行测试并确认展示类型缺失**

运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MenuBarPresentationTests
```

预期：编译失败，指出 `TokenUsagePresentation` 不存在。

- [ ] **步骤 3：按确认稿重写弹窗层级**

`MenuBarView` 使用约 350 点宽的中性原生背景：顶部左侧标题与状态圆点，右侧明确的 bordered“刷新”按钮；今日 Token 以 28 点圆角字体和等宽数字显示；额度改为纵向 `QuotaRow`，包含百分比、线性 `ProgressView` 与重置时间；底部横排登录启动与退出。移除整块状态色背景、描边和等权 `UsageCard`。`UsageLevel.warning` 映射为黄色，Token 文本保持主色/次要色。

刷新按钮在 `isRefreshing` 时显示小型 `ProgressView` 与“刷新中…”，结束后标题下状态读取 `refreshFeedback`。警告文案放在对应数据附近并允许换行。

- [ ] **步骤 4：运行聚焦测试、编译并提交**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MenuBarPresentationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
git add Sources/CodexBar/UI/MenuBarView.swift Tests/CodexBarTests/MenuBarPresentationTests.swift
git commit -m "feat: redesign usage popover"
```

### Task 5：更新中文说明并完成全量验证

**文件：**
- 修改：`README.md`

**接口：**
- 记录 `account/usage/read`、准实时语义、局部失败和新弹窗操作方式。

- [ ] **步骤 1：更新 README**

在项目简介、首次启动和常见问题中加入今日 Token：说明应用每 60 秒读取本地 App Server 的按日聚合值，正在运行的任务可能在结束后计入；Token 暂不可用时额度仍可更新；5 小时缺失时继续只显示周额度。

- [ ] **步骤 2：执行格式、测试与构建验证**

```bash
git diff --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash scripts/build-app.sh
```

预期：Swift 全量测试零失败，`.build/app/CodexBar.app` 成功生成且脚本退出码为 0。

- [ ] **步骤 3：提交 README**

```bash
git add README.md
git commit -m "docs: describe daily token usage"
```

- [ ] **步骤 4：人工验收清单**

启动构建产物并确认：明暗模式均无裁切；右上刷新按钮具有空闲、刷新中、已完成反馈；今日 Token 使用中性色；额度在 51/50/21/20 边界显示绿/黄/红；5 小时缺失时该行隐藏；Token 请求失败时额度仍可用。人工验收不自动安装到 `~/Applications`。

---

## 自检结果

- 规格覆盖：5 个任务分别覆盖领域、客户端、状态编排、界面和交付说明。
- 类型一致：`AccountTokenUsageResponse` 由 Task 1 产出，Task 2 客户端返回，Task 3 解析为 `DailyTokenUsage`，Task 4 负责展示。
- 局部失败：Task 3 的双结果与 Task 4 的独立展示共同覆盖。
- 占位扫描：计划未包含未定义的后续实现占位项。
