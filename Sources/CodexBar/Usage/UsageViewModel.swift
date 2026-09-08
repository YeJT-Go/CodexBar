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

    @Published private(set) var state: UsageState

    private let client: any CodexUsageProviding
    private let parser: RateLimitParser
    private let store: any UsageStoring
    private let refreshInterval: Duration
    private let sleep: Sleep
    private let reconnectSleep: Sleep
    private let now: @Sendable () -> Date

    private var lastGoodSnapshot: UsageSnapshot?
    private var reconnectTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var refreshTask: Task<Result<UsageSnapshot, Error>, Never>?
    private var refreshGeneration: Int?
    private var nextRefreshGeneration = 0
    private var lastAppliedGeneration = 0
    private var isRunning = false

    init(
        client: any CodexUsageProviding,
        parser: RateLimitParser = RateLimitParser(),
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
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        reconnectTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
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
        let task: Task<Result<UsageSnapshot, Error>, Never>
        let taskGeneration: Int
        if let inFlight = refreshTask {
            task = inFlight
            taskGeneration = refreshGeneration!
        } else {
            let client = self.client
            let parser = self.parser
            let now = self.now
            let created = Task<Result<UsageSnapshot, Error>, Never> {
                do {
                    let response = try await client.fetchRateLimits()
                    return Result.success(try parser.parse(response, now: now()))
                } catch {
                    return Result.failure(error)
                }
            }
            nextRefreshGeneration += 1
            let createdGeneration = nextRefreshGeneration
            refreshTask = created
            refreshGeneration = createdGeneration
            task = created
            taskGeneration = createdGeneration
        }

        let result = await task.value
        if refreshGeneration == taskGeneration {
            refreshTask = nil
            refreshGeneration = nil
        }
        guard !Task.isCancelled, taskGeneration >= lastAppliedGeneration else { return }
        lastAppliedGeneration = taskGeneration

        switch result {
        case let .success(snapshot):
            lastGoodSnapshot = snapshot
            store.save(snapshot)
            state = .current(snapshot)
        case let .failure(error):
            publishFailure(error)
        }
    }

    func stop() async {
        guard isRunning || reconnectTask != nil || timerTask != nil || updatesTask != nil || refreshTask != nil else {
            return
        }
        isRunning = false
        reconnectTask?.cancel()
        timerTask?.cancel()
        updatesTask?.cancel()
        refreshTask?.cancel()
        reconnectTask = nil
        timerTask = nil
        updatesTask = nil
        refreshTask = nil
        refreshGeneration = nil
        await client.stop()
    }

    private func runConnectionLoop() async {
        let delays = [1, 2, 4, 8, 16, 32, 60]
        var retryIndex = 0

        while isRunning && !Task.isCancelled {
            do {
                try await client.connect()
                retryIndex = 0
                await refresh()
                return
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
}
