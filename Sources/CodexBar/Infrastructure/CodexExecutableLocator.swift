import Foundation

enum CodexClientError: Error, Equatable, Sendable {
    case executableNotFound
    case malformedRateLimitsResponse
    case serverExited(code: Int32, stderr: String)
    case stopped
}

struct CodexExecutableLocator: Sendable {
    private let path: String
    private let isExecutable: @Sendable (String) -> Bool

    init(
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.path = path
        self.isExecutable = isExecutable
    }

    func locate() throws -> URL {
        var candidates = ["/opt/homebrew/bin/codex"]
        candidates.append(contentsOf: path.split(separator: ":").compactMap { directory in
            guard directory.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("codex", isDirectory: false)
                .path
        })
        candidates.append("/usr/local/bin/codex")

        var visited = Set<String>()
        for candidate in candidates where visited.insert(candidate).inserted {
            guard candidate.hasPrefix("/"), isExecutable(candidate) else { continue }
            return URL(fileURLWithPath: candidate)
        }
        throw CodexClientError.executableNotFound
    }
}
