import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    subscript(_ key: String) -> JSONValue? {
        guard case let .object(values) = self else { return nil }
        return values[key]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum JSONRPCError: Error, Equatable, Sendable {
    case disconnected
    case timedOut(method: String)
    case remote(code: Int, message: String)
    case malformedMessage
}

protocol RPCTransport: Sendable {
    func start(
        onLine: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) async throws
    func write(_ data: Data) async throws
    func stop() async
}

protocol RPCConnecting: Sendable {
    func start() async throws
    func request(method: String, params: JSONValue?) async throws -> JSONValue
    func notify(method: String, params: JSONValue?) async throws
    func setNotificationHandler(_ handler: (@Sendable (String, JSONValue?) -> Void)?) async
    func stop() async
}

actor JSONRPCConnection: RPCConnecting {
    typealias NotificationHandler = @Sendable (String, JSONValue?) -> Void

    private let transport: any RPCTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var isStarted = false
    private var isStarting = false
    private var lifecycleGeneration = 0

    private(set) var onNotification: NotificationHandler?

    var pendingRequestCount: Int { pending.count }

    init(transport: any RPCTransport) {
        self.transport = transport
    }

    func start() async throws {
        guard !isStarted, !isStarting else { return }
        isStarting = true
        let generation = lifecycleGeneration

        do {
            try await transport.start(
                onLine: { [weak self] data in
                    Task { await self?.receive(data) }
                },
                onTermination: { [weak self] _ in
                    Task { await self?.transportDidTerminate(generation: generation) }
                }
            )
            guard lifecycleGeneration == generation, isStarting else {
                throw JSONRPCError.disconnected
            }
            isStarting = false
            isStarted = true
        } catch {
            if lifecycleGeneration == generation {
                isStarting = false
            }
            throw error
        }
    }

    func request(
        method: String,
        params: JSONValue?
    ) async throws -> JSONValue {
        try await request(method: method, params: params, timeout: .seconds(30))
    }

    func request(
        method: String,
        params: JSONValue?,
        timeout: Duration
    ) async throws -> JSONValue {
        guard isStarted else { throw JSONRPCError.disconnected }

        let id = nextRequestID
        nextRequestID += 1
        let data = try encodedMessage(id: id, method: method, params: params)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                pending[id] = continuation
                timeoutTasks[id] = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.finishRequest(id, with: .failure(JSONRPCError.timedOut(method: method)))
                }
                Task { [transport] in
                    do {
                        try await transport.write(data)
                    } catch {
                        self.finishRequest(id, with: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.finishRequest(id, with: .failure(CancellationError()))
            }
        }
    }

    func notify(method: String, params: JSONValue?) async throws {
        guard isStarted else { throw JSONRPCError.disconnected }
        let data = try encodedMessage(id: nil, method: method, params: params)
        try await transport.write(data)
    }

    func setNotificationHandler(_ handler: NotificationHandler?) {
        onNotification = handler
    }

    func stop() async {
        lifecycleGeneration += 1
        isStarted = false
        isStarting = false
        failAllPending(with: JSONRPCError.disconnected)
        await transport.stop()
    }

    private func encodedMessage(id: Int?, method: String, params: JSONValue?) throws -> Data {
        let message = OutgoingMessage(id: id, method: method, params: params)
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    private func receive(_ data: Data) {
        guard let message = try? decoder.decode(JSONValue.self, from: data),
              case let .object(values) = message else {
            return
        }

        if case let .string(method)? = values["method"] {
            onNotification?(method, values["params"])
            return
        }

        guard case let .number(idValue)? = values["id"],
              let id = Int(exactly: idValue) else {
            return
        }

        if let result = values["result"] {
            finishRequest(id, with: .success(result))
            return
        }

        guard case let .object(error)? = values["error"],
              case let .number(codeValue)? = error["code"],
              let code = Int(exactly: codeValue),
              case let .string(message)? = error["message"] else {
            finishRequest(id, with: .failure(JSONRPCError.malformedMessage))
            return
        }
        finishRequest(id, with: .failure(JSONRPCError.remote(code: code, message: message)))
    }

    private func transportDidTerminate(generation: Int) {
        guard lifecycleGeneration == generation else { return }
        lifecycleGeneration += 1
        isStarted = false
        isStarting = false
        failAllPending(with: JSONRPCError.disconnected)
    }

    private func finishRequest(_ id: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(with: result)
    }

    private func failAllPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        let activeTimeouts = timeoutTasks.values
        timeoutTasks.removeAll()
        activeTimeouts.forEach { $0.cancel() }
        continuations.forEach { $0.resume(throwing: error) }
    }
}

private struct OutgoingMessage: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int?
    let method: String
    let params: JSONValue?
}
