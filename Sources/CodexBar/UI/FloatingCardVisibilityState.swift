import Foundation

enum FloatingCardVisibilityState: Equatable, Sendable {
    case hidden
    case visible
    case waiting(token: UInt64)
    case fading(token: UInt64)
}

enum FloatingCardVisibilityEvent: Sendable {
    case pointerChanged(isInside: Bool)
    case hideDelayElapsed(token: UInt64)
    case fadeCompleted(token: UInt64)
    case reset
}

enum FloatingCardVisibilityEffect: Equatable, Sendable {
    case show
    case scheduleHide(token: UInt64, delay: Duration)
    case beginFade(token: UInt64, duration: TimeInterval)
    case restore
    case hide
    case cancelPending
}

struct FloatingCardVisibilityMachine: Sendable {
    private(set) var state: FloatingCardVisibilityState = .hidden
    private var token: UInt64 = 0

    mutating func handle(_ event: FloatingCardVisibilityEvent) -> [FloatingCardVisibilityEffect] {
        switch (state, event) {
        case (.hidden, .pointerChanged(isInside: true)):
            state = .visible
            return [.show]

        case (.visible, .pointerChanged(isInside: false)):
            token &+= 1
            state = .waiting(token: token)
            return [.scheduleHide(token: token, delay: .seconds(3))]

        case (.waiting, .pointerChanged(isInside: true)):
            state = .visible
            return [.cancelPending]

        case let (.waiting(activeToken), .hideDelayElapsed(token: eventToken)) where activeToken == eventToken:
            state = .fading(token: activeToken)
            return [.beginFade(token: activeToken, duration: 0.25)]

        case (.fading, .pointerChanged(isInside: true)):
            state = .visible
            return [.cancelPending, .restore]

        case let (.fading(activeToken), .fadeCompleted(token: eventToken)) where activeToken == eventToken:
            state = .hidden
            return [.hide]

        case (_, .reset) where state != .hidden:
            token &+= 1
            state = .hidden
            return [.cancelPending, .hide]

        default:
            return []
        }
    }
}
