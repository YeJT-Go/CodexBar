import Combine
import Foundation
import ServiceManagement

protocol LoginItemManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

struct LoginItemManager: LoginItemManaging {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private let manager: any LoginItemManaging

    init(manager: any LoginItemManaging) {
        self.manager = manager
        isEnabled = manager.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try manager.setEnabled(enabled)
            isEnabled = manager.isEnabled
            errorMessage = nil
        } catch {
            isEnabled = manager.isEnabled
            errorMessage = "无法更新登录项：\(error.localizedDescription)"
        }
    }
}
