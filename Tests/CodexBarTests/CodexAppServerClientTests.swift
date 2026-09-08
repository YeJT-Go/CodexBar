import Foundation
import XCTest
@testable import CodexBar

final class CodexAppServerClientTests: XCTestCase {
    func testConnectInitializesBeforeSendingInitializedNotification() async throws {
        let rpc = RecordingRPCConnection()
        let client = CodexAppServerClient(connection: rpc)

        try await client.connect()

        let events = await rpc.events
        XCTAssertEqual(events.map(\.method), ["initialize", "initialized"])
        XCTAssertEqual(events.map(\.kind), [.request, .notification])
        XCTAssertEqual(events.first?.params, .object([
            "clientInfo": .object([
                "name": .string("codex_bar"),
                "title": .string("CodexBar"),
                "version": .string("0.1.0")
            ]),
            "capabilities": .object(["experimentalApi": .bool(false)])
        ]))
    }

    func testFetchRateLimitsDecodesNamedCodexBucket() async throws {
        let response = try fixture(namedCodexUsedPercent: 12, fallbackUsedPercent: 91)
        let rpc = RecordingRPCConnection(responses: ["account/rateLimits/read": [.success(response)]])
        let client = CodexAppServerClient(connection: rpc)
        try await client.connect()

        let fetched = try await client.fetchRateLimits()

        XCTAssertEqual(fetched.rateLimitsByLimitId?["codex"]?.primary?.usedPercent, 12)
        XCTAssertEqual(fetched.rateLimits.primary?.usedPercent, 91)
    }

    func testFetchRateLimitsDecodesSingleBucketFallback() async throws {
        let response: JSONValue = .object([
            "rateLimits": .object([
                "limitId": .string("legacy"),
                "primary": window(usedPercent: 25, duration: 300, resetsAt: 1_800_000_000),
                "secondary": window(usedPercent: 50, duration: 10_080, resetsAt: 1_800_604_800)
            ])
        ])
        let rpc = RecordingRPCConnection(responses: ["account/rateLimits/read": [.success(response)]])
        let client = CodexAppServerClient(connection: rpc)
        try await client.connect()

        let fetched = try await client.fetchRateLimits()

        XCTAssertEqual(fetched.rateLimits.limitId, "legacy")
        XCTAssertNil(fetched.rateLimitsByLimitId)
    }

    func testDisconnectedReadReconnectsAndRetriesOnce() async throws {
        let response = try fixture(namedCodexUsedPercent: 18, fallbackUsedPercent: 80)
        let rpc = RecordingRPCConnection(responses: [
            "account/rateLimits/read": [
                .failure(JSONRPCError.disconnected),
                .success(response)
            ]
        ])
        let client = CodexAppServerClient(connection: rpc)
        try await client.connect()

        let fetched = try await client.fetchRateLimits()

        XCTAssertEqual(fetched.rateLimitsByLimitId?["codex"]?.primary?.usedPercent, 18)
        let rateLimitReadCount = await rpc.requestCount(for: "account/rateLimits/read")
        let initializeCount = await rpc.requestCount(for: "initialize")
        XCTAssertEqual(rateLimitReadCount, 2)
        XCTAssertEqual(initializeCount, 2)
    }

    func testSparseUpdateRefetchesAndPublishesCompleteSnapshot() async throws {
        let completeResponse = try fixture(namedCodexUsedPercent: 31, fallbackUsedPercent: 88)
        let rpc = RecordingRPCConnection(responses: [
            "account/rateLimits/read": [.success(completeResponse)]
        ])
        let client = CodexAppServerClient(connection: rpc)
        try await client.connect()
        let nextUpdate = Task { () -> RateLimitsResponse? in
            var iterator = client.updates().makeAsyncIterator()
            return await iterator.next()
        }

        await rpc.emitNotification(
            method: "account/rateLimits/updated",
            params: .object(["rateLimitsByLimitId": .object(["codex": .object(["primary": .object(["usedPercent": .number(31)])])])])
        )

        let receivedUpdate = await nextUpdate.value
        let update = try XCTUnwrap(receivedUpdate)
        XCTAssertEqual(update.rateLimitsByLimitId?["codex"]?.primary?.windowDurationMins, 300)
        XCTAssertEqual(update.rateLimitsByLimitId?["codex"]?.secondary?.windowDurationMins, 10_080)
        let requestCount = await rpc.requestCount(for: "account/rateLimits/read")
        XCTAssertEqual(requestCount, 1)
    }

    func testDuplicateSparseUpdatesAreCoalescedWhileRefreshIsInFlight() async throws {
        let completeResponse = try fixture(namedCodexUsedPercent: 42, fallbackUsedPercent: 84)
        let rpc = RecordingRPCConnection(
            responses: ["account/rateLimits/read": [.success(completeResponse)]],
            suspendRateLimitRead: true
        )
        let client = CodexAppServerClient(connection: rpc)
        try await client.connect()
        let sparse: JSONValue = .object(["limitId": .string("codex")])

        await rpc.emitNotification(method: "account/rateLimits/updated", params: sparse)
        await rpc.waitForRequests(method: "account/rateLimits/read", count: 1)
        await rpc.emitNotification(method: "account/rateLimits/updated", params: sparse)
        await rpc.releaseRateLimitRead()
        await rpc.waitForCompletedRequests(method: "account/rateLimits/read", count: 1)

        let requestCount = await rpc.requestCount(for: "account/rateLimits/read")
        XCTAssertEqual(requestCount, 1)
    }

    func testStopStopsConnectionAndFinishesUpdates() async throws {
        let rpc = RecordingRPCConnection()
        let client = CodexAppServerClient(connection: rpc)
        try await client.connect()
        let completion = Task { () -> RateLimitsResponse? in
            var iterator = client.updates().makeAsyncIterator()
            return await iterator.next()
        }

        await client.stop()

        let finalUpdate = await completion.value
        let stopCallCount = await rpc.stopCallCount
        let hasNotificationHandler = await rpc.hasNotificationHandler
        XCTAssertNil(finalUpdate)
        XCTAssertEqual(stopCallCount, 1)
        XCTAssertFalse(hasNotificationHandler)
    }

    func testProcessTransportFramesRealPipeChunksAndAddsNodeSearchPaths() async throws {
        let script = try TemporaryNodeScript(source: #"""
        process.stdout.write('{"first":1}\n{"sec');
        setTimeout(() => {
          process.stdout.write('ond":2}\n');
          process.exit(0);
        }, 20);
        """#)
        defer { script.remove() }
        let transport = ProcessTransport(
            executableURL: script.url,
            environment: ["PATH": "/usr/bin", "CODEX_BAR_SENTINEL": "kept"]
        )
        let recorder = ProcessEventRecorder()

        try await transport.start(
            onLine: { data in Task { await recorder.appendLine(data) } },
            onTermination: { code in Task { await recorder.terminate(code) } }
        )
        await recorder.waitForTermination()

        let strings = await recorder.strings
        let exitCode = await recorder.exitCode
        XCTAssertEqual(strings, [#"{"first":1}"#, #"{"second":2}"#])
        XCTAssertEqual(exitCode, 0)
    }

    func testNonzeroProcessExitFailsPendingRequestWithBoundedRedactedStderr() async throws {
        let script = try TemporaryNodeScript(source: #"""
        process.stderr.write('x'.repeat(5000));
        process.stderr.write('\nAuthorization: Bearer supersecret\n');
        setTimeout(() => process.exit(7), 30);
        """#)
        defer { script.remove() }
        let transport = ProcessTransport(executableURL: script.url)
        let connection = JSONRPCConnection(transport: transport)
        try await connection.start()

        do {
            _ = try await connection.request(method: "account/rateLimits/read", params: nil)
            XCTFail("Expected the process exit to fail the pending request")
        } catch let error as CodexClientError {
            guard case let .serverExited(code, stderr) = error else {
                return XCTFail("Unexpected client error: \(error)")
            }
            XCTAssertEqual(code, 7)
            XCTAssertLessThanOrEqual(stderr.utf8.count, 4096)
            XCTAssertFalse(stderr.contains("supersecret"))
            XCTAssertTrue(stderr.contains("[REDACTED]"))
        }
    }
}

private enum RecordedRPCKind: Equatable, Sendable {
    case request
    case notification
}

private struct RecordedRPCEvent: Equatable, Sendable {
    let kind: RecordedRPCKind
    let method: String
    let params: JSONValue?
}

private actor RecordingRPCConnection: RPCConnecting {
    private var responses: [String: [Result<JSONValue, Error>]]
    private let suspendRateLimitRead: Bool
    private var rateLimitReadContinuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [(method: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completionWaiters: [(method: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completedMethods: [String] = []
    private(set) var events: [RecordedRPCEvent] = []
    private(set) var stopCallCount = 0
    private(set) var currentNotificationHandler: (@Sendable (String, JSONValue?) -> Void)?

    var hasNotificationHandler: Bool { currentNotificationHandler != nil }

    init(
        responses: [String: [Result<JSONValue, Error>]] = [:],
        suspendRateLimitRead: Bool = false
    ) {
        self.responses = responses
        self.suspendRateLimitRead = suspendRateLimitRead
    }

    func start() async throws {}

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        events.append(.init(kind: .request, method: method, params: params))
        resumeRequestWaiters()
        if method == "account/rateLimits/read", suspendRateLimitRead {
            await withCheckedContinuation { continuation in
                rateLimitReadContinuation = continuation
            }
        }
        completedMethods.append(method)
        resumeCompletionWaiters()
        guard var methodResponses = responses[method], !methodResponses.isEmpty else {
            return .object([:])
        }
        let result = methodResponses.removeFirst()
        responses[method] = methodResponses
        return try result.get()
    }

    func notify(method: String, params: JSONValue?) async throws {
        events.append(.init(kind: .notification, method: method, params: params))
    }

    func setNotificationHandler(_ handler: (@Sendable (String, JSONValue?) -> Void)?) async {
        currentNotificationHandler = handler
    }

    func stop() async {
        stopCallCount += 1
    }

    func emitNotification(method: String, params: JSONValue?) {
        currentNotificationHandler?(method, params)
    }

    func requestCount(for method: String) -> Int {
        events.count { $0.kind == .request && $0.method == method }
    }

    func waitForRequests(method: String, count: Int) async {
        guard requestCount(for: method) < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((method, count, continuation))
        }
    }

    func waitForCompletedRequests(method: String, count: Int) async {
        guard completedMethods.count(where: { $0 == method }) < count else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append((method, count, continuation))
        }
    }

    func releaseRateLimitRead() {
        rateLimitReadContinuation?.resume()
        rateLimitReadContinuation = nil
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requestCount(for: $0.method) >= $0.count }
        requestWaiters.removeAll { requestCount(for: $0.method) >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    private func resumeCompletionWaiters() {
        let ready = completionWaiters.filter { waiter in
            completedMethods.count(where: { $0 == waiter.method }) >= waiter.count
        }
        completionWaiters.removeAll { waiter in
            completedMethods.count(where: { $0 == waiter.method }) >= waiter.count
        }
        ready.forEach { $0.continuation.resume() }
    }
}

private actor ProcessEventRecorder {
    private(set) var strings: [String] = []
    private(set) var exitCode: Int32?
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    func appendLine(_ data: Data) {
        strings.append(String(decoding: data, as: UTF8.self))
    }

    func terminate(_ code: Int32) {
        exitCode = code
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForTermination() async {
        guard exitCode == nil else { return }
        await withCheckedContinuation { terminationWaiters.append($0) }
    }
}

private struct TemporaryNodeScript {
    let directory: URL
    let url: URL

    init(source: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarTests-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("fake-codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = "#!/usr/bin/env node\n\(source)\n"
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func fixture(namedCodexUsedPercent: Int, fallbackUsedPercent: Int) throws -> JSONValue {
    .object([
        "rateLimits": .object([
            "limitId": .string("legacy"),
            "primary": window(usedPercent: fallbackUsedPercent, duration: 300, resetsAt: 1_800_000_000),
            "secondary": window(usedPercent: fallbackUsedPercent, duration: 10_080, resetsAt: 1_800_604_800)
        ]),
        "rateLimitsByLimitId": .object([
            "codex": .object([
                "limitId": .string("codex"),
                "primary": window(usedPercent: namedCodexUsedPercent, duration: 300, resetsAt: 1_800_000_000),
                "secondary": window(usedPercent: namedCodexUsedPercent + 1, duration: 10_080, resetsAt: 1_800_604_800)
            ])
        ])
    ])
}

private func window(usedPercent: Int, duration: Int, resetsAt: Int) -> JSONValue {
    .object([
        "usedPercent": .number(Double(usedPercent)),
        "windowDurationMins": .number(Double(duration)),
        "resetsAt": .number(Double(resetsAt))
    ])
}
