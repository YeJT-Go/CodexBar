import Foundation

enum TokenUsageParseError: Error, Equatable, Sendable {
    case missingDailyBuckets
    case invalidDateKey
    case invalidTokenCount
}

struct TokenUsageParser: Sendable {
    private static let dateKeyCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

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
        guard buckets.allSatisfy({ isValidDateKey($0.startDate) }) else {
            throw TokenUsageParseError.invalidDateKey
        }

        let dateKey = Self.dateKey(for: now, calendar: calendar)
        let tokens = buckets.first(where: { $0.startDate == dateKey })?.tokens ?? 0

        return DailyTokenUsage(tokens: tokens, dateKey: dateKey, fetchedAt: now)
    }

    private func isValidDateKey(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ (48...57).contains(bytes[$0]) }),
              let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.suffix(2)),
              (1...9_999).contains(year) else {
            return false
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Self.dateKeyCalendar.date(from: components) else {
            return false
        }
        return value == Self.dateKey(for: date, calendar: Self.dateKeyCalendar)
    }

    private static func dateKey(for date: Date, calendar: Calendar) -> String {
        String(
            format: "%04d-%02d-%02d",
            calendar.component(.year, from: date),
            calendar.component(.month, from: date),
            calendar.component(.day, from: date)
        )
    }
}
