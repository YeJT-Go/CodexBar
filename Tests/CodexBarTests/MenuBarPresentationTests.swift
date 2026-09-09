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
        XCTAssertEqual(value.fiveHour.remainingText, "80%")
        XCTAssertEqual(value.weekly.remainingText, "25%")
        XCTAssertEqual(value.fiveHour.resetText, "未知")
        XCTAssertEqual(value.fiveHourLevel, .healthy)
        XCTAssertEqual(value.weeklyLevel, .warning)
        XCTAssertEqual(value.connectionText, "已连接")
        XCTAssertFalse(value.showsWarning)
    }

    func testThresholdsUseHealthyAt50WarningAt20AndCriticalBelow20() {
        let snapshot = UsageSnapshot(
            fiveHour: .init(remainingPercent: 50, resetsAt: nil),
            weekly: .init(remainingPercent: 20, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )

        let value = MenuBarPresentation.make(from: .current(snapshot))

        XCTAssertEqual(value.fiveHourLevel, .healthy)
        XCTAssertEqual(value.weeklyLevel, .warning)

        let critical = MenuBarPresentation.make(from: .current(.init(
            fiveHour: .init(remainingPercent: 19, resetsAt: nil),
            weekly: .init(remainingPercent: 0, resetsAt: nil),
            fetchedAt: snapshot.fetchedAt
        )))
        XCTAssertEqual(critical.fiveHourLevel, .critical)
        XCTAssertEqual(critical.weeklyLevel, .critical)
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

        XCTAssertEqual(value.label, "⚠ 5h -- · 周 --")
        XCTAssertEqual(value.fiveHour.remainingText, "--")
        XCTAssertEqual(value.weekly.remainingText, "--")
        XCTAssertEqual(value.fiveHourLevel, .stale)
        XCTAssertEqual(value.weeklyLevel, .stale)
        XCTAssertEqual(value.connectionText, "不可用")
        XCTAssertEqual(value.warningText, "Codex CLI 未找到")
        XCTAssertTrue(value.showsWarning)
    }
}
