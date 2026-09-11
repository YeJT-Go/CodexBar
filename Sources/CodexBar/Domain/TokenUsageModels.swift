import Foundation

struct AccountTokenUsageDailyBucketDTO: Codable, Equatable, Sendable {
    let startDate: String
    let tokens: Int64
}

struct AccountTokenUsageSummaryDTO: Codable, Equatable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let longestRunningTurnSec: Int64?
}

struct AccountTokenUsageResponse: Codable, Equatable, Sendable {
    let summary: AccountTokenUsageSummaryDTO
    let dailyUsageBuckets: [AccountTokenUsageDailyBucketDTO]?
}

struct DailyTokenUsage: Equatable, Sendable {
    let tokens: Int64
    let dateKey: String
    let fetchedAt: Date
}

enum TokenUsageState: Equatable, Sendable {
    case loading
    case current(DailyTokenUsage)
    case stale(DailyTokenUsage, String)
    case unavailable(String)
}
