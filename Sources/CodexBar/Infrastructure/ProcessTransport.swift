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
    private static let maximumRawStderrBytes = 4 * 1024
    private static let maximumReportedStderrBytes = 4 * 1024

    private let lock = NSLock()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var lastTerminationError: CodexClientError?

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
            lastTerminationError = nil
            self.process = process
            inputHandle = inputPipe.fileHandleForWriting
            outputHandle = outputPipe.fileHandleForReading
            errorHandle = errorPipe.fileHandleForReading

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.consumeStdout(data, onLine: onLine)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.consumeStderr(data)
            }
            process.terminationHandler = { [weak self] process in
                self?.didTerminate(code: process.terminationStatus, onTermination: onTermination)
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
        let resources = lock.withLock { () -> (Process?, FileHandle?, FileHandle?, FileHandle?) in
            let resources = (process, inputHandle, outputHandle, errorHandle)
            outputHandle?.readabilityHandler = nil
            errorHandle?.readabilityHandler = nil
            inputHandle = nil
            outputHandle = nil
            errorHandle = nil
            return resources
        }
        try? resources.1?.close()
        try? resources.2?.close()
        try? resources.3?.close()
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
            stderrBuffer.append(data)
            if stderrBuffer.count > Self.maximumRawStderrBytes {
                stderrBuffer = Data(stderrBuffer.suffix(Self.maximumRawStderrBytes))
            }
        }
    }

    private func didTerminate(
        code: Int32,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) {
        lock.withLock {
            if code != 0 {
                lastTerminationError = .serverExited(code: code, stderr: sanitizedStderr())
            }
            inputHandle = nil
            outputHandle = nil
            errorHandle = nil
            process = nil
        }
        onTermination(code)
    }

    private func sanitizedStderr() -> String {
        var output = String(decoding: stderrBuffer, as: UTF8.self)
        let patterns = [
            (#"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#, "$1[REDACTED]"),
            (#"(?i)(\"(?:access_?token|id_?token|refresh_?token|email|account)\"\s*:\s*\")[^\"]*(\")"#, "$1[REDACTED]$2")
        ]
        for (pattern, replacement) in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        let encoded = Data(output.utf8)
        guard encoded.count > Self.maximumReportedStderrBytes else { return output }
        return String(decoding: encoded.suffix(Self.maximumReportedStderrBytes), as: UTF8.self)
    }
}
