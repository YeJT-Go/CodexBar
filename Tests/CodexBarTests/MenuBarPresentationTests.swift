import XCTest
@testable import CodexBar

final class MenuBarPresentationTests: XCTestCase {
    func testCurrentPresentationContainsBothWindowsAndSemanticLevels() {
        let snapshot = UsageSnapshot(
            fiveHour: .init(remainingPercent: 80, resetsAt: nil),
            weekly: .init(remainingPercent: 25, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )

        let value = MenuBarPresentation.make(from: .current(snapshot))

        XCTAssertEqual(value.label, "5h 80% · 周 25%")
        XCTAssertEqual(value.fiveHour?.remainingText, "80%")
        XCTAssertEqual(value.weekly.remainingText, "25%")
        XCTAssertEqual(value.fiveHour?.resetText, "未知")
        XCTAssertEqual(value.fiveHourLevel, .healthy)
        XCTAssertEqual(value.weeklyLevel, .warning)
        XCTAssertEqual(value.connectionText, "已连接")
        XCTAssertFalse(value.showsWarning)
    }

    func testThresholdsUseApprovedHealthyWarningAndCriticalBoundaries() {
        let snapshot = UsageSnapshot(
            fiveHour: .init(remainingPercent: 51, resetsAt: nil),
            weekly: .init(remainingPercent: 21, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )

        let value = MenuBarPresentation.make(from: .current(snapshot))

        XCTAssertEqual(value.fiveHourLevel, .healthy)
        XCTAssertEqual(value.weeklyLevel, .warning)

        let boundaries = MenuBarPresentation.make(from: .current(.init(
            fiveHour: .init(remainingPercent: 50, resetsAt: nil),
            weekly: .init(remainingPercent: 20, resetsAt: nil),
            fetchedAt: snapshot.fetchedAt
        )))
        XCTAssertEqual(boundaries.fiveHourLevel, .warning)
        XCTAssertEqual(boundaries.weeklyLevel, .critical)
    }

    func testStalePresentationKeepsValuesButUsesGrayAndWarningText() {
        let snapshot = UsageSnapshot(
            fiveHour: .init(remainingPercent: 46, resetsAt: nil),
            weekly: .init(remainingPercent: 73, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )

        let value = MenuBarPresentation.make(from: .stale(snapshot, "连接已断开"))

        XCTAssertEqual(value.label, "⚠ 5h 46% · 周 73%")
        XCTAssertEqual(value.fiveHourLevel, .stale)
        XCTAssertEqual(value.weeklyLevel, .stale)
        XCTAssertEqual(value.connectionText, "数据已过期")
        XCTAssertEqual(value.warningText, "连接已断开")
        XCTAssertTrue(value.showsWarning)
    }

    func testUnavailablePresentationDoesNotInventZeroUsage() {
        let value = MenuBarPresentation.make(from: .unavailable("Codex CLI 未找到"))

        XCTAssertEqual(value.label, "⚠ 周 --")
        XCTAssertNil(value.fiveHour)
        XCTAssertEqual(value.weekly.remainingText, "--")
        XCTAssertEqual(value.fiveHourLevel, .stale)
        XCTAssertEqual(value.weeklyLevel, .stale)
        XCTAssertEqual(value.connectionText, "不可用")
        XCTAssertEqual(value.warningText, "Codex CLI 未找到")
        XCTAssertTrue(value.showsWarning)
    }

    func testWeeklyOnlyHidesFiveHourAndDrivesAccent() {
        for (remaining, level) in [(100, UsageLevel.healthy), (30, .warning), (10, .critical)] {
            let value = MenuBarPresentation.make(from: .current(.init(
                fiveHour: nil, weekly: .init(remainingPercent: remaining, resetsAt: nil), fetchedAt: Date()
            )))
            XCTAssertEqual(value.label, "周 \(remaining)%")
            XCTAssertNil(value.fiveHour)
            XCTAssertEqual(value.accentLevel, level)
            XCTAssertFalse(value.showsWarning)
        }
    }

    func testFiveHourTakesPriorityOverWeeklyForAccent() {
        let value = MenuBarPresentation.make(from: .current(.init(
            fiveHour: .init(remainingPercent: 100, resetsAt: nil),
            weekly: .init(remainingPercent: 10, resetsAt: nil), fetchedAt: Date()
        )))
        XCTAssertEqual(value.label, "5h 100% · 周 10%")
        XCTAssertEqual(value.accentLevel, .healthy)
    }
}
