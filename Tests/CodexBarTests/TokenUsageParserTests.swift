import XCTest
@testable import CodexBar

final class TokenUsageParserTests: XCTestCase {
    func testParsesLocalTodayBucket() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let response = AccountTokenUsageResponse(
            summary: .init(lifetimeTokens: 184_260, peakDailyTokens: 184_260,
                           currentStreakDays: 1, longestStreakDays: 1,
                           longestRunningTurnSec: 60),
            dailyUsageBuckets: [
                .init(startDate: "2026-09-11", tokens: 184_260)
            ]
        )

        let usage = try TokenUsageParser().parse(
            response,
            now: Date(timeIntervalSince1970: 1_789_117_200),
            calendar: calendar
        )

        XCTAssertEqual(usage.tokens, 184_260)
        XCTAssertEqual(usage.dateKey, "2026-09-11")
    }

    func testMissingTodayBucketMeansZeroWhenBucketsArePresent() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = Date(timeIntervalSince1970: 1_789_117_200)
        let response = AccountTokenUsageResponse(
            summary: .init(lifetimeTokens: nil, peakDailyTokens: nil,
                           currentStreakDays: nil, longestStreakDays: nil,
                           longestRunningTurnSec: nil),
            dailyUsageBuckets: []
        )

        XCTAssertEqual(
            try TokenUsageParser().parse(response, now: now, calendar: calendar).tokens,
            0
        )
    }

    func testThrowsWhenDailyBucketsAreMissing() {
        let response = AccountTokenUsageResponse(
            summary: .init(lifetimeTokens: nil, peakDailyTokens: nil,
                           currentStreakDays: nil, longestStreakDays: nil,
                           longestRunningTurnSec: nil),
            dailyUsageBuckets: nil
        )

        XCTAssertThrowsError(try TokenUsageParser().parse(response)) { error in
            XCTAssertEqual(error as? TokenUsageParseError, .missingDailyBuckets)
        }
    }

    func testThrowsWhenTodayBucketHasNegativeTokenCount() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let response = AccountTokenUsageResponse(
            summary: .init(lifetimeTokens: nil, peakDailyTokens: nil,
                           currentStreakDays: nil, longestStreakDays: nil,
                           longestRunningTurnSec: nil),
            dailyUsageBuckets: [.init(startDate: "2026-09-11", tokens: -1)]
        )

        XCTAssertThrowsError(
            try TokenUsageParser().parse(
                response,
                now: Date(timeIntervalSince1970: 1_789_117_200),
                calendar: calendar
            )
        ) { error in
            XCTAssertEqual(error as? TokenUsageParseError, .invalidTokenCount)
        }
    }
}
