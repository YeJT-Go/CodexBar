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
}

private final class FakeLoginItemManager: LoginItemManaging {
    private(set) var isEnabled: Bool
    private let error: Error?

    init(isEnabled: Bool, error: Error? = nil) {
        self.isEnabled = isEnabled
        self.error = error
    }

    func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
        isEnabled = enabled
    }
}

private enum LoginItemTestError: LocalizedError {
    case denied

    var errorDescription: String? { "没有权限" }
}
