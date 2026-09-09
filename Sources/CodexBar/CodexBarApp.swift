import SwiftUI

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(CodexBarApplicationDelegate.self) private var appDelegate
    @StateObject private var model: UsageViewModel
    @StateObject private var lifecycle: AppLifecycleCoordinator

    init() {
        let model = AppDependencies.makeUsageViewModel()
        _model = StateObject(wrappedValue: model)
        _lifecycle = StateObject(wrappedValue: AppLifecycleCoordinator(
            usage: model,
            terminator: ApplicationTerminator()
        ))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                model: model,
                loginItems: LoginItemManager(),
                lifecycle: lifecycle
            )
        } label: {
            MenuBarLabel(presentation: .make(from: model.state))
                .task {
                    appDelegate.lifecycle = lifecycle
                    lifecycle.start()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum AppDependencies {
    static func makeUsageViewModel() -> UsageViewModel {
        let provider: any CodexUsageProviding
        do {
            provider = CodexAppServerClient(executableURL: try CodexExecutableLocator().locate())
        } catch {
            provider = UnavailableUsageProvider(message: userFacingMessage(for: error))
        }
        return UsageViewModel(client: provider)
    }

    private static func userFacingMessage(for error: Error) -> String {
        if error as? CodexClientError == .executableNotFound {
            return "未找到 Codex CLI，请先安装或检查 PATH"
        }
        return error.localizedDescription
    }
}

private struct UnavailableUsageProvider: CodexUsageProviding {
    let message: String

    func connect() async throws { throw StartupError(message: message) }
    func fetchRateLimits() async throws -> RateLimitsResponse { throw StartupError(message: message) }
    func updates() -> AsyncStream<RateLimitsResponse> { AsyncStream { $0.finish() } }
    func stop() async {}
}

private struct StartupError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
