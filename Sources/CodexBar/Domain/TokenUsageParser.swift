import Foundation

enum TokenUsageParseError: Error, Equatable, Sendable {
    case missingDailyBuckets
    case invalidTokenCount
}

struct TokenUsageParser: Sendable {
    func parse(
        _ response: AccountTokenUsageResponse,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DailyTokenUsage {
        guard let buckets = response.dailyUsageBuckets else {
            throw TokenUsageParseError.missingDailyBuckets
        }
        guard buckets.allSatisfy({ $0.tokens >= 0 }) else {
            throw TokenUsageParseError.invalidTokenCount
        }

        let dateKey = String(
            format: "%04d-%02d-%02d",
            calendar.component(.year, from: now),
            calendar.component(.month, from: now),
            calendar.component(.day, from: now)
        )
        let tokens = buckets.first(where: { $0.startDate == dateKey })?.tokens ?? 0

        return DailyTokenUsage(tokens: tokens, dateKey: dateKey, fetchedAt: now)
    }
}
