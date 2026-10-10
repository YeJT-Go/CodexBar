import XCTest
@testable import CodexBar

final class FloatingCardVisibilityStateTests: XCTestCase {
    func testStartsHiddenAndShowsWhenPointerEnters() {
        var machine = FloatingCardVisibilityMachine()

        XCTAssertEqual(machine.handle(.pointerChanged(isInside: false)), [])
        XCTAssertEqual(machine.handle(.pointerChanged(isInside: true)), [.show])
    }

    func testLeavingVisibleCardSchedulesOneThreeSecondHide() {
        var machine = FloatingCardVisibilityMachine()

        _ = machine.handle(.pointerChanged(isInside: true))
        let expected: [FloatingCardVisibilityEffect] = [.scheduleHide(token: 1, delay: .seconds(3))]
        XCTAssertEqual(machine.handle(.pointerChanged(isInside: false)), expected)
        XCTAssertEqual(machine.handle(.pointerChanged(isInside: false)), [])
    }

    func testReturningDuringWaitCancelsPendingHide() {
        var machine = FloatingCardVisibilityMachine()

        _ = machine.handle(.pointerChanged(isInside: true))
        _ = machine.handle(.pointerChanged(isInside: false))

        XCTAssertEqual(machine.handle(.pointerChanged(isInside: true)), [.cancelPending])
        XCTAssertEqual(machine.handle(.hideDelayElapsed(token: 1)), [])
    }

    func testMatchingHideDelayStartsFadeAndReturningDuringFadeRestores() {
        var machine = FloatingCardVisibilityMachine()

        _ = machine.handle(.pointerChanged(isInside: true))
        _ = machine.handle(.pointerChanged(isInside: false))
        XCTAssertEqual(
            machine.handle(.hideDelayElapsed(token: 1)),
            [.beginFade(token: 1, duration: 0.25)]
        )

        XCTAssertEqual(machine.handle(.pointerChanged(isInside: true)), [.cancelPending, .restore])
        XCTAssertEqual(machine.handle(.fadeCompleted(token: 1)), [])
    }

    func testOldWaitAndFadeTokensCannotAffectNewVisibilityCycle() {
        var machine = FloatingCardVisibilityMachine()

        _ = machine.handle(.pointerChanged(isInside: true))
        _ = machine.handle(.pointerChanged(isInside: false))
        XCTAssertEqual(machine.handle(.hideDelayElapsed(token: 99)), [])
        _ = machine.handle(.hideDelayElapsed(token: 1))
        XCTAssertEqual(machine.handle(.fadeCompleted(token: 99)), [])
        XCTAssertEqual(machine.handle(.pointerChanged(isInside: true)), [.cancelPending, .restore])

        _ = machine.handle(.pointerChanged(isInside: false))
        XCTAssertEqual(machine.handle(.hideDelayElapsed(token: 1)), [])
        XCTAssertEqual(machine.handle(.hideDelayElapsed(token: 2)), [.beginFade(token: 2, duration: 0.25)])
        XCTAssertEqual(machine.handle(.fadeCompleted(token: 1)), [])
    }

    func testResetHidesAndInvalidatesOutstandingCallbacks() {
        var machine = FloatingCardVisibilityMachine()

        _ = machine.handle(.pointerChanged(isInside: true))
        _ = machine.handle(.pointerChanged(isInside: false))
        XCTAssertEqual(machine.handle(.reset), [.cancelPending, .hide])
        XCTAssertEqual(machine.handle(.hideDelayElapsed(token: 1)), [])
        XCTAssertEqual(machine.handle(.reset), [])

        XCTAssertEqual(machine.handle(.pointerChanged(isInside: true)), [.show])
        XCTAssertEqual(
            machine.handle(.pointerChanged(isInside: false)),
            [.scheduleHide(token: 3, delay: .seconds(3))]
        )
    }

    func testWaitingAndFadingIgnoreRepeatedOutsideChanges() {
        var machine = FloatingCardVisibilityMachine()

        _ = machine.handle(.pointerChanged(isInside: true))
        _ = machine.handle(.pointerChanged(isInside: false))
        XCTAssertEqual(machine.handle(.pointerChanged(isInside: false)), [])

        _ = machine.handle(.hideDelayElapsed(token: 1))
        XCTAssertEqual(machine.handle(.pointerChanged(isInside: false)), [])
    }

    func testMatchingFadeCompletionHidesCard() {
        var machine = FloatingCardVisibilityMachine()

        _ = machine.handle(.pointerChanged(isInside: true))
        _ = machine.handle(.pointerChanged(isInside: false))
        _ = machine.handle(.hideDelayElapsed(token: 1))

        XCTAssertEqual(machine.handle(.fadeCompleted(token: 1)), [.hide])
        XCTAssertEqual(machine.handle(.pointerChanged(isInside: false)), [])
    }
}
