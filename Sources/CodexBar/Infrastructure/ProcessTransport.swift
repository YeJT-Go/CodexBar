import Foundation
import Darwin

final class ProcessTransport: RPCTransport, @unchecked Sendable {
    private let executableURL: URL
    private let environment: [String: String]
    private let state: ProcessTransportState

    init(
        executableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumStdoutFrameBytes: Int = JSONLineFramer.defaultMaximumFrameBytes
    ) {
        self.executableURL = executableURL
        self.environment = Self.environmentWithCommandSearchPaths(environment)
        state = ProcessTransportState(maximumStdoutFrameBytes: maximumStdoutFrameBytes)
    }

    func start(
        onLine: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) async throws {
        try state.start(
            executableURL: executableURL,
            environment: environment,
            onLine: onLine,
            onTermination: onTermination
        )
    }

    func write(_ data: Data) async throws {
        try state.write(data)
    }

    func stop() async {
        state.stop()
    }

    func terminationError(for code: Int32) async -> CodexClientError? {
        state.terminationError(for: code)
    }

    private static func environmentWithCommandSearchPaths(
        _ environment: [String: String]
    ) -> [String: String] {
        var result = environment
        let inherited = environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        let directories = (["/opt/homebrew/bin", "/usr/local/bin"] + inherited)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        result["PATH"] = directories.joined(separator: ":")
        return result
    }
}

private final class ProcessTransportState: @unchecked Sendable {
    private static let maximumReportedStderrBytes = 4 * 1024
    private static let maximumPendingStderrLineBytes = 4 * 1024
    private static let terminationDrainDeadline: TimeInterval = 0.05
    private static let maximumBytesPerReadPass = 64 * 1024
    private static let readLoopPollTimeoutMilliseconds: Int32 = 10

    private let lock = NSLock()
    private let readCallbackCondition = NSCondition()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var stdoutFramer: JSONLineFramer
    private var stderrBuffer = Data()
    private var stderrLineBuffer = Data()
    private var isDiscardingOversizedStderrLine = false
    private var stdoutProtocolViolationDiagnostic: String?
    private var lastTerminationError: CodexClientError?
    private var readCallbacksInProgress = 0
    private var isTerminating = false

    init(maximumStdoutFrameBytes: Int) {
        stdoutFramer = JSONLineFramer(maximumFrameBytes: maximumStdoutFrameBytes)
    }

    func start(
        executableURL: URL,
        environment: [String: String],
        onLine: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws {
        try lock.withLock {
            if process?.isRunning == true { return }

            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["app-server", "--stdio"]
            process.environment = environment
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            stdoutFramer.reset()
            stderrBuffer.removeAll(keepingCapacity: true)
            stderrLineBuffer.removeAll(keepingCapacity: true)
            isDiscardingOversizedStderrLine = false
            stdoutProtocolViolationDiagnostic = nil
            lastTerminationError = nil
            resetReadCallbackCoordination()
            self.process = process
            inputHandle = inputPipe.fileHandleForWriting
            outputHandle = outputPipe.fileHandleForReading
            errorHandle = errorPipe.fileHandleForReading
            makeNonBlocking(outputPipe.fileHandleForReading.fileDescriptor)
            makeNonBlocking(errorPipe.fileHandleForReading.fileDescriptor)

            process.terminationHandler = { [weak self] process in
                self?.didTerminate(
                    code: process.terminationStatus,
                    onLine: onLine,
                    onTermination: onTermination
                )
            }

            do {
                try process.run()
                startReadLoop(fileDescriptor: outputPipe.fileHandleForReading.fileDescriptor) {
                    self.consumeStdout($0, onLine: onLine)
                }
                startReadLoop(
                    fileDescriptor: errorPipe.fileHandleForReading.fileDescriptor,
                    consume: consumeStderr
                )
            } catch {
                self.process = nil
                inputHandle = nil
                outputHandle = nil
                errorHandle = nil
                throw error
            }
        }
    }

    func write(_ data: Data) throws {
        let target: Result<FileHandle, Error> = lock.withLock {
            if let process, process.isRunning, let inputHandle {
                return .success(inputHandle)
            }
            if let lastTerminationError {
                return .failure(lastTerminationError)
            }
            return .failure(JSONRPCError.disconnected)
        }
        try target.get().write(contentsOf: data)
    }

    func stop() {
        let resources = lock.withLock { () -> (Process?, FileHandle?) in
            let resources = (process, inputHandle)
            inputHandle = nil
            return resources
        }
        try? resources.1?.close()
        if resources.0?.isRunning == true {
            resources.0?.terminate()
        }
    }

    func terminationError(for code: Int32) -> CodexClientError? {
        lock.withLock {
            if let lastTerminationError {
                return lastTerminationError
            }
            guard code != 0 else { return nil }
            return .serverExited(code: code, stderr: sanitizedStderr())
        }
    }

    private func consumeStdout(_ data: Data, onLine: @escaping @Sendable (Data) -> Void) {
        var shouldTerminate = false
        let lines: [Data] = lock.withLock {
            let output = stdoutFramer.consume(data)
            if output.didExceedMaximumFrameBytes, stdoutProtocolViolationDiagnostic == nil {
                stdoutProtocolViolationDiagnostic =
                    "Transport error: stdout frame exceeded \(stdoutFramer.maximumFrameBytes)-byte limit"
                shouldTerminate = true
            }
            return output.lines
        }
        lines.forEach(onLine)
        if shouldTerminate {
            let process = lock.withLock { self.process }
            if process?.isRunning == true {
                process?.terminate()
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        lock.withLock {
            stderrLineBuffer.append(data)
            while true {
                if isDiscardingOversizedStderrLine {
                    guard let newline = stderrLineBuffer.firstIndex(of: 0x0A) else {
                        stderrLineBuffer.removeAll(keepingCapacity: true)
                        return
                    }
                    stderrLineBuffer.removeSubrange(...newline)
                    isDiscardingOversizedStderrLine = false
                    continue
                }
                if let newline = stderrLineBuffer.firstIndex(of: 0x0A) {
                    let line = Data(stderrLineBuffer[...newline])
                    stderrLineBuffer.removeSubrange(...newline)
                    appendSanitizedStderrLine(line)
                    continue
                }
                if stderrLineBuffer.count > Self.maximumPendingStderrLineBytes {
                    appendBoundedStderr(Data("[REDACTED OVERSIZED STDERR LINE]\n".utf8))
                    stderrLineBuffer.removeAll(keepingCapacity: true)
                    isDiscardingOversizedStderrLine = true
                }
                return
            }
        }
    }

    private func didTerminate(
        code: Int32,
        onLine: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) {
        markTerminating()
        let handles = lock.withLock { (outputHandle, errorHandle, inputHandle) }
        waitForReadCallbacksToFinish()

        drainAvailableData(
            stdout: handles.0,
            stderr: handles.1,
            deadline: ProcessInfo.processInfo.systemUptime + Self.terminationDrainDeadline,
            onLine: onLine
        )

        lock.withLock {
            if !stderrLineBuffer.isEmpty, !isDiscardingOversizedStderrLine {
                appendSanitizedStderrLine(stderrLineBuffer)
            }
            stderrLineBuffer.removeAll(keepingCapacity: true)
            isDiscardingOversizedStderrLine = false
            if let stdoutProtocolViolationDiagnostic {
                lastTerminationError = .serverExited(
                    code: code,
                    stderr: stdoutProtocolViolationDiagnostic
                )
            } else if code != 0 {
                lastTerminationError = .serverExited(code: code, stderr: sanitizedStderr())
            }
            inputHandle = nil
            outputHandle = nil
            errorHandle = nil
            process = nil
        }
        try? handles.0?.close()
        try? handles.1?.close()
        try? handles.2?.close()
        onTermination(code)
    }

    private func sanitizedStderr() -> String {
        String(decoding: stderrBuffer, as: UTF8.self)
    }

    private func appendSanitizedStderrLine(_ data: Data) {
        var line = String(decoding: data, as: UTF8.self)
        let lowercase = line.lowercased()
        if lowercase.contains("\"account\"") || lowercase.contains("\"ratelimits\"") {
            line = "[REDACTED ACCOUNT DATA]\n"
        } else {
            let patterns = [
                (#"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[^\s]+"#, "$1[REDACTED]"),
                (#"(?i)((?:[\"']?)(?:openai_api_key|api[_-]?key|access[_-]?token|id[_-]?token|refresh[_-]?token|authorization)(?:[\"']?)\s*[:=]\s*)(?:[\"'][^\"']*[\"']|[^\s,;]+)"#, "$1[REDACTED]"),
                (#"(?i)((?:[\"']?)(?:(?:[a-z0-9]+[_-])*(?:token|secret|password|session))(?:[\"']?)\s*[:=]\s*)(?:[\"'][^\"']*[\"']|[^\s,;}]+)"#, "$1[REDACTED]"),
                (#"(?i)((?:set-)?cookie\s*:\s*)[^\r\n]+"#, "$1[REDACTED]")
            ]
            for (pattern, replacement) in patterns {
                line = line.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: .regularExpression
                )
            }
        }
        appendBoundedStderr(Data(line.utf8))
    }

    private func appendBoundedStderr(_ data: Data) {
        stderrBuffer.append(data)
        guard stderrBuffer.count > Self.maximumReportedStderrBytes else { return }
        var suffix = Data(stderrBuffer.suffix(Self.maximumReportedStderrBytes))
        while !suffix.isEmpty, String(data: suffix, encoding: .utf8) == nil {
            suffix.removeFirst()
        }
        stderrBuffer = suffix
    }

    private func drainAvailableData(
        stdout: FileHandle?,
        stderr: FileHandle?,
        deadline: TimeInterval,
        onLine: @escaping @Sendable (Data) -> Void
    ) {
        var sources: [DrainSource] = []
        if let stdout {
            sources.append(.init(fileDescriptor: stdout.fileDescriptor) { [weak self] data in
                self?.consumeStdout(data, onLine: onLine)
            })
        }
        if let stderr {
            sources.append(.init(fileDescriptor: stderr.fileDescriptor) { [weak self] data in
                self?.consumeStderr(data)
            })
        }
        for source in sources {
            makeNonBlocking(source.fileDescriptor)
        }

        while sources.contains(where: \.isOpen) {
            var madeProgress = false
            for index in sources.indices where sources[index].isOpen {
                let result = readAvailableData(
                    from: sources[index].fileDescriptor,
                    consume: sources[index].consume
                )
                if result.bytesRead > 0 {
                    madeProgress = true
                }
                if result.reachedEOF {
                    sources[index].isOpen = false
                }
            }

            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, sources.contains(where: \.isOpen) else { break }
            if madeProgress { continue }

            var descriptors = sources.filter(\.isOpen).map {
                pollfd(
                    fd: $0.fileDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
            }
            let timeoutMilliseconds = Int32(max(1, ceil(remaining * 1_000)))
            guard poll(&descriptors, nfds_t(descriptors.count), timeoutMilliseconds) > 0 else {
                break
            }
        }
    }

    private func makeNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private func readAvailableData(
        from fileDescriptor: Int32,
        consume: (Data) -> Void
    ) -> NonBlockingReadResult {
        var totalBytesRead = 0
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while totalBytesRead < Self.maximumBytesPerReadPass {
            let remainingBudget = Self.maximumBytesPerReadPass - totalBytesRead
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, min(bytes.count, remainingBudget))
            }
            if byteCount > 0 {
                totalBytesRead += byteCount
                consume(Data(buffer.prefix(byteCount)))
            } else if byteCount == 0 {
                return .init(bytesRead: totalBytesRead, reachedEOF: true)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return .init(bytesRead: totalBytesRead, reachedEOF: false)
            } else {
                return .init(bytesRead: totalBytesRead, reachedEOF: true)
            }
        }
        return .init(bytesRead: totalBytesRead, reachedEOF: false)
    }

    private func startReadLoop(
        fileDescriptor: Int32,
        consume: @escaping @Sendable (Data) -> Void
    ) {
        guard beginReadCallback() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer { self.endReadCallback() }
            self.runReadLoop(fileDescriptor: fileDescriptor, consume: consume)
        }
    }

    private func runReadLoop(fileDescriptor: Int32, consume: (Data) -> Void) {
        while shouldContinueReading {
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let result = poll(&descriptor, 1, Self.readLoopPollTimeoutMilliseconds)
            if result < 0 {
                if errno == EINTR { continue }
                return
            }
            if result == 0 { continue }
            if readAvailableData(from: fileDescriptor, consume: consume).reachedEOF {
                return
            }
        }
    }

    private var shouldContinueReading: Bool {
        readCallbackCondition.lock()
        defer { readCallbackCondition.unlock() }
        return !isTerminating
    }

    private func resetReadCallbackCoordination() {
        readCallbackCondition.lock()
        isTerminating = false
        readCallbacksInProgress = 0
        readCallbackCondition.unlock()
    }

    private func beginReadCallback() -> Bool {
        readCallbackCondition.lock()
        defer { readCallbackCondition.unlock() }
        guard !isTerminating else { return false }
        readCallbacksInProgress += 1
        return true
    }

    private func endReadCallback() {
        readCallbackCondition.lock()
        readCallbacksInProgress -= 1
        if readCallbacksInProgress == 0 {
            readCallbackCondition.broadcast()
        }
        readCallbackCondition.unlock()
    }

    private func markTerminating() {
        readCallbackCondition.lock()
        isTerminating = true
        readCallbackCondition.unlock()
    }

    private func waitForReadCallbacksToFinish() {
        readCallbackCondition.lock()
        while readCallbacksInProgress > 0 {
            readCallbackCondition.wait()
        }
        readCallbackCondition.unlock()
    }
}

private struct DrainSource {
    let fileDescriptor: Int32
    let consume: (Data) -> Void
    var isOpen = true
}

private struct NonBlockingReadResult {
    let bytesRead: Int
    let reachedEOF: Bool
}

struct JSONLineFramer {
    static let defaultMaximumFrameBytes = 1024 * 1024

    let maximumFrameBytes: Int
    private var pending = Data()
    private(set) var isDiscardingOversizedFrame = false

    var pendingByteCount: Int { pending.count }

    init(maximumFrameBytes: Int = defaultMaximumFrameBytes) {
        precondition(maximumFrameBytes > 0)
        self.maximumFrameBytes = maximumFrameBytes
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
        isDiscardingOversizedFrame = false
    }

    mutating func consume(_ data: Data) -> JSONLineFramerOutput {
        pending.append(data)
        var lines: [Data] = []
        var didExceedMaximumFrameBytes = false
        while true {
            if isDiscardingOversizedFrame {
                guard let newline = pending.firstIndex(of: 0x0A) else {
                    pending.removeAll(keepingCapacity: false)
                    break
                }
                pending.removeSubrange(...newline)
                isDiscardingOversizedFrame = false
                continue
            }
            if let newline = pending.firstIndex(of: 0x0A) {
                if pending[..<newline].count > maximumFrameBytes {
                    didExceedMaximumFrameBytes = true
                    pending.removeSubrange(...newline)
                    continue
                }
                var line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty { lines.append(line) }
                continue
            }
            if pending.count > maximumFrameBytes {
                didExceedMaximumFrameBytes = true
                pending.removeAll(keepingCapacity: false)
                isDiscardingOversizedFrame = true
            }
            break
        }
        return .init(
            lines: lines,
            didExceedMaximumFrameBytes: didExceedMaximumFrameBytes
        )
    }
}

struct JSONLineFramerOutput {
    let lines: [Data]
    let didExceedMaximumFrameBytes: Bool
}
