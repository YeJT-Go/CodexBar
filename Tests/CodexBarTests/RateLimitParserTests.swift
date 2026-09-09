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
        XCTAssertEqual(result.fiveHour?.remainingPercent, 80)
        XCTAssertEqual(result.weekly.remainingPercent, 25)
    }

    func testClampsAndColorsRemainingPercent() {
        XCTAssertEqual(UsageLevel.level(forRemaining: 50), .healthy)
        XCTAssertEqual(UsageLevel.level(forRemaining: 49), .warning)
        XCTAssertEqual(UsageLevel.level(forRemaining: 19), .critical)
        XCTAssertEqual(UsageWindow.remaining(fromUsed: 130), 0)
        XCTAssertEqual(UsageWindow.remaining(fromUsed: -10), 100)
    }

    func testPrefersCodexLimitFromRateLimitsByLimitId() throws {
        let fallback = RateLimitSnapshotDTO(
            limitId: "other",
            primary: .init(usedPercent: 90, windowDurationMins: 300, resetsAt: nil),
            secondary: .init(usedPercent: 90, windowDurationMins: 10_080, resetsAt: nil)
        )
        let codex = RateLimitSnapshotDTO(
            limitId: "codex",
            primary: .init(usedPercent: 20, windowDurationMins: 300, resetsAt: nil),
            secondary: .init(usedPercent: 75, windowDurationMins: 10_080, resetsAt: nil)
        )
        let response = RateLimitsResponse(
            rateLimits: fallback,
            rateLimitsByLimitId: ["codex": codex]
        )

        let result = try RateLimitParser().parse(response)

        XCTAssertEqual(result.fiveHour?.remainingPercent, 80)
        XCTAssertEqual(result.weekly.remainingPercent, 25)
    }

    func testFallsBackToPrimaryAndSecondaryWhenDurationsAreMissing() throws {
        let response = RateLimitsResponse(
            rateLimits: .init(
                limitId: "codex",
                primary: .init(usedPercent: 30, windowDurationMins: nil, resetsAt: nil),
                secondary: .init(usedPercent: 60, windowDurationMins: nil, resetsAt: nil)
            ),
            rateLimitsByLimitId: nil
        )

        let result = try RateLimitParser().parse(response)

        XCTAssertEqual(result.fiveHour?.remainingPercent, 70)
        XCTAssertEqual(result.weekly.remainingPercent, 40)
    }

    func testThrowsWhenWeeklyWindowCannotBeFound() {
        let response = RateLimitsResponse(
            rateLimits: .init(
                limitId: "codex",
                primary: .init(usedPercent: 30, windowDurationMins: 300, resetsAt: nil),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )

        XCTAssertThrowsError(try RateLimitParser().parse(response)) { error in
            XCTAssertEqual(error as? RateLimitParseError, .missingWindow)
        }
    }

    func testAcceptsWeeklyPrimaryWithoutFiveHourAndDoesNotBorrowSparkWindow() throws {
        let data = Data("""
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": {"usedPercent": 25, "windowDurationMins": 10080},
            "secondary": null
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {"usedPercent": 25, "windowDurationMins": 10080},
              "secondary": null
            },
            "codex_spark": {
              "limitId": "codex_spark",
              "primary": {"usedPercent": 10, "windowDurationMins": 300},
              "secondary": {"usedPercent": 20, "windowDurationMins": 10080}
            }
          }
        }
        """.utf8)
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)

        let result = try RateLimitParser().parse(response)

        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.weekly.remainingPercent, 75)
    }

    func testAcceptsWeeklyOnlyLegacyResponseWithoutBucketMap() throws {
        let response = RateLimitsResponse(
            rateLimits: .init(
                limitId: "codex",
                primary: .init(usedPercent: 0, windowDurationMins: 10_080, resetsAt: nil),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )

        let result = try RateLimitParser().parse(response)

        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.weekly.remainingPercent, 100)
    }
}
