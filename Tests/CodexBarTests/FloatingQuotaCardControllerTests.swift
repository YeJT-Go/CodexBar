import AppKit
import Foundation
import XCTest
@testable import CodexBar

@MainActor
final class FloatingQuotaCardControllerTests: XCTestCase {
    private let main = FloatingScreen(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876),
        scale: 2
    )

    func testRepeatedStartCreatesOneSamplerAndOneObservation() {
        let harness = makeHarness(pointer: CGPoint(x: 500, y: 500))

        harness.controller.start()
        harness.controller.start()

        XCTAssertEqual(harness.scheduler.repeatingIntervals, [0.1])
        XCTAssertEqual(harness.environment.startObservingCount, 1)
        XCTAssertFalse(harness.panel.isVisible)
    }

    func testEdgeOnAnotherScreenMovesTheSamePanel() {
        let right = FloatingScreen(
            id: 2,
            frame: CGRect(x: 1440, y: -100, width: 1280, height: 800),
            visibleFrame: CGRect(x: 1440, y: -76, width: 1280, height: 776),
            scale: 1
        )
        let harness = makeHarness(pointer: CGPoint(x: 1439, y: 500), screens: [main, right])

        harness.controller.start()
        let firstFrame = harness.panel.frame
        harness.environment.mouseLocation = CGPoint(x: 2719, y: 300)
        harness.scheduler.fireRepeating()

        XCTAssertTrue(harness.panel.isVisible)
        XCTAssertEqual(harness.panel.showCount, 1)
        XCTAssertNotEqual(harness.panel.frame, firstFrame)
        XCTAssertEqual(harness.panel.frame.origin.x, 2560)
    }

    func testPointerInPanelKeepsItVisibleWithoutSchedulingHide() {
        let harness = makeHarness(pointer: CGPoint(x: 1439, y: 500))

        harness.controller.start()
        harness.environment.mouseLocation = CGPoint(
            x: harness.panel.frame.midX,
            y: harness.panel.frame.midY
        )
        harness.scheduler.fireRepeating()

        XCTAssertTrue(harness.panel.isVisible)
        XCTAssertTrue(harness.scheduler.oneShots.isEmpty)
    }

    func testLeavingSchedulesOneDelayThenFadesAndHidesAfterCompletion() {
        let harness = makeHarness(pointer: CGPoint(x: 1439, y: 500))

        harness.controller.start()
        harness.environment.mouseLocation = CGPoint(x: 500, y: 500)
        harness.scheduler.fireRepeating()
        harness.scheduler.fireRepeating()

        XCTAssertEqual(harness.scheduler.oneShots.map(\.delay), [.seconds(3)])
        XCTAssertTrue(harness.panel.fadeDurations.isEmpty)

        harness.scheduler.fireOneShot(at: 0)

        XCTAssertEqual(harness.panel.fadeDurations, [0.25])
        XCTAssertTrue(harness.panel.isVisible)

        harness.panel.completeFade(at: 0)

        XCTAssertFalse(harness.panel.isVisible)
    }

    func testReturningCancelsDelayAndOldCallbackCannotStartFade() {
        let harness = makeHarness(pointer: CGPoint(x: 1439, y: 500))

        harness.controller.start()
        harness.environment.mouseLocation = CGPoint(x: 500, y: 500)
        harness.scheduler.fireRepeating()
        harness.environment.mouseLocation = CGPoint(
            x: harness.panel.frame.midX,
            y: harness.panel.frame.midY
        )
        harness.scheduler.fireRepeating()
        harness.scheduler.fireOneShot(at: 0, includingCancelled: true)

        XCTAssertTrue(harness.scheduler.oneShots[0].isCancelled)
        XCTAssertTrue(harness.panel.fadeDurations.isEmpty)
        XCTAssertTrue(harness.panel.isVisible)
    }

    func testReturningDuringFadeRestoresAndOldCompletionCannotHide() {
        let harness = makeHarness(pointer: CGPoint(x: 1439, y: 500))

        harness.controller.start()
        harness.environment.mouseLocation = CGPoint(x: 500, y: 500)
        harness.scheduler.fireRepeating()
        harness.scheduler.fireOneShot(at: 0)
        harness.environment.mouseLocation = CGPoint(
            x: harness.panel.frame.midX,
            y: harness.panel.frame.midY
        )
        harness.scheduler.fireRepeating()
        harness.panel.completeFade(at: 0)

        XCTAssertEqual(harness.panel.restoreDurations, [0.1])
        XCTAssertTrue(harness.panel.isVisible)
    }

    func testSleepInvalidatesCallbacksAndWakeRestartsSampling() {
        let harness = makeHarness(pointer: CGPoint(x: 1439, y: 500))

        harness.controller.start()
        harness.environment.mouseLocation = CGPoint(x: 500, y: 500)
        harness.scheduler.fireRepeating()
        harness.environment.send(.willSleep)

        XCTAssertFalse(harness.panel.isVisible)
        XCTAssertTrue(harness.scheduler.repeatingHandles[0].isCancelled)

        harness.scheduler.fireOneShot(at: 0, includingCancelled: true)
        XCTAssertTrue(harness.panel.fadeDurations.isEmpty)

        harness.environment.mouseLocation = CGPoint(x: 1439, y: 500)
        harness.environment.send(.didWake)

        XCTAssertEqual(harness.scheduler.repeatingIntervals, [0.1, 0.1])
        XCTAssertTrue(harness.panel.isVisible)
    }

    func testScreenChangeRecalculatesOrHidesWhenTriggeredScreenDisconnects() {
        let harness = makeHarness(pointer: CGPoint(x: 1439, y: 500))

        harness.controller.start()
        harness.environment.screens = []
        harness.environment.send(.screenParametersChanged)

        XCTAssertFalse(harness.panel.isVisible)
    }

    func testDisconnectedSecondScreenMovesSamePanelToFirstScreenEdge() {
        let right = FloatingScreen(
            id: 2,
            frame: CGRect(x: 1440, y: -100, width: 1280, height: 800),
            visibleFrame: CGRect(x: 1440, y: -76, width: 1280, height: 776),
            scale: 1
        )
        let harness = makeHarness(pointer: CGPoint(x: 2719, y: 300), screens: [main, right])

        harness.controller.start()
        XCTAssertEqual(harness.panel.frame.origin.x, 2560)

        harness.environment.screens = [main]
        harness.environment.mouseLocation = CGPoint(x: 1439, y: 500)
        harness.environment.send(.screenParametersChanged)

        XCTAssertTrue(harness.panel.isVisible)
        XCTAssertEqual(harness.panel.showCount, 2)
        XCTAssertEqual(harness.panel.frame.origin, CGPoint(x: 1280, y: 352))
    }

    func testReducedTransparencyMaterialRefreshesColorWhenEffectiveAppearanceChanges() throws {
        let source = MaterialBackgroundSource(color: .systemRed)
        let materialView = FloatingCardMaterialView {
            source.resolutionCount += 1
            return source.color
        }

        materialView.setReduceTransparency(true)
        let countAfterEnabling = source.resolutionCount
        let firstColor = try XCTUnwrap(materialView.layer?.backgroundColor)
        source.color = .systemBlue
        materialView.viewDidChangeEffectiveAppearance()
        let refreshedColor = try XCTUnwrap(materialView.layer?.backgroundColor)

        XCTAssertEqual(source.resolutionCount, countAfterEnabling + 1)
        XCTAssertNotEqual(refreshedColor, firstColor)
    }

    func testAccessibilityOptionsUpdateStyleAndReduceMotionSkipsFadeDuration() {
        let harness = makeHarness(pointer: CGPoint(x: 1439, y: 500))

        harness.controller.start()
        harness.environment.reduceTransparency = true
        harness.environment.reduceMotion = true
        harness.environment.send(.accessibilityDisplayOptionsChanged)
        harness.environment.mouseLocation = CGPoint(x: 500, y: 500)
        harness.scheduler.fireRepeating()
        harness.scheduler.fireOneShot(at: 0)

        XCTAssertEqual(harness.panel.transparencySettings, [false, true])
        XCTAssertEqual(harness.panel.fadeDurations, [0])
    }

    func testStopIsIdempotentAndReleasesOnlyFloatingCardResources() {
        let harness = makeHarness(pointer: CGPoint(x: 1439, y: 500))

        harness.controller.start()
        harness.controller.stop()
        harness.controller.stop()

        XCTAssertEqual(harness.environment.stopObservingCount, 1)
        XCTAssertTrue(harness.scheduler.repeatingHandles[0].isCancelled)
        XCTAssertFalse(harness.panel.isVisible)
        XCTAssertEqual(harness.provider.stopCount, 0)
    }

    private func makeHarness(
        pointer: CGPoint,
        screens: [FloatingScreen]? = nil
    ) -> Harness {
        let provider = ControllerNoopUsageProvider()
        let model = UsageViewModel(
            client: provider,
            store: ControllerEmptyUsageStore()
        )
        let environment = FakeFloatingCardEnvironment(
            mouseLocation: pointer,
            screens: screens ?? [main]
        )
        let scheduler = FakeFloatingCardScheduler()
        let panel = FakeFloatingCardPanel(contentSize: CGSize(width: 148, height: 220))
        let controller = FloatingQuotaCardController(
            model: model,
            environment: environment,
            scheduler: scheduler,
            panel: panel
        )
        return Harness(
            controller: controller,
            environment: environment,
            scheduler: scheduler,
            panel: panel,
            provider: provider
        )
    }
}

@MainActor
private struct Harness {
    let controller: FloatingQuotaCardController
    let environment: FakeFloatingCardEnvironment
    let scheduler: FakeFloatingCardScheduler
    let panel: FakeFloatingCardPanel
    let provider: ControllerNoopUsageProvider
}

@MainActor
private final class MaterialBackgroundSource {
    var color: NSColor
    var resolutionCount = 0

    init(color: NSColor) {
        self.color = color
    }
}

@MainActor
private final class FakeFloatingCardEnvironment: FloatingCardEnvironment {
    var mouseLocation: CGPoint
    var screens: [FloatingScreen]
    var reduceTransparency = false
    var reduceMotion = false
    private var handler: (@MainActor @Sendable (FloatingCardSystemEvent) -> Void)?
    private(set) var startObservingCount = 0
    private(set) var stopObservingCount = 0

    init(mouseLocation: CGPoint, screens: [FloatingScreen]) {
        self.mouseLocation = mouseLocation
        self.screens = screens
    }

    func startObserving(
        _ handler: @escaping @MainActor @Sendable (FloatingCardSystemEvent) -> Void
    ) {
        startObservingCount += 1
        self.handler = handler
    }

    func stopObserving() {
        stopObservingCount += 1
        handler = nil
    }

    func send(_ event: FloatingCardSystemEvent) {
        handler?(event)
    }
}

@MainActor
private final class FakeFloatingCardScheduler: FloatingCardScheduling {
    final class Handle: FloatingCardCancellation {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }

    @MainActor
    struct OneShot {
        let delay: Duration
        let action: @MainActor @Sendable () -> Void
        let handle: Handle
        var isCancelled: Bool { handle.isCancelled }
    }

    private(set) var repeatingIntervals: [TimeInterval] = []
    private(set) var repeatingActions: [@MainActor @Sendable () -> Void] = []
    private(set) var repeatingHandles: [Handle] = []
    private(set) var oneShots: [OneShot] = []

    func repeating(
        every interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any FloatingCardCancellation {
        let handle = Handle()
        repeatingIntervals.append(interval)
        repeatingActions.append(action)
        repeatingHandles.append(handle)
        return handle
    }

    func once(
        after delay: Duration,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any FloatingCardCancellation {
        let handle = Handle()
        oneShots.append(.init(delay: delay, action: action, handle: handle))
        return handle
    }

    func fireRepeating(at index: Int = 0) {
        guard !repeatingHandles[index].isCancelled else { return }
        repeatingActions[index]()
    }

    func fireOneShot(at index: Int, includingCancelled: Bool = false) {
        guard includingCancelled || !oneShots[index].isCancelled else { return }
        oneShots[index].action()
    }
}

@MainActor
private final class FakeFloatingCardPanel: FloatingCardPanelPresenting {
    let contentSize: CGSize
    private(set) var frame = CGRect.zero
    private(set) var isVisible = false
    private(set) var showCount = 0
    private(set) var transparencySettings: [Bool] = []
    private(set) var fadeDurations: [TimeInterval] = []
    private(set) var fadeCompletions: [@MainActor @Sendable () -> Void] = []
    private(set) var restoreDurations: [TimeInterval] = []

    init(contentSize: CGSize) {
        self.contentSize = contentSize
    }

    func show(frame: CGRect, reduceTransparency: Bool) {
        self.frame = frame
        isVisible = true
        showCount += 1
        transparencySettings.append(reduceTransparency)
    }

    func move(to frame: CGRect) {
        self.frame = frame
    }

    func setReduceTransparency(_ enabled: Bool) {
        transparencySettings.append(enabled)
    }

    func fadeOut(
        duration: TimeInterval,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        fadeDurations.append(duration)
        fadeCompletions.append(completion)
    }

    func restore(duration: TimeInterval) {
        restoreDurations.append(duration)
    }

    func hide() {
        isVisible = false
    }

    func completeFade(at index: Int) {
        fadeCompletions[index]()
    }
}

private final class ControllerNoopUsageProvider: CodexUsageProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stopCount = 0

    func connect() async throws {}
    func fetchRateLimits() async throws -> RateLimitsResponse { throw ControllerTestError.unavailable }
    func fetchAccountUsage() async throws -> AccountTokenUsageResponse { throw ControllerTestError.unavailable }
    func updates() -> AsyncStream<RateLimitsResponse> { AsyncStream { $0.finish() } }
    func stop() async { lock.withLock { stopCount += 1 } }
}

private struct ControllerEmptyUsageStore: UsageStoring {
    func load() -> UsageSnapshot? { nil }
    func save(_: UsageSnapshot) {}
}

private enum ControllerTestError: Error {
    case unavailable
}
