import Foundation

final class ProcessTransport: RPCTransport, @unchecked Sendable {
    private let executableURL: URL
    private let environment: [String: String]
    private let state = ProcessTransportState()

    init(
        executableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        self.environment = Self.environmentWithCommandSearchPaths(environment)
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

    private let lock = NSLock()
    private let readCallbackCondition = NSCondition()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stderrLineBuffer = Data()
    private var isDiscardingOversizedStderrLine = false
    private var lastTerminationError: CodexClientError?
    private var readCallbacksInProgress = 0
    private var isTerminating = false

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

            stdoutBuffer.removeAll(keepingCapacity: true)
            stderrBuffer.removeAll(keepingCapacity: true)
            stderrLineBuffer.removeAll(keepingCapacity: true)
            isDiscardingOversizedStderrLine = false
            lastTerminationError = nil
            resetReadCallbackCoordination()
            self.process = process
            inputHandle = inputPipe.fileHandleForWriting
            outputHandle = outputPipe.fileHandleForReading
            errorHandle = errorPipe.fileHandleForReading

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self, self.beginReadCallback() else { return }
                defer { self.endReadCallback() }
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self.consumeStdout(data, onLine: onLine)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self, self.beginReadCallback() else { return }
                defer { self.endReadCallback() }
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self.consumeStderr(data)
            }
            process.terminationHandler = { [weak self] process in
                self?.didTerminate(
                    code: process.terminationStatus,
                    onLine: onLine,
                    onTermination: onTermination
                )
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
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
            guard code != 0 else { return nil }
            if case let .serverExited(storedCode, _)? = lastTerminationError, storedCode == code {
                return lastTerminationError
            }
            return .serverExited(code: code, stderr: sanitizedStderr())
        }
    }

    private func consumeStdout(_ data: Data, onLine: @escaping @Sendable (Data) -> Void) {
        let lines: [Data] = lock.withLock {
            stdoutBuffer.append(data)
            var completed: [Data] = []
            while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                var line = Data(stdoutBuffer[..<newline])
                stdoutBuffer.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty { completed.append(line) }
            }
            return completed
        }
        lines.forEach(onLine)
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
        handles.0?.readabilityHandler = nil
        handles.1?.readabilityHandler = nil
        waitForReadCallbacksToFinish()

        let remainingStdout = readToEnd(handles.0)
        let remainingStderr = readToEnd(handles.1)
        if !remainingStdout.isEmpty {
            consumeStdout(remainingStdout, onLine: onLine)
        }
        if !remainingStderr.isEmpty {
            consumeStderr(remainingStderr)
        }

        lock.withLock {
            if !stderrLineBuffer.isEmpty, !isDiscardingOversizedStderrLine {
                appendSanitizedStderrLine(stderrLineBuffer)
            }
            stderrLineBuffer.removeAll(keepingCapacity: true)
            isDiscardingOversizedStderrLine = false
            if code != 0 {
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

    private func readToEnd(_ handle: FileHandle?) -> Data {
        guard let handle else { return Data() }
        return (try? handle.readToEnd()) ?? Data()
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
