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

    func testMissingCardUsesFixedWidthAndHasIntrinsicHeight() {
        assertCardSize(.make(from: .loading))
    }

    func testStaleCardUsesFixedWidthAndHasIntrinsicHeight() {
        let snapshot = UsageSnapshot(
            fiveHour: .init(remainingPercent: 18, resetsAt: nil),
            weekly: .init(remainingPercent: 72, resetsAt: nil),
            fetchedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )

        assertCardSize(.make(from: .stale(snapshot, "连接已断开")))
    }

    private func assertCardSize(
        _ presentation: FloatingQuotaCardPresentation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hostingView = NSHostingView(
            rootView: FloatingQuotaCardContent(presentation: presentation)
        )

        XCTAssertEqual(hostingView.fittingSize.width, 148, accuracy: 0.01, file: file, line: line)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0, file: file, line: line)
    }
}
