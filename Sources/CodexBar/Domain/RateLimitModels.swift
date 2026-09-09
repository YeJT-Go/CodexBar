import Foundation

struct RateLimitWindowDTO: Codable, Equatable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?
}

struct RateLimitSnapshotDTO: Codable, Equatable, Sendable {
    let limitId: String?
    let primary: RateLimitWindowDTO?
    let secondary: RateLimitWindowDTO?
}

struct RateLimitsResponse: Codable, Equatable, Sendable {
    let rateLimits: RateLimitSnapshotDTO
    let rateLimitsByLimitId: [String: RateLimitSnapshotDTO]?
}

struct UsageWindow: Codable, Equatable, Sendable {
    let remainingPercent: Int
    let resetsAt: Date?

    static func remaining(fromUsed used: Int) -> Int {
        min(100, max(0, 100 - used))
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow
    let fetchedAt: Date
}

enum UsageLevel: Equatable, Sendable {
    case healthy
    case warning
    case critical
    case stale

    static func level(forRemaining value: Int) -> Self {
        value >= 50 ? .healthy : value >= 20 ? .warning : .critical
    }
}
