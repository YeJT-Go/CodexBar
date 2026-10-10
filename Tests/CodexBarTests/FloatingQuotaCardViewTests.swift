import AppKit
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class FloatingQuotaCardViewTests: XCTestCase {
    func testCurrentCardUsesFixedWidthAndHasIntrinsicHeight() {
        let presentation = FloatingQuotaCardPresentation.make(from: .current(.init(
            fiveHour: .init(remainingPercent: 64, resetsAt: nil),
            weekly: .init(remainingPercent: 28, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )))

        assertCardSize(presentation)
    }

    func testWeeklyOnlyCurrentCardKeepsSpaceForMissingFiveHourRing() {
        let complete = FloatingQuotaCardPresentation.make(from: .current(.init(
            fiveHour: .init(remainingPercent: 64, resetsAt: nil),
            weekly: .init(remainingPercent: 28, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )))
        let weeklyOnly = FloatingQuotaCardPresentation.make(from: .current(.init(
            fiveHour: nil,
            weekly: .init(remainingPercent: 28, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )))

        let completeSize = cardSize(complete)
        let weeklyOnlySize = cardSize(weeklyOnly)

        XCTAssertEqual(weeklyOnlySize.width, 148, accuracy: 0.01)
        XCTAssertGreaterThan(weeklyOnlySize.height, 0)
        XCTAssertEqual(weeklyOnlySize.height, completeSize.height, accuracy: 0.01)
    }

    func testStaleCardUsesFixedWidthAndHasIntrinsicHeight() {
        let snapshot = UsageSnapshot(
            fiveHour: .init(remainingPercent: 18, resetsAt: nil),
            weekly: .init(remainingPercent: 72, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )

        assertCardSize(.make(from: .stale(snapshot, "连接已断开")))
    }

    func testLongUnavailableMessageIsTruncatedToACompactCardHeight() {
        let message = String(repeating: "无法获取额度，请检查连接后重试。", count: 80)

        let size = cardSize(.make(from: .unavailable(message)))

        XCTAssertEqual(size.width, 148, accuracy: 0.01)
        XCTAssertLessThan(size.height, 300)
    }

    private func assertCardSize(
        _ presentation: FloatingQuotaCardPresentation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let size = cardSize(presentation)

        XCTAssertEqual(size.width, 148, accuracy: 0.01, file: file, line: line)
        XCTAssertGreaterThan(size.height, 0, file: file, line: line)
    }

    private func cardSize(_ presentation: FloatingQuotaCardPresentation) -> NSSize {
        NSHostingView(
            rootView: FloatingQuotaCardContent(presentation: presentation)
        ).fittingSize
    }
}
