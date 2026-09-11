import Foundation

protocol CodexUsageProviding: Sendable {
    func connect() async throws
    func fetchRateLimits() async throws -> RateLimitsResponse
    func fetchAccountUsage() async throws -> AccountTokenUsageResponse
    func updates() -> AsyncStream<RateLimitsResponse>
    func stop() async
}

actor CodexAppServerClient: CodexUsageProviding {
    private let connection: any RPCConnecting
    private nonisolated let updateStream: AsyncStream<RateLimitsResponse>
    private let updateContinuation: AsyncStream<RateLimitsResponse>.Continuation
    private var isConnected = false
    private var isStopped = false
    private var notificationRefreshInFlight = false
    private var notificationRefreshPending = false
    private var currentNotificationBatch: Set<Data> = []
    private var lastPublishedResponse: RateLimitsResponse?

    init(connection: any RPCConnecting) {
        self.connection = connection
        var capturedContinuation: AsyncStream<RateLimitsResponse>.Continuation?
        self.updateStream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.updateContinuation = capturedContinuation!
    }

    init(executableURL: URL) {
        let transport = ProcessTransport(executableURL: executableURL)
        self.init(connection: JSONRPCConnection(transport: transport))
    }

    nonisolated func updates() -> AsyncStream<RateLimitsResponse> {
        updateStream
    }

    func connect() async throws {
        guard !isStopped else { throw CodexClientError.stopped }
        guard !isConnected else { return }

        await connection.setNotificationHandler { [weak self] method, params in
            Task { await self?.receiveNotification(method: method, params: params) }
        }
        do {
            try await connection.start()
            _ = try await connection.request(method: "initialize", params: Self.initializeParams)
            try await connection.notify(method: "initialized", params: nil)
            isConnected = true
        } catch {
            await connection.setNotificationHandler(nil)
            await connection.stop()
            throw error
        }
    }

    func fetchRateLimits() async throws -> RateLimitsResponse {
        guard !isStopped else { throw CodexClientError.stopped }
        if !isConnected {
            try await connect()
        }

        do {
            return try await requestRateLimits()
        } catch JSONRPCError.disconnected {
            isConnected = false
            try await connect()
            return try await requestRateLimits()
        } catch {
            if error is CodexClientError {
                isConnected = false
            }
            throw error
        }
    }

    func fetchAccountUsage() async throws -> AccountTokenUsageResponse {
        guard !isStopped else { throw CodexClientError.stopped }
        if !isConnected {
            try await connect()
        }

        do {
            return try await requestAccountUsage()
        } catch JSONRPCError.disconnected {
            isConnected = false
            try await connect()
            return try await requestAccountUsage()
        } catch {
            if error is CodexClientError {
                isConnected = false
            }
            throw error
        }
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        isConnected = false
        notificationRefreshInFlight = false
        notificationRefreshPending = false
        currentNotificationBatch.removeAll()
        await connection.setNotificationHandler(nil)
        await connection.stop()
        updateContinuation.finish()
    }

    private func requestRateLimits() async throws -> RateLimitsResponse {
        let value = try await connection.request(method: "account/rateLimits/read", params: nil)
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        } catch {
            throw CodexClientError.malformedRateLimitsResponse
        }
    }

    private func requestAccountUsage() async throws -> AccountTokenUsageResponse {
        let value = try await connection.request(method: "account/usage/read", params: nil)
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(AccountTokenUsageResponse.self, from: data)
        } catch {
            throw CodexClientError.malformedAccountUsageResponse
        }
    }

    private func receiveNotification(method: String, params: JSONValue?) {
        guard method == "account/rateLimits/updated", !isStopped else { return }
        let fingerprint = notificationFingerprint(params)
        guard currentNotificationBatch.insert(fingerprint).inserted else { return }
        if notificationRefreshInFlight {
            notificationRefreshPending = true
            return
        }
        notificationRefreshInFlight = true

        Task { [weak self] in
            await self?.refreshAfterNotification()
        }
    }

    private func refreshAfterNotification() async {
        defer {
            notificationRefreshInFlight = false
            notificationRefreshPending = false
            currentNotificationBatch.removeAll()
        }

        repeat {
            notificationRefreshPending = false
            if let response = try? await fetchRateLimits(), response != lastPublishedResponse {
                lastPublishedResponse = response
                updateContinuation.yield(response)
            }
        } while notificationRefreshPending && !isStopped
    }

    private func notificationFingerprint(_ params: JSONValue?) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(params ?? .null)) ?? Data()
    }

    private static let initializeParams: JSONValue = .object([
        "clientInfo": .object([
            "name": .string("codex_bar"),
            "title": .string("CodexBar"),
            "version": .string("0.1.0")
        ]),
        "capabilities": .object(["experimentalApi": .bool(false)])
    ])
}
