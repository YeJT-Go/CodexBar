import Foundation
import XCTest
@testable import CodexBar

final class FloatingCardScreenLayoutTests: XCTestCase {
    private let main = FloatingScreen(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 836),
        scale: 2
    )

    func testFindsMainScreenUsingFullFrameIncludingDockArea() {
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: CGPoint(x: 600, y: 20), in: [main])?.id, 1)
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: .zero, in: [main])?.id, 1)
    }

    func testFindsScreenWithNegativeXCoordinates() {
        let left = FloatingScreen(
            id: 2,
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1056),
            scale: 1
        )
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: CGPoint(x: -1, y: 400), in: [main, left])?.id, 2)
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: CGPoint(x: -1920, y: 0), in: [main, left])?.id, 2)
    }

    func testFindsScreensAboveAndBelowMainScreen() {
        let upper = FloatingScreen(
            id: 2,
            frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 876),
            scale: 1
        )
        let lower = FloatingScreen(
            id: 3,
            frame: CGRect(x: 0, y: -900, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: -900, width: 1440, height: 876),
            scale: 2
        )
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: CGPoint(x: 200, y: 1000), in: [main, upper, lower])?.id, 2)
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: CGPoint(x: 200, y: -100), in: [main, upper, lower])?.id, 3)
    }

    func testVerticalSeamBelongsToRightScreenRegardlessOfOrder() {
        let right = FloatingScreen(
            id: 2,
            frame: CGRect(x: 1440, y: 0, width: 1280, height: 800),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1280, height: 776),
            scale: 1
        )
        let point = CGPoint(x: 1440, y: 400)
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: point, in: [main, right])?.id, 2)
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: point, in: [right, main])?.id, 2)
        XCTAssertFalse(FloatingCardScreenLayout.isInRightEdge(point, of: main))
    }

    func testHorizontalSeamBelongsToUpperScreenRegardlessOfOrder() {
        let upper = FloatingScreen(
            id: 2,
            frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 876),
            scale: 1
        )
        let point = CGPoint(x: 500, y: 900)
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: point, in: [main, upper])?.id, 2)
        XCTAssertEqual(FloatingCardScreenLayout.screen(at: point, in: [upper, main])?.id, 2)
    }

    func testOutsidePointsAndEmptyScreenListHaveNoHit() {
        for point in [CGPoint(x: -1, y: 500), CGPoint(x: 1440, y: 500), CGPoint(x: 500, y: 900)] {
            XCTAssertNil(FloatingCardScreenLayout.screen(at: point, in: [main]))
        }
        XCTAssertNil(FloatingCardScreenLayout.screen(at: .zero, in: []))
    }

    func testRightEdgeUsesTwoLogicalPointsAndRejectsOutsidePoints() {
        XCTAssertTrue(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1438, y: 400), of: main))
        XCTAssertTrue(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1439.5, y: 20), of: main))
        XCTAssertFalse(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1437.9, y: 400), of: main))
        XCTAssertFalse(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1440, y: 400), of: main))
        XCTAssertFalse(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1439, y: -1), of: main))
        XCTAssertFalse(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1439, y: 900), of: main))
        XCTAssertTrue(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1435, y: 400), of: main, width: 5))
        XCTAssertFalse(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1439, y: 400), of: main, width: 0))
    }

    func testPanelCentersVerticallyAndUsesDefaultTrailingInset() {
        XCTAssertEqual(
            FloatingCardScreenLayout.panelOrigin(size: CGSize(width: 280, height: 200), screen: main),
            CGPoint(x: 1148, y: 358)
        )
    }

    func testRightDockMovesPanelButDoesNotMoveScreenHotZone() {
        let dockScreen = FloatingScreen(
            id: 2,
            frame: main.frame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1360, height: 876),
            scale: 2
        )
        XCTAssertEqual(
            FloatingCardScreenLayout.panelOrigin(size: CGSize(width: 280, height: 200), screen: dockScreen),
            CGPoint(x: 1068, y: 338)
        )
        XCTAssertTrue(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1439, y: 500), of: dockScreen))
        XCTAssertFalse(FloatingCardScreenLayout.isInRightEdge(CGPoint(x: 1359, y: 500), of: dockScreen))
    }

    func testNegativeCoordinatesAndCustomInsetArePreservedInPanelOrigin() {
        let left = FloatingScreen(
            id: 2,
            frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: -160, width: 1920, height: 1016),
            scale: 1
        )
        XCTAssertEqual(
            FloatingCardScreenLayout.panelOrigin(size: CGSize(width: 280, height: 200), screen: left, trailingInset: 20),
            CGPoint(x: -300, y: 248)
        )
    }

    func testPixelAlignmentUsesScreenScaleRatherThanScalingLogicalCoordinates() {
        for (scale, expected) in [(CGFloat(1), CGPoint(x: 709, y: 301)), (CGFloat(2), CGPoint(x: 708.5, y: 300.5))] {
            let screen = FloatingScreen(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                scale: scale
            )
            XCTAssertEqual(
                FloatingCardScreenLayout.panelOrigin(size: CGSize(width: 279.4, height: 198.8), screen: screen),
                expected
            )
        }
    }

    func testNonpositiveScaleFallsBackToOne() {
        for scale: CGFloat in [0, -2] {
            let screen = FloatingScreen(id: 1, frame: main.frame, visibleFrame: main.visibleFrame, scale: scale)
            XCTAssertEqual(
                FloatingCardScreenLayout.panelOrigin(size: CGSize(width: 279.4, height: 198.8), screen: screen),
                CGPoint(x: 1149, y: 359)
            )
        }
    }

    func testOversizedCardAnchorsAtVisibleMinimum() {
        XCTAssertEqual(
            FloatingCardScreenLayout.panelOrigin(size: CGSize(width: 1600, height: 1000), screen: main),
            CGPoint(x: 0, y: 40)
        )
    }

    func testPixelRoundingIsClampedBackInsideVisibleFrame() {
        let screen = FloatingScreen(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0.2, y: 0.2, width: 999.8, height: 799.6),
            scale: 1
        )
        XCTAssertEqual(
            FloatingCardScreenLayout.panelOrigin(size: CGSize(width: 1200, height: 799.6), screen: screen),
            CGPoint(x: 0.2, y: 0.2)
        )
    }

    func testOversizedCardRemainsAtFractionalMinimumWhenPixelRoundingMovesRight() {
        let screen = FloatingScreen(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0.6, y: 0, width: 999.4, height: 800),
            scale: 1
        )
        XCTAssertEqual(
            FloatingCardScreenLayout.panelOrigin(size: CGSize(width: 1200, height: 200), screen: screen),
            CGPoint(x: 0.6, y: 300)
        )
    }
}
