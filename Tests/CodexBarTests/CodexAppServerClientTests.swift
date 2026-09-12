import Foundation
import Darwin
import XCTest
@testable import CodexBar

final class CodexAppServerClientTests: XCTestCase {
    func testJSONLineFramerBoundsContinuousFrameAndDiscardsTailUntilLineFeed() {
        var framer = JSONLineFramer()
        let chunk = Data(repeating: 0x78, count: 64 * 1024)

        for _ in 0..<16 {
            let output = framer.consume(chunk)
            XCTAssertTrue(output.lines.isEmpty)
            XCTAssertFalse(output.didExceedMaximumFrameBytes)
            XCTAssertLessThanOrEqual(framer.pendingByteCount, 1024 * 1024)
        }
        let overflow = framer.consume(Data([0x78]))
        let pendingBytesAfterOverflow = framer.pendingByteCount
        let wasDiscardingAfterOverflow = framer.isDiscardingOversizedFrame
        let recovery = framer.consume(Data("""
        tail-must-not-be-a-line
        {"valid":true}

        """.utf8))

        XCTAssertTrue(overflow.didExceedMaximumFrameBytes)
        XCTAssertEqual(pendingBytesAfterOverflow, 0)
        XCTAssertTrue(wasDiscardingAfterOverflow)
        XCTAssertFalse(framer.isDiscardingOversizedFrame)
        XCTAssertEqual(recovery.lines.map { String(decoding: $0, as: UTF8.self) }, [#"{"valid":true}"#])
    }

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
        let events = await rpc.events
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(events.last?.params, nil)
    }

    func testFetchAccountUsageThrowsMalformedErrorWhenSummaryIsMissing() async throws {
        let rpc = RecordingRPCConnection(responses: [
            "account/usage/read": [.success(.object(["dailyUsageBuckets": .array([])]))]
        ])
        let client = CodexAppServerClient(connection: rpc)

        do {
            _ = try await client.fetchAccountUsage()
            XCTFail("缺少 summary 的响应必须被拒绝")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .malformedAccountUsageResponse)
        }
    }

    func testDisconnectedAccountUsageReadReconnectsAndRetriesOnce() async throws {
        let value: JSONValue = .object([
            "summary": .object([
                "lifetimeTokens": .number(184_260),
                "peakDailyTokens": .number(90_000),
                "currentStreakDays": .number(3),
                "longestStreakDays": .number(7),
                "longestRunningTurnSec": .number(600)
            ]),
            "dailyUsageBuckets": .array([])
        ])
        let rpc = RecordingRPCConnection(responses: [
            "account/usage/read": [.failure(JSONRPCError.disconnected), .success(value)]
        ])
        let client = CodexAppServerClient(connection: rpc)
        try await client.connect()

        _ = try await client.fetchAccountUsage()

        let usageReadCount = await rpc.requestCount(for: "account/usage/read")
        let initializeCount = await rpc.requestCount(for: "initialize")
        XCTAssertEqual(usageReadCount, 2)
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

    func testSameSparsePayloadRefreshesAgainAfterPreviousBatchCompletes() async throws {
        let firstResponse = try fixture(namedCodexUsedPercent: 42, fallbackUsedPercent: 84)
        let secondResponse = try fixture(namedCodexUsedPercent: 43, fallbackUsedPercent: 83)
        let rpc = RecordingRPCConnection(responses: [
            "account/rateLimits/read": [.success(firstResponse), .success(secondResponse)]
        ])
        let client = CodexAppServerClient(connection: rpc)
        try await client.connect()
        let sparse: JSONValue = .object(["limitId": .string("codex")])

        await rpc.emitNotification(method: "account/rateLimits/updated", params: sparse)
        try await waitForCompletedRequests(on: rpc, method: "account/rateLimits/read", count: 1)
        await rpc.emitNotification(method: "account/rateLimits/updated", params: sparse)
        try await waitForCompletedRequests(on: rpc, method: "account/rateLimits/read", count: 2)

        let requestCount = await rpc.requestCount(for: "account/rateLimits/read")
        XCTAssertEqual(requestCount, 2)
    }

    func testDifferentNotificationDuringRefreshQueuesOneSerialFollowUp() async throws {
        let firstResponse = try fixture(namedCodexUsedPercent: 44, fallbackUsedPercent: 82)
        let secondResponse = try fixture(namedCodexUsedPercent: 45, fallbackUsedPercent: 81)
        let rpc = RecordingRPCConnection(
            responses: ["account/rateLimits/read": [.success(firstResponse), .success(secondResponse)]],
            suspendRateLimitRead: true
        )
        let client = CodexAppServerClient(connection: rpc)
        try await client.connect()

        await rpc.emitNotification(
            method: "account/rateLimits/updated",
            params: .object(["usedPercent": .number(44)])
        )
        try await waitForRequests(on: rpc, method: "account/rateLimits/read", count: 1)
        await rpc.emitNotification(
            method: "account/rateLimits/updated",
            params: .object(["usedPercent": .number(45)])
        )
        await rpc.releaseRateLimitRead()
        try await waitForRequests(on: rpc, method: "account/rateLimits/read", count: 2)
        await rpc.releaseRateLimitRead()
        try await waitForCompletedRequests(on: rpc, method: "account/rateLimits/read", count: 2)

        let maximumConcurrentReads = await rpc.maximumConcurrentRateLimitReads
        XCTAssertEqual(maximumConcurrentReads, 1)
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
        process.stdout.write(JSON.stringify({path: process.env.PATH, sentinel: process.env.CODEX_BAR_SENTINEL}) + '\n{"sec');
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
        let environment = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(strings.first).utf8)) as? [String: String]
        )
        let pathDirectories = try XCTUnwrap(environment["path"]).split(separator: ":").map(String.init)
        XCTAssertTrue(pathDirectories.contains("/opt/homebrew/bin"))
        XCTAssertTrue(pathDirectories.contains("/usr/local/bin"))
        XCTAssertEqual(environment["sentinel"], "kept")
        XCTAssertEqual(strings.dropFirst(), [#"{"second":2}"#])
        XCTAssertEqual(exitCode, 0)
    }

    func testTerminationDrainIsBoundedWhenDescendantKeepsPipesOpen() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarTests-child-finished-\(UUID().uuidString)")
        let pidMarker = marker.appendingPathExtension("pid")
        defer {
            if !FileManager.default.fileExists(atPath: marker.path), let pid = processID(from: pidMarker) {
                _ = Darwin.kill(pid, SIGTERM)
            }
            removeIfPresent(marker)
            removeIfPresent(pidMarker)
        }
        let escapedMarker = marker.path.replacingOccurrences(of: "'", with: "\\'")
        let escapedPIDMarker = pidMarker.path.replacingOccurrences(of: "'", with: "\\'")
        let script = try TemporaryNodeScript(source: """
        const {spawn} = require('child_process');
        const child = spawn(process.execPath,
              ['-e', "setTimeout(() => require('fs').writeFileSync('\(escapedMarker)', 'done'), 300)"],
              {stdio: ['ignore', 'inherit', 'inherit']});
        require('fs').writeFileSync('\(escapedPIDMarker)', String(child.pid));
        process.stdout.write('{"beforeExit":true}\\n');
        process.exit(0);
        """)
        defer { script.remove() }
        let transport = ProcessTransport(executableURL: script.url)
        let recorder = BoundedTerminationRecorder(expectedLine: #"{"beforeExit":true}"#)

        try await transport.start(
            onLine: { recorder.appendLine(String(decoding: $0, as: UTF8.self)) },
            onTermination: { recorder.appendTermination($0) }
        )
        try await waitUntil(timeout: .seconds(2)) { processID(from: pidMarker) != nil }
        try await waitUntil(timeout: .seconds(1)) { recorder.hasExpectedLine }
        try await waitUntil(timeout: .milliseconds(250)) { recorder.hasTerminated }
        try await waitUntil(timeout: .seconds(1)) { FileManager.default.fileExists(atPath: marker.path) }

        XCTAssertLessThan(try XCTUnwrap(recorder.lineToTerminationDuration), .milliseconds(250))
        XCTAssertTrue(recorder.expectedLinePrecededTermination)
        XCTAssertEqual(recorder.exitCode, 0)
    }

    func testTerminationDrainIsBoundedWhileDescendantContinuouslyWrites() async throws {
        let pidMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarTests-continuous-child-\(UUID().uuidString).pid")
        let escapedPIDMarker = pidMarker.path.replacingOccurrences(of: "'", with: "\\'")
        let parent = try TemporaryNodeScript(source: """
        const {spawn} = require('child_process');
        const fs = require('fs');
        process.stdout.write('{"beforeContinuousWrite":true}\\n');
        const writers = spawn('/bin/sh', ['-c',
              "/usr/bin/yes '{\\\"noise\\\":true}' & /usr/bin/yes 'TOKEN=continuous-secret' >&2 & wait"],
              {stdio: ['ignore', 'inherit', 'inherit'], detached: true});
        fs.writeFileSync('\(escapedPIDMarker)', String(writers.pid));
        writers.on('spawn', () => {
          setTimeout(() => process.exit(0), 20);
        });
        """)
        let cleanup = DescendantProcessCleanup(pidFile: pidMarker, targetsProcessGroup: true)
        defer {
            cleanup.terminateAndWait()
            parent.remove()
            removeIfPresent(pidMarker)
        }
        let transport = ProcessTransport(executableURL: parent.url)
        let recorder = BoundedTerminationRecorder(expectedLine: #"{"beforeContinuousWrite":true}"#)

        try await transport.start(
            onLine: { recorder.appendLine(String(decoding: $0, as: UTF8.self)) },
            onTermination: { recorder.appendTermination($0) }
        )
        try await waitUntil(timeout: .seconds(2)) { processID(from: pidMarker) != nil }
        try await waitUntil(timeout: .seconds(1)) { recorder.hasExpectedLine }
        try await waitUntil(timeout: .milliseconds(500)) { recorder.hasTerminated }
        let lineToTermination = try XCTUnwrap(recorder.lineToTerminationDuration)
        cleanup.terminateAndWait()

        XCTAssertLessThan(lineToTermination, .milliseconds(250))
        XCTAssertTrue(recorder.expectedLinePrecededTermination)
        XCTAssertEqual(recorder.exitCode, 0)
        XCTAssertFalse(cleanup.isRunning)
    }

    func testOversizedStdoutFloodIsDiscardedAndTerminatesWithDiagnostic() async throws {
        let pidMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarTests-oversized-stdout-\(UUID().uuidString).pid")
        let escapedPIDMarker = pidMarker.path.replacingOccurrences(of: "'", with: "\\'")
        let script = try TemporaryNodeScript(source: """
        const fs = require('fs');
        fs.writeFileSync('\(escapedPIDMarker)', String(process.pid));
        const chunk = Buffer.alloc(64 * 1024, 0x78);
        function flood() {
          while (process.stdout.write(chunk)) {}
        }
        process.stdout.on('drain', flood);
        flood();
        setInterval(() => {}, 1000);
        """)
        let cleanup = DescendantProcessCleanup(pidFile: pidMarker)
        defer {
            cleanup.terminateAndWait()
            script.remove()
            try? FileManager.default.removeItem(at: pidMarker)
        }
        let transport = ProcessTransport(
            executableURL: script.url,
            maximumStdoutFrameBytes: 32 * 1024
        )
        let recorder = ProtocolViolationRecorder()

        try await transport.start(
            onLine: { _ in recorder.recordLine() },
            onTermination: { recorder.recordTermination($0) }
        )
        var terminatedInTime = true
        do {
            try await waitUntil(timeout: .milliseconds(500)) { recorder.hasTerminated }
        } catch {
            terminatedInTime = false
            await transport.stop()
            try? await waitUntil(timeout: .milliseconds(500)) { recorder.hasTerminated }
        }
        let exitCode = try XCTUnwrap(recorder.exitCode)
        let terminationError = await transport.terminationError(for: exitCode)
        cleanup.terminateAndWait()

        XCTAssertTrue(terminatedInTime)
        XCTAssertEqual(recorder.lineCount, 0)
        guard case let .serverExited(errorCode, diagnostic)? = terminationError else {
            return XCTFail("Expected a controlled oversized-frame termination error")
        }
        XCTAssertEqual(errorCode, exitCode)
        XCTAssertTrue(
            diagnostic.contains("stdout frame exceeded 32768-byte limit"),
            "Unexpected diagnostic: \(diagnostic)"
        )
        XCTAssertFalse(cleanup.isRunning)
    }

    func testImmediateProcessExitDeliversDrainedLineBeforeTermination() async throws {
        let script = try TemporaryNodeScript(source: #"""
        process.stdout.write('{"last":true}\n');
        process.exit(0);
        """#)
        defer { script.remove() }
        let transport = ProcessTransport(executableURL: script.url)
        let recorder = SynchronousProcessEventRecorder()

        try await transport.start(
            onLine: { recorder.appendLine(String(decoding: $0, as: UTF8.self)) },
            onTermination: { recorder.appendTermination($0) }
        )
        try await waitUntil { recorder.hasTerminated }

        XCTAssertEqual(recorder.events, [.line(#"{"last":true}"#), .termination(0)])
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

    func testImmediateExitRedactsCredentialFormsBeforeFourKilobyteLimit() async throws {
        let script = try TemporaryNodeScript(source: #"""
        process.stderr.write('z'.repeat(4050) + '\n');
        process.stderr.write('Authorization: Basic basic-secret\n');
        process.stderr.write('Authorization: Bearer bearer-secret\n');
        process.stderr.write('OPENAI_API_KEY=sk-secret\n');
        process.stderr.write('api_key=query-secret\n');
        process.stderr.write('Cookie: session=cookie-secret\n');
        process.exit(8);
        """#)
        defer { script.remove() }
        let connection = JSONRPCConnection(transport: ProcessTransport(executableURL: script.url))
        try await connection.start()

        do {
            _ = try await connection.request(method: "account/rateLimits/read", params: nil)
            XCTFail("Expected the process exit to fail the pending request")
        } catch let error as CodexClientError {
            guard case let .serverExited(code, stderr) = error else {
                return XCTFail("Unexpected client error: \(error)")
            }
            XCTAssertEqual(code, 8)
            XCTAssertLessThanOrEqual(stderr.utf8.count, 4096)
            for secret in ["basic-secret", "bearer-secret", "sk-secret", "query-secret", "cookie-secret"] {
                XCTAssertFalse(stderr.contains(secret), "Leaked \(secret)")
            }
            XCTAssertTrue(stderr.contains("[REDACTED]"))
        }
    }

    func testOversizedCredentialLineDoesNotLeakTailAcrossPipeChunks() async throws {
        let script = try TemporaryNodeScript(source: #"""
        process.stderr.write('OPENAI_API_KEY=' + 'boundary-secret'.repeat(400));
        setTimeout(() => {
          process.stderr.write('boundary-secret'.repeat(400) + '\n');
          process.exit(9);
        }, 20);
        """#)
        defer { script.remove() }
        let connection = JSONRPCConnection(transport: ProcessTransport(executableURL: script.url))
        try await connection.start()

        do {
            _ = try await connection.request(method: "account/rateLimits/read", params: nil)
            XCTFail("Expected the process exit to fail the pending request")
        } catch let error as CodexClientError {
            guard case let .serverExited(code, stderr) = error else {
                return XCTFail("Unexpected client error: \(error)")
            }
            XCTAssertEqual(code, 9)
            XCTAssertLessThanOrEqual(stderr.utf8.count, 4096)
            XCTAssertFalse(stderr.contains("boundary-secret"))
            XCTAssertTrue(stderr.contains("[REDACTED OVERSIZED STDERR LINE]"))
        }
    }

    func testGenericCredentialKeysAreRedactedWithoutMaskingNaturalLanguageToken() async throws {
        let script = try TemporaryNodeScript(source: #"""
        process.stderr.write('The tokenizer reports a token count of 42.\n');
        process.stderr.write('TOKEN=token-secret\n');
        process.stderr.write('auth_token: auth-secret\n');
        process.stderr.write('session_token="session-token-secret"\n');
        process.stderr.write('{"secret":"json-secret","password":"password-secret","session":"session-secret"}\n');
        process.stderr.write('X-Session: header-session-secret\n');
        process.stderr.write('AUTH_TO');
        setTimeout(() => {
          process.stderr.write('KEN=cross-chunk-secret\n');
          process.exit(10);
        }, 20);
        """#)
        defer { script.remove() }
        let connection = JSONRPCConnection(transport: ProcessTransport(executableURL: script.url))
        try await connection.start()

        do {
            _ = try await connection.request(method: "account/rateLimits/read", params: nil)
            XCTFail("Expected the process exit to fail the pending request")
        } catch let error as CodexClientError {
            guard case let .serverExited(code, stderr) = error else {
                return XCTFail("Unexpected client error: \(error)")
            }
            XCTAssertEqual(code, 10)
            XCTAssertTrue(stderr.contains("The tokenizer reports a token count of 42."))
            for secret in [
                "token-secret", "auth-secret", "session-token-secret", "json-secret",
                "password-secret", "session-secret", "header-session-secret", "cross-chunk-secret"
            ] {
                XCTAssertFalse(stderr.contains(secret), "Leaked \(secret)")
            }
            XCTAssertLessThanOrEqual(stderr.utf8.count, 4096)
        }
    }

    func testStopTerminatesLongRunningProcess() async throws {
        let script = try TemporaryNodeScript(source: #"""
        process.on('SIGTERM', () => process.exit(0));
        process.stdout.write('{"ready":true}\n');
        setInterval(() => {}, 1000);
        """#)
        defer { script.remove() }
        let transport = ProcessTransport(executableURL: script.url)
        let recorder = SynchronousProcessEventRecorder()
        try await transport.start(
            onLine: { recorder.appendLine(String(decoding: $0, as: UTF8.self)) },
            onTermination: { recorder.appendTermination($0) }
        )
        try await waitUntil { recorder.events.contains(.line(#"{"ready":true}"#)) }

        await transport.stop()
        try await waitUntil { recorder.hasTerminated }

        XCTAssertEqual(recorder.events.last, .termination(0))
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
    private var rateLimitReadContinuations: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [(method: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completionWaiters: [(method: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completedMethods: [String] = []
    private var activeRateLimitReads = 0
    private(set) var maximumConcurrentRateLimitReads = 0
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
        if method == "account/rateLimits/read" {
            activeRateLimitReads += 1
            maximumConcurrentRateLimitReads = max(maximumConcurrentRateLimitReads, activeRateLimitReads)
            if suspendRateLimitRead {
                await withCheckedContinuation { continuation in
                    rateLimitReadContinuations.append(continuation)
                }
            }
            activeRateLimitReads -= 1
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

    func completedRequestCount(for method: String) -> Int {
        completedMethods.count(where: { $0 == method })
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
        guard !rateLimitReadContinuations.isEmpty else { return }
        rateLimitReadContinuations.removeFirst().resume()
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

private enum SynchronousProcessEvent: Equatable {
    case line(String)
    case termination(Int32)
}

private final class SynchronousProcessEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [SynchronousProcessEvent] = []

    var events: [SynchronousProcessEvent] { lock.withLock { storedEvents } }
    var hasTerminated: Bool {
        lock.withLock { storedEvents.contains { if case .termination = $0 { true } else { false } } }
    }

    func appendLine(_ line: String) {
        lock.withLock { storedEvents.append(.line(line)) }
    }

    func appendTermination(_ code: Int32) {
        lock.withLock { storedEvents.append(.termination(code)) }
    }
}

private final class BoundedTerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedLine: String
    private let clock = ContinuousClock()
    private var lineInstant: ContinuousClock.Instant?
    private var terminationInstant: ContinuousClock.Instant?
    private var terminationExitCode: Int32?

    init(expectedLine: String) {
        self.expectedLine = expectedLine
    }

    var hasTerminated: Bool { lock.withLock { terminationInstant != nil } }
    var hasExpectedLine: Bool { lock.withLock { lineInstant != nil } }
    var exitCode: Int32? { lock.withLock { terminationExitCode } }
    var expectedLinePrecededTermination: Bool {
        lock.withLock {
            guard let lineInstant, let terminationInstant else { return false }
            return lineInstant < terminationInstant
        }
    }
    var lineToTerminationDuration: Duration? {
        lock.withLock {
            guard let lineInstant, let terminationInstant else { return nil }
            return lineInstant.duration(to: terminationInstant)
        }
    }

    func appendLine(_ line: String) {
        guard line == expectedLine else { return }
        lock.withLock {
            if lineInstant == nil { lineInstant = clock.now }
        }
    }

    func appendTermination(_ code: Int32) {
        lock.withLock {
            if terminationInstant == nil {
                terminationInstant = clock.now
                terminationExitCode = code
            }
        }
    }
}

private final class ProtocolViolationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLineCount = 0
    private var storedExitCode: Int32?

    var lineCount: Int { lock.withLock { storedLineCount } }
    var exitCode: Int32? { lock.withLock { storedExitCode } }
    var hasTerminated: Bool { lock.withLock { storedExitCode != nil } }

    func recordLine() {
        lock.withLock { storedLineCount += 1 }
    }

    func recordTermination(_ code: Int32) {
        lock.withLock { storedExitCode = code }
    }
}

private final class DescendantProcessCleanup: @unchecked Sendable {
    private let pidFile: URL
    private let targetsProcessGroup: Bool

    init(pidFile: URL, targetsProcessGroup: Bool = false) {
        self.pidFile = pidFile
        self.targetsProcessGroup = targetsProcessGroup
    }

    var isRunning: Bool {
        guard let pid else { return false }
        return Darwin.kill(signalTarget(for: pid), 0) == 0 || errno == EPERM
    }

    func terminateAndWait() {
        guard let pid, pid > 1 else { return }
        let target = signalTarget(for: pid)
        if Darwin.kill(target, 0) == 0 || errno == EPERM {
            _ = Darwin.kill(target, SIGTERM)
            waitForExit(pid: pid, timeout: 0.25)
        }
        if Darwin.kill(target, 0) == 0 || errno == EPERM {
            _ = Darwin.kill(target, SIGKILL)
            waitForExit(pid: pid, timeout: 0.25)
        }
    }

    private var pid: Int32? {
        processID(from: pidFile)
    }

    private func waitForExit(pid: Int32, timeout: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let target = signalTarget(for: pid)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Darwin.kill(target, 0) != 0, errno == ESRCH { return }
            usleep(5_000)
        }
    }

    private func signalTarget(for pid: Int32) -> Int32 {
        targetsProcessGroup ? -pid : pid
    }
}

private func processID(from file: URL) -> Int32? {
    guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
    return Int32(String(decoding: data, as: UTF8.self))
}

private func removeIfPresent(_ file: URL) {
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    try? FileManager.default.removeItem(at: file)
}

private enum TestWaitError: Error {
    case timedOut
}

private func waitForRequests(
    on rpc: RecordingRPCConnection,
    method: String,
    count: Int
) async throws {
    try await waitUntil { await rpc.requestCount(for: method) >= count }
}

private func waitForCompletedRequests(
    on rpc: RecordingRPCConnection,
    method: String,
    count: Int
) async throws {
    try await waitUntil { await rpc.completedRequestCount(for: method) >= count }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw TestWaitError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
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
