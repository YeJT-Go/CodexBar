import Combine
import Foundation

enum UsageState: Equatable, Sendable {
    case loading
    case current(UsageSnapshot)
    case stale(UsageSnapshot, String)
    case unavailable(String)
}

@MainActor
final class UsageViewModel: ObservableObject {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct RefreshOutcome: @unchecked Sendable {
        let quota: Result<UsageSnapshot, Error>
        let tokenUsage: Result<DailyTokenUsage, Error>?
    }

    private struct RefreshToken: Equatable {
        let lifecycle: Int
        let generation: Int
    }

    @Published private(set) var state: UsageState
    @Published private(set) var tokenState: TokenUsageState
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshFeedback: String?

    private let client: any CodexUsageProviding
    private let parser: RateLimitParser
    private let tokenParser: TokenUsageParser
    private let tokenUsageEnabled: Bool
    private let store: any UsageStoring
    private let refreshInterval: Duration
    private let sleep: Sleep
    private let reconnectSleep: Sleep
    private let now: @Sendable () -> Date

    private var lastGoodSnapshot: UsageSnapshot?
    private var lastGoodTokenUsage: DailyTokenUsage?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectGeneration = 0
    private var activeReconnectGeneration: Int?
    private var reconnectRequested = false
    private var timerTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var refreshTask: Task<RefreshOutcome, Never>?
    private var activeRefreshToken: RefreshToken?
    private var latestValidRefreshToken: RefreshToken?
    private var nextRefreshGeneration = 0
    private var lifecycleEpoch = 0
    private var isRunning = false

    init(
        client: any CodexUsageProviding,
        parser: RateLimitParser = RateLimitParser(),
        tokenParser: TokenUsageParser = TokenUsageParser(),
        tokenUsageEnabled: Bool = false,
        store: any UsageStoring = UsageStore(),
        refreshInterval: Duration = .seconds(60),
        sleep: @escaping Sleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        },
        reconnectSleep: Sleep? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.parser = parser
        self.tokenParser = tokenParser
        self.tokenUsageEnabled = tokenUsageEnabled
        self.store = store
        self.refreshInterval = refreshInterval
        self.sleep = sleep
        self.reconnectSleep = reconnectSleep ?? sleep
        self.now = now

        if let cached = store.load() {
            lastGoodSnapshot = cached
            state = .stale(cached, "正在刷新缓存数据")
        } else {
            state = .loading
        }
        tokenState = .loading
    }

    func start() {
        guard !isRunning else { return }
        beginNewLifecycle()
        isRunning = true

        requestReconnect()
        timerTask = Task { [weak self] in
            await self?.runRefreshLoop()
        }
        let updateStream = client.updates()
        updatesTask = Task { [weak self] in
            for await _ in updateStream {
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        let task: Task<RefreshOutcome, Never>
        let token: RefreshToken
        if let inFlight = refreshTask,
           let inFlightToken = activeRefreshToken,
           inFlightToken.lifecycle == lifecycleEpoch {
            task = inFlight
            token = inFlightToken
        } else {
            let client = self.client
            isRefreshing = true
            refreshFeedback = "正在获取最新数据…"
            let parser = self.parser
            let tokenParser = self.tokenParser
            let tokenUsageEnabled = self.tokenUsageEnabled
            let now = self.now
            let created = Task<RefreshOutcome, Never> {
                let quota: Result<UsageSnapshot, Error>
                do {
                    let response = try await client.fetchRateLimits()
                    quota = .success(try parser.parse(response, now: now()))
                } catch {
                    quota = .failure(error)
                }

                let tokenUsage: Result<DailyTokenUsage, Error>?
                if tokenUsageEnabled {
                    do {
                        let response = try await client.fetchAccountUsage()
                        tokenUsage = .success(try tokenParser.parse(response, now: now()))
                    } catch {
                        tokenUsage = .failure(error)
                    }
                } else {
                    tokenUsage = nil
                }

                return RefreshOutcome(quota: quota, tokenUsage: tokenUsage)
            }
            nextRefreshGeneration += 1
            let createdToken = RefreshToken(
                lifecycle: lifecycleEpoch,
                generation: nextRefreshGeneration
            )
            refreshTask = created
            activeRefreshToken = createdToken
            latestValidRefreshToken = createdToken
            task = created
            token = createdToken
        }

        let outcome = await task.value
        if activeRefreshToken == token {
            isRefreshing = false
            refreshTask = nil
            activeRefreshToken = nil
        }
        guard !Task.isCancelled,
              token.lifecycle == lifecycleEpoch,
              latestValidRefreshToken == token else { return }

        let quotaSucceeded: Bool
        switch outcome.quota {
        case let .success(snapshot):
            quotaSucceeded = true
            lastGoodSnapshot = snapshot
            store.save(snapshot)
            state = .current(snapshot)
        case let .failure(error):
            quotaSucceeded = false
            publishFailure(error)
            if isRunning, isConnectionFailure(error) {
                requestReconnect()
            }
        }

        let tokenSucceeded: Bool?
        switch outcome.tokenUsage {
        case let .success(tokenUsage)?:
            tokenSucceeded = true
            lastGoodTokenUsage = tokenUsage
            tokenState = .current(tokenUsage)
        case let .failure(error)?:
            tokenSucceeded = false
            publishTokenFailure(error)
            if isRunning, isConnectionFailure(error) {
                requestReconnect()
            }
        case nil:
            tokenSucceeded = nil
        }

        switch (quotaSucceeded, tokenSucceeded) {
        case (true, true), (true, nil):
            let refreshedAt = lastGoodSnapshot?.fetchedAt ?? now()
            refreshFeedback = "已刷新 · " + refreshedAt.formatted(date: .omitted, time: .standard)
        case (true, false):
            refreshFeedback = "额度已刷新，Token 暂不可用"
        case (false, true):
            refreshFeedback = "Token 已刷新，额度暂不可用"
        case (false, false), (false, nil):
            refreshFeedback = "刷新失败，请重试"
        }
    }

    func stop() async {
        guard isRunning || reconnectTask != nil || timerTask != nil || updatesTask != nil || refreshTask != nil else {
            return
        }
        isRunning = false
        isRefreshing = false
        lifecycleEpoch += 1
        reconnectRequested = false
        reconnectTask?.cancel()
        timerTask?.cancel()
        updatesTask?.cancel()
        refreshTask?.cancel()
        reconnectTask = nil
        activeReconnectGeneration = nil
        timerTask = nil
        updatesTask = nil
        refreshTask = nil
        activeRefreshToken = nil
        latestValidRefreshToken = nil
        await client.stop()
    }

    private func requestReconnect() {
        guard isRunning else { return }
        reconnectRequested = true
        guard reconnectTask == nil else { return }

        reconnectGeneration += 1
        let generation = reconnectGeneration
        let lifecycle = lifecycleEpoch
        activeReconnectGeneration = generation
        reconnectTask = Task { [weak self] in
            await self?.runConnectionLoop(lifecycle: lifecycle)
            self?.finishReconnect(generation: generation, lifecycle: lifecycle)
        }
    }

    private func runConnectionLoop(lifecycle: Int) async {
        let delays = [1, 2, 4, 8, 16, 32, 60]
        var retryIndex = 0

        while isRunning && lifecycleEpoch == lifecycle && !Task.isCancelled {
            do {
                try await client.connect()
                retryIndex = 0
                reconnectRequested = false
                await refresh()
                if !reconnectRequested { return }
                let seconds = delays[min(retryIndex, delays.count - 1)]
                retryIndex = min(retryIndex + 1, delays.count - 1)
                do {
                    try await reconnectSleep(.seconds(seconds))
                } catch {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                publishFailure(error)
                let seconds = delays[min(retryIndex, delays.count - 1)]
                retryIndex = min(retryIndex + 1, delays.count - 1)
                do {
                    try await reconnectSleep(.seconds(seconds))
                } catch {
                    return
                }
            }
        }
    }

    private func finishReconnect(generation: Int, lifecycle: Int) {
        guard activeReconnectGeneration == generation else { return }
        reconnectTask = nil
        activeReconnectGeneration = nil
        if reconnectRequested, isRunning, lifecycleEpoch == lifecycle {
            requestReconnect()
        }
    }

    private func runRefreshLoop() async {
        while isRunning && !Task.isCancelled {
            do {
                try await sleep(refreshInterval)
            } catch {
                return
            }
            guard isRunning && !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func publishFailure(_ error: Error) {
        let message = error.localizedDescription
        if let snapshot = lastGoodSnapshot {
            state = .stale(snapshot, message)
        } else {
            state = .unavailable(message)
        }
    }

    private func publishTokenFailure(_ error: Error) {
        let message = error.localizedDescription
        if let tokenUsage = lastGoodTokenUsage {
            tokenState = .stale(tokenUsage, message)
        } else {
            tokenState = .unavailable(message)
        }
    }

    private func beginNewLifecycle() {
        isRefreshing = false
        lifecycleEpoch += 1
        refreshTask?.cancel()
        refreshTask = nil
        activeRefreshToken = nil
        latestValidRefreshToken = nil
    }

    private func isConnectionFailure(_ error: Error) -> Bool {
        if let rpcError = error as? JSONRPCError, rpcError == .disconnected {
            return true
        }
        if case .serverExited = error as? CodexClientError {
            return true
        }
        return false
    }
}
