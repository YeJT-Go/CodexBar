import XCTest
@testable import CodexBar

@MainActor
final class LoginItemManagerTests: XCTestCase {
    func testSuccessfulChangeUpdatesDisplayedSetting() {
        let manager = FakeLoginItemManager(isEnabled: false)
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(true)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testRegistrationFailureRestoresSettingAndShowsError() {
        let manager = FakeLoginItemManager(isEnabled: false, error: LoginItemTestError.denied)
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.errorMessage, "无法更新登录项：没有权限")
    }

    func testRegistrationWithoutErrorButUnchangedSystemStatusShowsSettingsGuidance() {
        let manager = FakeLoginItemManager(isEnabled: false, acceptsChange: false)
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(
            controller.errorMessage,
            "登录项尚未启用，请前往“系统设置 > 通用 > 登录项”允许 CodexBar。"
        )
    }

    func testSynchronizeReadsStatusChangedOutsideApplication() {
        let manager = FakeLoginItemManager(isEnabled: false)
        let controller = LoginItemController(manager: manager)
        manager.simulateExternalChange(to: true)

        controller.synchronize()

        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }
}

private final class FakeLoginItemManager: LoginItemManaging {
    private(set) var isEnabled: Bool
    private let error: Error?
    private let acceptsChange: Bool

    init(isEnabled: Bool, error: Error? = nil, acceptsChange: Bool = true) {
        self.isEnabled = isEnabled
        self.error = error
        self.acceptsChange = acceptsChange
    }

    func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
        if acceptsChange { isEnabled = enabled }
    }

    func simulateExternalChange(to enabled: Bool) { isEnabled = enabled }
}

private enum LoginItemTestError: LocalizedError {
    case denied

    var errorDescription: String? { "没有权限" }
}
