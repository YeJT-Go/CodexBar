import Foundation
import XCTest
@testable import CodexBar

@MainActor
final class UsageViewModelTests: XCTestCase {
    func testWeeklyOnlyRefreshReplacesPreviousTwoWindowCache() async {
        let old = makeSnapshot(fiveHour: 12, weekly: 34, fetchedAt: .distantPast)
        let store = InMemoryUsageStore(snapshot: old)
        let response = RateLimitsResponse(
            rateLimits: .init(
                limitId: "codex",
                primary: .init(usedPercent: 0, windowDurationMins: 10_080, resetsAt: nil),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )
        let model = UsageViewModel(
            client: FakeUsageProvider(fetchResults: [.success(response)]), store: store
        )

        await model.refresh()

        guard case let .current(snapshot) = model.state else {
            return XCTFail("仅周额度应刷新成功，不能继续显示旧缓存已过期")
        }
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly.remainingPercent, 100)
        XCTAssertEqual(store.load(), snapshot)
        XCTAssertFalse(model.isRefreshing)
    }

    func testSuccessfulRefreshPublishesCurrentAndSavesFetchedAt() async {
        let store = InMemoryUsageStore()
        let provider = FakeUsageProvider(fetchResults: [.success(makeResponse(fiveHourUsed: 20, weeklyUsed: 75))])
        let now = Date(timeIntervalSince1970: 1_788_700_000)
        let model = UsageViewModel(client: provider, store: store, now: { now })

        await model.refresh()

        guard case let .current(snapshot) = model.state else {
            return XCTFail("刷新成功后应为 current")
        }
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 80)
        XCTAssertEqual(snapshot.weekly.remainingPercent, 25)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(store.load(), snapshot)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(model.refreshFeedback?.hasPrefix("已刷新 · ") == true)
    }

    func testFailureKeepsLastGoodSnapshotAsStale() async {
        let provider = FakeUsageProvider(fetchResults: [
            .success(makeResponse(fiveHourUsed: 20, weeklyUsed: 75)),
            .failure(TestFailure.offline)
        ])
        let model = UsageViewModel(client: provider, store: InMemoryUsageStore())

        await model.refresh()
        await model.refresh()

        guard case let .stale(snapshot, message) = model.state else {
            return XCTFail("失败且有历史值时应为 stale")
        }
        XCTAssertEqual(snapshot.weekly.remainingPercent, 25)
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.refreshFeedback, "刷新失败，请重试")
    }

    func testFailureWithoutCacheIsUnavailableRatherThanZeroPercent() async {
        let model = UsageViewModel(
            client: FakeUsageProvider(fetchResults: [.failure(TestFailure.offline)]),
            store: InMemoryUsageStore()
        )

        await model.refresh()

        guard case .unavailable = model.state else {
            return XCTFail("没有任何快照时失败应为 unavailable")
        }
    }

    func testCachedSnapshotStartsAsStaleAndPreservesFetchedAt() {
        let old = makeSnapshot(fiveHour: 12, weekly: 34, fetchedAt: .distantPast)
        let store = InMemoryUsageStore(snapshot: old)

        let model = UsageViewModel(client: FakeUsageProvider(), store: store)

        guard case let .stale(cached, _) = model.state else {
            return XCTFail("缓存只能作为 stale 展示")
        }
        XCTAssertEqual(cached, old)
    }

    func testUsageStoreRoundTripsSnapshotIncludingFetchedAt() throws {
        let suiteName = "CodexBarTests.UsageStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UsageStore(defaults: defaults, key: "snapshot")
        let original = makeSnapshot(
            fiveHour: 51,
            weekly: 73,
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_123)
        )

        store.save(original)

        XCTAssertEqual(store.load(), original)
    }

    func testConcurrentRefreshesShareOneFetch() async {
        let gate = AsyncGate()
        let calls = Counter()
        let provider = FakeUsageProvider(fetch: {
            await calls.increment()
            await gate.wait()
            return makeResponse(fiveHourUsed: 10, weeklyUsed: 20)
        })
        let model = UsageViewModel(client: provider, store: InMemoryUsageStore())

        let first = Task { await model.refresh() }
        await eventually { await calls.value == 1 }
        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(model.refreshFeedback, "正在获取最新额度…")
        let second = Task { await model.refresh() }
        await spin()
        let callsWhileBlocked = await calls.getValue()
        XCTAssertEqual(callsWhileBlocked, 1)

        await gate.open()
        await first.value
        await second.value
        let finalCalls = await calls.getValue()
        XCTAssertEqual(finalCalls, 1)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(model.refreshFeedback?.hasPrefix("已刷新 · ") == true)
    }

    func testUpdateNotificationTriggersImmediateFullRefresh() async {
        let sleeper = ControlledSleeper()
        let provider = FakeUsageProvider(fetchResults: [
            .success(makeResponse(fiveHourUsed: 10, weeklyUsed: 20)),
            .success(makeResponse(fiveHourUsed: 30, weeklyUsed: 40))
        ])
        let model = UsageViewModel(
            client: provider,
            store: InMemoryUsageStore(),
            sleep: sleeper.sleep
        )

        model.start()
        await eventually {
            guard case let .current(value) = model.state else { return false }
            return provider.fetchCount == 1 && value.fiveHour?.remainingPercent == 90
        }
        provider.sendUpdate(makeResponse(fiveHourUsed: 99, weeklyUsed: 99))
        await eventually {
            guard case let .current(value) = model.state else { return false }
            return provider.fetchCount == 2 && value.fiveHour?.remainingPercent == 70
        }

        guard case let .current(value) = model.state else {
            return XCTFail("通知后的完整读取应更新 current")
        }
        XCTAssertEqual(value.fiveHour?.remainingPercent, 70)
        await model.stop()
    }

    func testRefreshLoopUsesConfiguredInterval() async {
        let sleeper = ControlledSleeper()
        let provider = FakeUsageProvider(fetchResults: [
            .success(makeResponse(fiveHourUsed: 10, weeklyUsed: 20)),
            .success(makeResponse(fiveHourUsed: 15, weeklyUsed: 25))
        ])
        let model = UsageViewModel(
            client: provider,
            store: InMemoryUsageStore(),
            refreshInterval: .seconds(60),
            sleep: sleeper.sleep
        )

        model.start()
        await eventually {
            let sleepCount = await sleeper.getCallCount()
            return provider.fetchCount == 1 && sleepCount >= 1
        }
        let firstDuration = await sleeper.getFirstDuration()
        XCTAssertEqual(firstDuration, .seconds(60))
        await sleeper.resumeFirst()
        await eventually { provider.fetchCount == 2 }
        await model.stop()
    }

    func testConnectRetriesWithCappedBackoffAndResetsAfterSuccess() async {
        let sleeps = DurationRecorder()
        let timerSleeper = ControlledSleeper()
        let provider = FakeUsageProvider(
            connectResults: Array(repeating: .failure(TestFailure.offline), count: 8) + [.success(())],
            fetchResults: [.success(makeResponse(fiveHourUsed: 10, weeklyUsed: 20))]
        )
        let model = UsageViewModel(
            client: provider,
            store: InMemoryUsageStore(),
            sleep: timerSleeper.sleep,
            reconnectSleep: sleeps.sleepImmediately
        )

        model.start()
        await eventually { provider.connectCount == 9 && provider.fetchCount == 1 }

        let recordedSleeps = await sleeps.prefix(8)
        XCTAssertEqual(recordedSleeps, [1, 2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) })
        await model.stop()
    }

    func testDisconnectAfterSuccessRestartsBackoffAtOneSecond() async {
        let timerSleeper = ControlledSleeper()
        let reconnectSleeper = ControlledSleeper()
        let provider = FakeUsageProvider(
            connectResults: [
                .failure(TestFailure.offline),
                .success(()),
                .failure(TestFailure.offline)
            ],
            fetchResults: [
                .success(makeResponse(fiveHourUsed: 10, weeklyUsed: 20)),
                .failure(CodexClientError.serverExited(code: 1, stderr: "exited"))
            ]
        )
        let model = UsageViewModel(
            client: provider,
            store: InMemoryUsageStore(),
            sleep: timerSleeper.sleep,
            reconnectSleep: reconnectSleeper.sleep
        )

        model.start()
        await eventually {
            let sleepCount = await reconnectSleeper.getCallCount()
            return provider.connectCount == 1 && sleepCount == 1
        }
        let initialDelay = await reconnectSleeper.getFirstDuration()
        XCTAssertEqual(initialDelay, .seconds(1))
        await reconnectSleeper.resumeFirst()
        await eventually {
            guard case .current = model.state else { return false }
            return provider.connectCount == 2 && provider.fetchCount == 1
        }

        await timerSleeper.resumeFirst()
        await eventually { provider.fetchCount == 2 }
        await eventually {
            let sleepCount = await reconnectSleeper.getCallCount()
            return provider.connectCount == 3 && sleepCount == 1
        }
        let postDisconnectDelay = await reconnectSleeper.getFirstDuration()
        XCTAssertEqual(postDisconnectDelay, .seconds(1))
        await model.stop()
    }

    func testImmediateExitAfterSuccessfulReconnectWaitsBeforeTryingAgain() async {
        let timerSleeper = ControlledSleeper()
        let reconnectSleeper = ControlledSleeper()
        let provider = FakeUsageProvider(
            connectResults: [.success(()), .success(()), .success(())],
            fetchResults: [
                .success(makeResponse(fiveHourUsed: 10, weeklyUsed: 20)),
                .failure(CodexClientError.serverExited(code: 1, stderr: "first exit")),
                .failure(CodexClientError.serverExited(code: 1, stderr: "second exit"))
            ]
        )
        let model = UsageViewModel(
            client: provider,
            store: InMemoryUsageStore(),
            sleep: timerSleeper.sleep,
            reconnectSleep: reconnectSleeper.sleep
        )

        model.start()
        await eventually {
            guard case .current = model.state else { return false }
            return provider.connectCount == 1 && provider.fetchCount == 1
        }
        await timerSleeper.resumeFirst()
        await eventually {
            let sleepCount = await reconnectSleeper.getCallCount()
            return provider.connectCount == 2 && provider.fetchCount == 3 && sleepCount == 1
        }

        let delay = await reconnectSleeper.getFirstDuration()
        XCTAssertEqual(delay, .seconds(1))
        XCTAssertEqual(provider.connectCount, 2, "等待完成前不得忙循环重启")
        await model.stop()
    }

    func testStopInvalidatesSuccessFromProviderThatIgnoresCancellation() async {
        let sequence = GatedFetchSequence([
            (AsyncGate(), makeResponse(fiveHourUsed: 10, weeklyUsed: 20))
        ])
        let provider = FakeUsageProvider(fetch: { try await sequence.next() })
        let store = InMemoryUsageStore()
        let model = UsageViewModel(client: provider, store: store)

        let refresh = Task { await model.refresh() }
        await eventually { provider.fetchCount == 1 }
        XCTAssertTrue(model.isRefreshing)
        await model.stop()
        XCTAssertFalse(model.isRefreshing)
        await sequence.open(at: 0)
        await refresh.value

        XCTAssertEqual(model.state, .loading)
        XCTAssertNil(store.load())
    }

    func testNewLifecycleRefreshIsNeverTemporarilyOverwrittenByOldResult() async {
        let sequence = GatedFetchSequence([
            (AsyncGate(), makeResponse(fiveHourUsed: 90, weeklyUsed: 90)),
            (AsyncGate(), makeResponse(fiveHourUsed: 20, weeklyUsed: 30))
        ])
        let provider = FakeUsageProvider(fetch: { try await sequence.next() })
        let store = InMemoryUsageStore()
        let model = UsageViewModel(client: provider, store: store)

        let oldRefresh = Task { await model.refresh() }
        await eventually { provider.fetchCount == 1 }
        await model.stop()
        let newRefresh = Task { await model.refresh() }
        await eventually { provider.fetchCount == 2 }

        await sequence.open(at: 0)
        await oldRefresh.value
        XCTAssertEqual(model.state, .loading)
        XCTAssertNil(store.load())

        await sequence.open(at: 1)
        await newRefresh.value
        guard case let .current(snapshot) = model.state else {
            return XCTFail("新生命周期刷新应成功发布")
        }
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 80)
        XCTAssertEqual(store.load(), snapshot)
    }

    func testStopCancelsPendingWorkAndStopsClient() async {
        let sleeper = ControlledSleeper()
        let provider = FakeUsageProvider(
            connectResults: [.failure(TestFailure.offline)],
            fetchResults: []
        )
        let model = UsageViewModel(
            client: provider,
            store: InMemoryUsageStore(),
            sleep: sleeper.sleep
        )

        model.start()
        await eventually {
            let sleepCount = await sleeper.getCallCount()
            return provider.connectCount == 1 && sleepCount >= 2
        }
        await model.stop()
        let callsAfterStop = provider.connectCount
        await sleeper.resumeAll()
        await spin(20)

        XCTAssertEqual(provider.stopCount, 1)
        XCTAssertEqual(provider.connectCount, callsAfterStop)
        let pendingSleeps = await sleeper.getPendingCount()
        XCTAssertEqual(pendingSleeps, 0)
    }

    private func eventually(
        attempts: Int = 1_000,
        condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("条件未在限定轮次内满足")
    }

    private func spin(_ count: Int = 10) async {
        for _ in 0..<count { await Task.yield() }
    }
}

private enum TestFailure: Error { case offline }

private func makeResponse(fiveHourUsed: Int, weeklyUsed: Int) -> RateLimitsResponse {
    RateLimitsResponse(
        rateLimits: .init(
            limitId: "codex",
            primary: .init(usedPercent: fiveHourUsed, windowDurationMins: 300, resetsAt: nil),
            secondary: .init(usedPercent: weeklyUsed, windowDurationMins: 10_080, resetsAt: nil)
        ),
        rateLimitsByLimitId: nil
    )
}

private func makeSnapshot(fiveHour: Int, weekly: Int, fetchedAt: Date) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: .init(remainingPercent: fiveHour, resetsAt: nil),
        weekly: .init(remainingPercent: weekly, resetsAt: nil),
        fetchedAt: fetchedAt
    )
}

private final class FakeUsageProvider: CodexUsageProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var connectResults: [Result<Void, Error>]
    private var fetchResults: [Result<RateLimitsResponse, Error>]
    private let fetchImpl: (@Sendable () async throws -> RateLimitsResponse)?
    private let stream: AsyncStream<RateLimitsResponse>
    private let continuation: AsyncStream<RateLimitsResponse>.Continuation
    private(set) var connectCount = 0
    private(set) var fetchCount = 0
    private(set) var stopCount = 0

    init(
        connectResults: [Result<Void, Error>] = [.success(())],
        fetchResults: [Result<RateLimitsResponse, Error>] = [],
        fetch: (@Sendable () async throws -> RateLimitsResponse)? = nil
    ) {
        self.connectResults = connectResults
        self.fetchResults = fetchResults
        self.fetchImpl = fetch
        var captured: AsyncStream<RateLimitsResponse>.Continuation?
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured!
    }

    func connect() async throws {
        let result: Result<Void, Error> = lock.withLock {
            connectCount += 1
            return connectResults.isEmpty ? .success(()) : connectResults.removeFirst()
        }
        try result.get()
    }

    func fetchRateLimits() async throws -> RateLimitsResponse {
        let implementation = lock.withLock { () -> (@Sendable () async throws -> RateLimitsResponse)? in
            fetchCount += 1
            return fetchImpl
        }
        if let implementation { return try await implementation() }
        return try lock.withLock {
            guard !fetchResults.isEmpty else { throw TestFailure.offline }
            return try fetchResults.removeFirst().get()
        }
    }

    func updates() -> AsyncStream<RateLimitsResponse> { stream }

    func stop() async {
        lock.withLock { stopCount += 1 }
        continuation.finish()
    }

    func sendUpdate(_ response: RateLimitsResponse) { continuation.yield(response) }
}

private final class InMemoryUsageStore: UsageStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: UsageSnapshot?

    init(snapshot: UsageSnapshot? = nil) { self.snapshot = snapshot }
    func load() -> UsageSnapshot? { lock.withLock { snapshot } }
    func save(_ value: UsageSnapshot) { lock.withLock { snapshot = value } }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
    func getValue() -> Int { value }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor GatedFetchSequence {
    private let entries: [(gate: AsyncGate, response: RateLimitsResponse)]
    private var index = 0

    init(_ entries: [(AsyncGate, RateLimitsResponse)]) {
        self.entries = entries
    }

    func next() async throws -> RateLimitsResponse {
        guard index < entries.count else { throw TestFailure.offline }
        let entry = entries[index]
        index += 1
        await entry.gate.wait()
        return entry.response
    }

    func open(at index: Int) async {
        await entries[index].gate.open()
    }
}

private actor DurationRecorder {
    private var values: [Duration] = []
    func sleepImmediately(_ duration: Duration) async throws { values.append(duration) }
    func prefix(_ count: Int) -> [Duration] { Array(values.prefix(count)) }
}

private actor ControlledSleeper {
    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []

    func getCallCount() -> Int { waiters.count }
    func getPendingCount() -> Int { waiters.count }
    func getFirstDuration() -> Duration? { waiters.values.first?.duration }

    nonisolated func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await self.register(id: id, duration: duration, continuation: continuation) }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func resumeFirst() {
        guard let id = waiters.keys.first, let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume()
    }

    func resumeAll() {
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }

    private func register(
        id: UUID,
        duration: Duration,
        continuation: CheckedContinuation<Void, Error>
    ) {
        if cancelledBeforeRegistration.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
        } else {
            waiters[id] = Waiter(duration: duration, continuation: continuation)
        }
    }

    private func cancel(id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelledBeforeRegistration.insert(id)
        }
    }
}
