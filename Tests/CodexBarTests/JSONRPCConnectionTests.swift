import Foundation
import XCTest
@testable import CodexBar

final class JSONRPCConnectionTests: XCTestCase {
    func testPairsResponseByIDAndForwardsNotification() async throws {
        let transport = FakeRPCTransport()
        let connection = JSONRPCConnection(transport: transport)
        let recorder = NotificationRecorder()
        await connection.setNotificationHandler { method, params in
            Task { await recorder.append(method: method, params: params) }
        }
        try await connection.start()

        let request = Task { try await connection.request(method: "account/rateLimits/read", params: nil) }
        await transport.waitForWrites(count: 1)
        let sent = try await transport.request(at: 0)
        XCTAssertEqual(sent.method, "account/rateLimits/read")
        XCTAssertNil(sent.params)

        await transport.emit(#"{"id":\#(sent.id),"result":{"rateLimits":{}}}"#)
        let result = try await request.value
        XCTAssertEqual(result["rateLimits"], .object([:]))

        await transport.emit(#"{"method":"account/rateLimits/updated","params":{"changed":true}}"#)
        await recorder.waitForValues(count: 1)
        let notifications = await recorder.values
        XCTAssertEqual(notifications, [
            .init(method: "account/rateLimits/updated", params: .object(["changed": .bool(true)]))
        ])
    }

    func testPairsOutOfOrderResponsesByID() async throws {
        let transport = FakeRPCTransport()
        let connection = JSONRPCConnection(transport: transport)
        try await connection.start()

        let first = Task { try await connection.request(method: "first", params: nil) }
        let second = Task { try await connection.request(method: "second", params: nil) }
        await transport.waitForWrites(count: 2)
        let firstSent = try await transport.request(at: 0)
        let secondSent = try await transport.request(at: 1)

        await transport.emit(#"{"id":\#(secondSent.id),"result":"second"}"#)
        await transport.emit(#"{"id":\#(firstSent.id),"result":"first"}"#)

        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, .string("first"))
        XCTAssertEqual(secondResult, .string("second"))
    }

    func testMapsRemoteError() async throws {
        let transport = FakeRPCTransport()
        let connection = JSONRPCConnection(transport: transport)
        try await connection.start()

        let request = Task { try await connection.request(method: "bad", params: nil) }
        await transport.waitForWrites(count: 1)
        let sent = try await transport.request(at: 0)
        await transport.emit(#"{"id":\#(sent.id),"error":{"code":-32001,"message":"denied"}}"#)

        do {
            _ = try await request.value
            XCTFail("Expected remote JSON-RPC error")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .remote(code: -32_001, message: "denied"))
        }
    }

    func testTerminatesAllPendingRequests() async throws {
        let transport = FakeRPCTransport()
        let connection = JSONRPCConnection(transport: transport)
        try await connection.start()

        let first = Task { try await connection.request(method: "first", params: nil) }
        let second = Task { try await connection.request(method: "second", params: nil) }
        await transport.waitForWrites(count: 2)
        await transport.terminate(code: 9)

        for request in [first, second] {
            do {
                _ = try await request.value
                XCTFail("Expected disconnection")
            } catch {
                XCTAssertEqual(error as? JSONRPCError, .disconnected)
            }
        }
    }

    func testTimesOutAndCancelsPendingRequest() async throws {
        let transport = FakeRPCTransport()
        let connection = JSONRPCConnection(transport: transport)
        try await connection.start()

        let request = Task {
            try await connection.request(method: "slow", params: nil, timeout: .milliseconds(10))
        }
        await transport.waitForWrites(count: 1)

        do {
            _ = try await request.value
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .timedOut(method: "slow"))
        }
        let pendingRequestCount = await connection.pendingRequestCount
        XCTAssertEqual(pendingRequestCount, 0)
    }

    func testCancellingCallerRemovesPendingRequest() async throws {
        let transport = FakeRPCTransport()
        let connection = JSONRPCConnection(transport: transport)
        try await connection.start()

        let request = Task { try await connection.request(method: "cancelled", params: nil) }
        await transport.waitForWrites(count: 1)
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Expected caller cancellation")
        } catch is CancellationError {
            // The caller's cancellation is the public observable behavior.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let pendingRequestCount = await connection.pendingRequestCount
        XCTAssertEqual(pendingRequestCount, 0)
    }

    func testStopRejectsPendingRequestsAndStopsTransport() async throws {
        let transport = FakeRPCTransport()
        let connection = JSONRPCConnection(transport: transport)
        try await connection.start()

        let request = Task { try await connection.request(method: "read", params: nil) }
        await transport.waitForWrites(count: 1)
        await connection.stop()

        do {
            _ = try await request.value
            XCTFail("Expected stop to disconnect request")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .disconnected)
        }
        let stopCallCount = await transport.stopCallCount
        XCTAssertEqual(stopCallCount, 1)
    }
}

private struct RecordedRequest: Sendable {
    let id: Int
    let method: String
    let params: JSONValue?
}

private actor FakeRPCTransport: RPCTransport {
    private var onLine: (@Sendable (Data) -> Void)?
    private var onTermination: (@Sendable (Int32) -> Void)?
    private var writes: [Data] = []
    private var writeWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var stopCallCount = 0

    func start(
        onLine: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) async throws {
        self.onLine = onLine
        self.onTermination = onTermination
    }

    func write(_ data: Data) async throws {
        writes.append(data)
        resumeWriteWaiters()
    }

    func stop() async {
        stopCallCount += 1
    }

    func waitForWrites(count: Int) async {
        guard writes.count < count else { return }
        await withCheckedContinuation { continuation in
            writeWaiters.append((count, continuation))
        }
    }

    func request(at index: Int) throws -> RecordedRequest {
        let data = writes[index]
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(values) = object,
              case let .number(idValue)? = values["id"],
              let id = Int(exactly: idValue),
              case let .string(method)? = values["method"]
        else {
            throw JSONRPCError.malformedMessage
        }
        return RecordedRequest(id: id, method: method, params: values["params"])
    }

    func emit(_ line: String) {
        onLine?(Data(line.utf8))
    }

    func terminate(code: Int32) {
        onTermination?(code)
    }

    private func resumeWriteWaiters() {
        let ready = writeWaiters.filter { writes.count >= $0.count }
        writeWaiters.removeAll { writes.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

private struct NotificationValue: Equatable, Sendable {
    let method: String
    let params: JSONValue?
}

private actor NotificationRecorder {
    private(set) var values: [NotificationValue] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(method: String, params: JSONValue?) {
        values.append(.init(method: method, params: params))
        let ready = waiters.filter { values.count >= $0.count }
        waiters.removeAll { values.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForValues(count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}
