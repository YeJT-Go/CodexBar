import AppKit
import SwiftUI

enum FloatingCardSystemEvent: Sendable {
    case screenParametersChanged
    case accessibilityDisplayOptionsChanged
    case willSleep
    case didWake
}

@MainActor
protocol FloatingCardEnvironment: AnyObject {
    var mouseLocation: CGPoint { get }
    var screens: [FloatingScreen] { get }
    var reduceTransparency: Bool { get }
    var reduceMotion: Bool { get }

    func startObserving(_ handler: @escaping @MainActor @Sendable (FloatingCardSystemEvent) -> Void)
    func stopObserving()
}

@MainActor
protocol FloatingCardCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol FloatingCardScheduling: AnyObject {
    func repeating(
        every interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any FloatingCardCancellation

    func once(
        after delay: Duration,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any FloatingCardCancellation
}

@MainActor
protocol FloatingCardPanelPresenting: AnyObject {
    var contentSize: CGSize { get }
    var frame: CGRect { get }
    var isVisible: Bool { get }

    func show(frame: CGRect, reduceTransparency: Bool)
    func move(to frame: CGRect)
    func setReduceTransparency(_ enabled: Bool)
    func fadeOut(duration: TimeInterval, completion: @escaping @MainActor @Sendable () -> Void)
    func restore(duration: TimeInterval)
    func hide()
}

@MainActor
final class FloatingQuotaCardController {
    private let environment: any FloatingCardEnvironment
    private let scheduler: any FloatingCardScheduling
    private let panel: any FloatingCardPanelPresenting

    private var visibilityMachine = FloatingCardVisibilityMachine()
    private var sampling: (any FloatingCardCancellation)?
    private var pendingHide: (any FloatingCardCancellation)?
    private var activeScreenID: Int?
    private var targetFrame = CGRect.zero
    private var isStarted = false
    private var isSleeping = false

    init(
        model: UsageViewModel,
        environment: (any FloatingCardEnvironment)? = nil,
        scheduler: (any FloatingCardScheduling)? = nil,
        panel: (any FloatingCardPanelPresenting)? = nil
    ) {
        self.environment = environment ?? AppKitFloatingCardEnvironment()
        self.scheduler = scheduler ?? TaskFloatingCardScheduler()
        self.panel = panel ?? AppKitFloatingQuotaPanel(model: model)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        isSleeping = false
        environment.startObserving { [weak self] event in
            self?.handleSystemEvent(event)
        }
        resumeSampling()
        samplePointer()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        isSleeping = false
        sampling?.cancel()
        sampling = nil
        pendingHide?.cancel()
        pendingHide = nil
        environment.stopObserving()
        apply(visibilityMachine.handle(.reset))
        activeScreenID = nil
        panel.hide()
    }

    private func resumeSampling() {
        guard isStarted, !isSleeping, sampling == nil else { return }
        sampling = scheduler.repeating(every: 0.1) { [weak self] in
            self?.samplePointer()
        }
    }

    private func samplePointer() {
        guard isStarted, !isSleeping else { return }
        let point = environment.mouseLocation
        let screens = environment.screens

        if let pointerScreen = FloatingCardScreenLayout.screen(at: point, in: screens),
           FloatingCardScreenLayout.isInRightEdge(point, of: pointerScreen) {
            activeScreenID = pointerScreen.id
            positionPanel(on: pointerScreen)
            apply(visibilityMachine.handle(.pointerChanged(isInside: true)))
            return
        }

        if let activeScreen = screens.first(where: { $0.id == activeScreenID }) {
            positionPanel(on: activeScreen)
        }
        let isInsidePanel = panel.isVisible && panel.frame.contains(point)
        apply(visibilityMachine.handle(.pointerChanged(isInside: isInsidePanel)))
    }

    private func positionPanel(on screen: FloatingScreen) {
        let size = panel.contentSize
        let origin = FloatingCardScreenLayout.panelOrigin(size: size, screen: screen)
        targetFrame = CGRect(origin: origin, size: size)
        panel.move(to: targetFrame)
    }

    private func handleSystemEvent(_ event: FloatingCardSystemEvent) {
        guard isStarted else { return }
        switch event {
        case .screenParametersChanged:
            if let activeScreenID,
               !environment.screens.contains(where: { $0.id == activeScreenID }) {
                apply(visibilityMachine.handle(.reset))
                self.activeScreenID = nil
            }
            samplePointer()

        case .accessibilityDisplayOptionsChanged:
            panel.setReduceTransparency(environment.reduceTransparency)

        case .willSleep:
            guard !isSleeping else { return }
            isSleeping = true
            sampling?.cancel()
            sampling = nil
            pendingHide?.cancel()
            pendingHide = nil
            apply(visibilityMachine.handle(.reset))
            activeScreenID = nil
            panel.hide()

        case .didWake:
            guard isSleeping else { return }
            isSleeping = false
            resumeSampling()
            samplePointer()
        }
    }

    private func apply(_ effects: [FloatingCardVisibilityEffect]) {
        for effect in effects {
            switch effect {
            case .show:
                panel.show(frame: targetFrame, reduceTransparency: environment.reduceTransparency)

            case let .scheduleHide(token, delay):
                pendingHide?.cancel()
                pendingHide = scheduler.once(after: delay) { [weak self] in
                    guard let self, self.isStarted, !self.isSleeping else { return }
                    self.pendingHide = nil
                    self.apply(self.visibilityMachine.handle(.hideDelayElapsed(token: token)))
                }

            case let .beginFade(token, duration):
                let actualDuration = environment.reduceMotion ? 0 : duration
                panel.fadeOut(duration: actualDuration) { [weak self] in
                    guard let self, self.isStarted, !self.isSleeping else { return }
                    self.apply(self.visibilityMachine.handle(.fadeCompleted(token: token)))
                }

            case .restore:
                panel.restore(duration: environment.reduceMotion ? 0 : 0.1)

            case .hide:
                pendingHide?.cancel()
                pendingHide = nil
                activeScreenID = nil
                panel.hide()

            case .cancelPending:
                pendingHide?.cancel()
                pendingHide = nil
            }
        }
    }
}

@MainActor
private final class AppKitFloatingCardEnvironment: NSObject, FloatingCardEnvironment {
    private var handler: (@MainActor @Sendable (FloatingCardSystemEvent) -> Void)?
    private var isObserving = false

    var mouseLocation: CGPoint { NSEvent.mouseLocation }

    var screens: [FloatingScreen] {
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return FloatingScreen(
                id: number?.intValue ?? screen.hash,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                scale: screen.backingScaleFactor
            )
        }
    }

    var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func startObserving(_ handler: @escaping @MainActor @Sendable (FloatingCardSystemEvent) -> Void) {
        guard !isObserving else { return }
        isObserving = true
        self.handler = handler
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        handler = nil
    }

    @objc private func screenParametersChanged() {
        handler?(.screenParametersChanged)
    }

    @objc private func accessibilityOptionsChanged() {
        handler?(.accessibilityDisplayOptionsChanged)
    }

    @objc private func willSleep() {
        handler?(.willSleep)
    }

    @objc private func didWake() {
        handler?(.didWake)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

@MainActor
private final class TaskFloatingCardScheduler: FloatingCardScheduling {
    func repeating(
        every interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any FloatingCardCancellation {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                action()
            }
        }
        return TaskFloatingCardCancellation(task: task)
    }

    func once(
        after delay: Duration,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any FloatingCardCancellation {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return TaskFloatingCardCancellation(task: task)
    }
}

@MainActor
private final class TaskFloatingCardCancellation: FloatingCardCancellation {
    private var task: Task<Void, Never>?

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
private final class FloatingQuotaPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingCardMaterialView: NSVisualEffectView {
    typealias OpaqueBackgroundColor = @MainActor () -> NSColor

    private let opaqueBackgroundColor: OpaqueBackgroundColor
    private var reduceTransparency = false

    init(
        opaqueBackgroundColor: @escaping OpaqueBackgroundColor = { .windowBackgroundColor }
    ) {
        self.opaqueBackgroundColor = opaqueBackgroundColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        opaqueBackgroundColor = { .windowBackgroundColor }
        super.init(coder: coder)
        wantsLayer = true
    }

    func setReduceTransparency(_ enabled: Bool) {
        reduceTransparency = enabled
        refreshMaterialAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMaterialAppearance()
    }

    private func refreshMaterialAppearance() {
        guard reduceTransparency else {
            blendingMode = .behindWindow
            state = .active
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }

        blendingMode = .withinWindow
        state = .inactive
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = opaqueBackgroundColor().cgColor
        }
    }
}

@MainActor
private final class AppKitFloatingQuotaPanel: FloatingCardPanelPresenting {
    private let panel: FloatingQuotaPanel
    private let effectView: FloatingCardMaterialView
    private let hostingView: NSHostingView<FloatingQuotaCardView>

    init(model: UsageViewModel) {
        hostingView = NSHostingView(rootView: FloatingQuotaCardView(model: model))
        effectView = FloatingCardMaterialView()
        panel = FloatingQuotaPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        effectView.layer?.masksToBounds = true

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])
        panel.contentView = effectView
    }

    var contentSize: CGSize {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        return CGSize(width: 148, height: max(1, fitting.height))
    }

    var frame: CGRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    func show(frame: CGRect, reduceTransparency: Bool) {
        setReduceTransparency(reduceTransparency)
        panel.alphaValue = 1
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func move(to frame: CGRect) {
        panel.setFrame(frame, display: panel.isVisible)
    }

    func setReduceTransparency(_ enabled: Bool) {
        effectView.setReduceTransparency(enabled)
    }

    func fadeOut(
        duration: TimeInterval,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                completion()
            }
        }
    }

    func restore(duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel.orderOut(nil)
        panel.alphaValue = 1
    }
}
