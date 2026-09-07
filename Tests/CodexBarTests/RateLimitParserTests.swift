import XCTest
@testable import CodexBar

final class RateLimitParserTests: XCTestCase {
    func testParsesFiveHourAndWeeklyRemainingPercent() throws {
        let response = RateLimitsResponse(rateLimits: .init(
            limitId: "codex",
            primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: 1_788_800_000),
            secondary: .init(usedPercent: 75, windowDurationMins: 10_080, resetsAt: 1_789_000_000)
        ), rateLimitsByLimitId: nil)
        let result = try RateLimitParser().parse(response, now: Date(timeIntervalSince1970: 1_788_700_000))
        XCTAssertEqual(result.fiveHour.remainingPercent, 80)
        XCTAssertEqual(result.weekly.remainingPercent, 25)
    }

    func testClampsAndColorsRemainingPercent() {
        XCTAssertEqual(UsageLevel.level(forRemaining: 50), .healthy)
        XCTAssertEqual(UsageLevel.level(forRemaining: 49), .warning)
        XCTAssertEqual(UsageLevel.level(forRemaining: 19), .critical)
        XCTAssertEqual(UsageWindow.remaining(fromUsed: 130), 0)
    }
}
