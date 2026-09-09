import XCTest
@testable import CodexBar

@MainActor
final class AppLifecycleCoordinatorTests: XCTestCase {
    func testStartAndStopAreIdempotent() async {
        let usage = FakeUsageLifecycle()
        let coordinator = AppLifecycleCoordinator(usage: usage, terminator: FakeApplicationTerminator())

        coordinator.start()
        coordinator.start()
        await coordinator.stop()
        await coordinator.stop()

        XCTAssertEqual(usage.startCount, 1)
        XCTAssertEqual(usage.stopCount, 1)
    }

    func testExplicitQuitStopsUsageBeforeTerminatingApplication() async {
        let events = EventRecorder()
        let usage = FakeUsageLifecycle(events: events)
        let terminator = FakeApplicationTerminator(events: events)
        let coordinator = AppLifecycleCoordinator(usage: usage, terminator: terminator)

        coordinator.start()
        await coordinator.quit()

        XCTAssertEqual(events.values, ["start", "stop", "terminate"])
        XCTAssertEqual(terminator.terminateCount, 1)
    }

    func testSystemTerminationDefersReplyUntilUsageHasStopped() async {
        let usage = FakeUsageLifecycle()
        let coordinator = AppLifecycleCoordinator(usage: usage, terminator: FakeApplicationTerminator())
        let replied = expectation(description: "termination reply")
        var replyValues: [Bool] = []
        coordinator.start()

        let mayTerminateNow = coordinator.handleSystemTermination { allowed in
            replyValues.append(allowed)
            replied.fulfill()
        }

        XCTAssertFalse(mayTerminateNow)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(usage.stopCount, 1)
        XCTAssertEqual(replyValues, [true])
        XCTAssertTrue(coordinator.handleSystemTermination { _ in
            XCTFail("already stopped should terminate synchronously")
        })
    }

    func testExplicitQuitDuringDeferredSystemTerminationDoesNotTerminateRecursively() async {
        let usage = FakeUsageLifecycle()
        let terminator = FakeApplicationTerminator()
        let coordinator = AppLifecycleCoordinator(usage: usage, terminator: terminator)
        let replied = expectation(description: "termination reply")
        coordinator.start()

        XCTAssertFalse(coordinator.handleSystemTermination { _ in replied.fulfill() })
        await coordinator.quit()
        await fulfillment(of: [replied], timeout: 1)

        XCTAssertEqual(usage.stopCount, 1)
        XCTAssertEqual(terminator.terminateCount, 0)
    }
}

@MainActor
private final class FakeUsageLifecycle: UsageLifecycleManaging {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let events: EventRecorder?

    init(events: EventRecorder? = nil) {
        self.events = events
    }

    func start() {
        startCount += 1
        events?.append("start")
    }

    func stop() async {
        stopCount += 1
        events?.append("stop")
    }
}

@MainActor
private final class FakeApplicationTerminator: ApplicationTerminating {
    private(set) var terminateCount = 0
    private let events: EventRecorder?

    init(events: EventRecorder? = nil) {
        self.events = events
    }

    func terminate() {
        terminateCount += 1
        events?.append("terminate")
    }
}

@MainActor
private final class EventRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
