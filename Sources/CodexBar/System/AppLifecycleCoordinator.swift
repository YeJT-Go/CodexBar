import AppKit
import Combine

@MainActor
protocol UsageLifecycleManaging: AnyObject {
    func start()
    func stop() async
}

extension UsageViewModel: UsageLifecycleManaging {}

@MainActor
protocol ApplicationTerminating: AnyObject {
    func terminate()
}

@MainActor
final class ApplicationTerminator: ApplicationTerminating {
    func terminate() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class AppLifecycleCoordinator: ObservableObject {
    private enum State {
        case idle
        case running
        case stopping
        case stopped
    }

    private let usage: any UsageLifecycleManaging
    private let terminator: any ApplicationTerminating
    private var state = State.idle
    private var stopTask: Task<Void, Never>?
    private var hasRequestedQuit = false
    private var hasDeferredSystemTermination = false

    init(usage: any UsageLifecycleManaging, terminator: any ApplicationTerminating) {
        self.usage = usage
        self.terminator = terminator
    }

    func start() {
        guard state == .idle else { return }
        state = .running
        usage.start()
    }

    func stop() async {
        if state == .stopped { return }
        if let stopTask {
            await stopTask.value
            return
        }

        state = .stopping
        let usage = self.usage
        let task = Task { await usage.stop() }
        stopTask = task
        await task.value
        stopTask = nil
        state = .stopped
    }

    func quit() async {
        guard !hasRequestedQuit else { return }
        hasRequestedQuit = true
        await stop()
        if !hasDeferredSystemTermination {
            terminator.terminate()
        }
    }

    /// Returns true when AppKit may terminate immediately. A false result means
    /// the caller must return `.terminateLater`; `reply` is called after cleanup.
    func handleSystemTermination(reply: @escaping @MainActor (Bool) -> Void) -> Bool {
        if state == .stopped { return true }
        guard !hasDeferredSystemTermination else { return false }
        hasDeferredSystemTermination = true
        Task {
            await stop()
            reply(true)
        }
        return false
    }
}

@MainActor
final class CodexBarApplicationDelegate: NSObject, NSApplicationDelegate {
    var lifecycle: AppLifecycleCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lifecycle else { return .terminateNow }
        let mayTerminateNow = lifecycle.handleSystemTermination { allowed in
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return mayTerminateNow ? .terminateNow : .terminateLater
    }
}
