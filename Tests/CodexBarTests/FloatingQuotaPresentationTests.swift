import XCTest
@testable import CodexBar

final class FloatingQuotaPresentationTests: XCTestCase {
    func testFloatingQuotaLevelsUseIndependentBoundaries() {
        XCTAssertEqual(FloatingQuotaLevel.level(forRemaining: 0), .critical)
        XCTAssertEqual(FloatingQuotaLevel.level(forRemaining: 19), .critical)
        XCTAssertEqual(FloatingQuotaLevel.level(forRemaining: 20), .warning)
        XCTAssertEqual(FloatingQuotaLevel.level(forRemaining: 50), .warning)
        XCTAssertEqual(FloatingQuotaLevel.level(forRemaining: 51), .healthy)
        XCTAssertEqual(FloatingQuotaLevel.level(forRemaining: 100), .healthy)
    }

    func testCurrentPresentationBuildsBothQuotaRings() {
        let state = UsageState.current(.init(
            fiveHour: .init(remainingPercent: 19, resetsAt: nil),
            weekly: .init(remainingPercent: 51, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        ))

        let card = FloatingQuotaCardPresentation.make(from: state)

        XCTAssertEqual(card.statusText, nil)
        XCTAssertEqual(card.fiveHour?.title, "5 小时")
        XCTAssertEqual(card.fiveHour?.remainingText, "19%")
        XCTAssertEqual(card.fiveHour?.progress, 0.19)
        XCTAssertEqual(card.fiveHour?.level, .critical)
        XCTAssertEqual(card.fiveHour?.accessibilityLabel, "5 小时剩余额度")
        XCTAssertEqual(card.fiveHour?.accessibilityValue, "19%")
        XCTAssertEqual(card.weekly.title, "每周")
        XCTAssertEqual(card.weekly.remainingText, "51%")
        XCTAssertEqual(card.weekly.progress, 0.51)
        XCTAssertEqual(card.weekly.level, .healthy)
        XCTAssertEqual(card.weekly.accessibilityLabel, "每周剩余额度")
        XCTAssertEqual(card.weekly.accessibilityValue, "51%")
    }

    func testProgressClampsPercentToZeroThroughOne() {
        let card = FloatingQuotaCardPresentation.make(from: .current(.init(
            fiveHour: .init(remainingPercent: -20, resetsAt: nil),
            weekly: .init(remainingPercent: 120, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )))

        XCTAssertEqual(card.fiveHour?.progress, 0)
        XCTAssertEqual(card.fiveHour?.remainingText, "0%")
        XCTAssertEqual(card.fiveHour?.accessibilityValue, "0%")
        XCTAssertEqual(card.fiveHour?.level, .critical)
        XCTAssertEqual(card.weekly.progress, 1)
        XCTAssertEqual(card.weekly.remainingText, "100%")
        XCTAssertEqual(card.weekly.accessibilityValue, "100%")
        XCTAssertEqual(card.weekly.level, .healthy)
    }

    func testLoadingPresentationHasNoInventedProgress() {
        let card = FloatingQuotaCardPresentation.make(from: .loading)

        XCTAssertEqual(card.statusText, "正在加载…")
        XCTAssertNil(card.fiveHour)
        XCTAssertEqual(card.weekly.remainingText, "—")
        XCTAssertNil(card.weekly.progress)
        XCTAssertEqual(card.weekly.level, .stale)
        XCTAssertEqual(card.weekly.accessibilityValue, "—")
    }

    func testUnavailablePresentationUsesMessageAndHasNoInventedProgress() {
        let card = FloatingQuotaCardPresentation.make(from: .unavailable("响应缺少字段"))

        XCTAssertEqual(card.statusText, "响应缺少字段")
        XCTAssertNil(card.fiveHour)
        XCTAssertEqual(card.weekly.remainingText, "—")
        XCTAssertNil(card.weekly.progress)
        XCTAssertEqual(card.weekly.level, .stale)
    }

    func testUnavailablePresentationUsesFallbackForEmptyMessage() {
        let card = FloatingQuotaCardPresentation.make(from: .unavailable(""))

        XCTAssertEqual(card.statusText, "额度暂不可用")
    }

    func testStalePresentationKeepsSnapshotValuesAndReportsExpiration() {
        let snapshot = UsageSnapshot(
            fiveHour: .init(remainingPercent: 20, resetsAt: nil),
            weekly: .init(remainingPercent: 100, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )

        let card = FloatingQuotaCardPresentation.make(from: .stale(snapshot, "连接已断开"))

        XCTAssertEqual(card.statusText, "数据已过期")
        XCTAssertEqual(card.fiveHour?.remainingText, "20%")
        XCTAssertEqual(card.fiveHour?.progress, 0.2)
        XCTAssertEqual(card.fiveHour?.level, .warning)
        XCTAssertEqual(card.weekly.remainingText, "100%")
        XCTAssertEqual(card.weekly.level, .healthy)
    }

    func testCurrentPresentationAllowsWeeklyOnlyWhenFiveHourIsMissing() {
        let card = FloatingQuotaCardPresentation.make(from: .current(.init(
            fiveHour: nil,
            weekly: .init(remainingPercent: 50, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )))

        XCTAssertNil(card.fiveHour)
        XCTAssertEqual(card.weekly.remainingText, "50%")
        XCTAssertEqual(card.weekly.progress, 0.5)
        XCTAssertEqual(card.weekly.level, .warning)
        XCTAssertNil(card.statusText)
    }
}
