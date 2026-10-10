import Foundation

enum FloatingQuotaLevel: Equatable, Sendable {
    case healthy
    case warning
    case critical
    case stale

    static func level(forRemaining value: Int) -> Self {
        value > 50 ? .healthy : value > 19 ? .warning : .critical
    }
}

struct FloatingQuotaRingPresentation: Equatable, Sendable {
    let title: String
    let remainingText: String
    let progress: Double?
    let level: FloatingQuotaLevel
    let accessibilityLabel: String
    let accessibilityValue: String
}

struct FloatingQuotaCardPresentation: Equatable, Sendable {
    let fiveHour: FloatingQuotaRingPresentation?
    let weekly: FloatingQuotaRingPresentation
    let statusText: String?

    static func make(from state: UsageState) -> Self {
        switch state {
        case .loading:
            return missing(statusText: "正在加载…")
        case let .current(snapshot):
            return snapshotPresentation(snapshot, statusText: nil)
        case let .stale(snapshot, _):
            return snapshotPresentation(snapshot, statusText: "数据已过期")
        case let .unavailable(message):
            return missing(statusText: message.isEmpty ? "额度暂不可用" : message)
        }
    }

    private static func snapshotPresentation(
        _ snapshot: UsageSnapshot,
        statusText: String?
    ) -> Self {
        Self(
            fiveHour: snapshot.fiveHour.map { ring(title: "5 小时", remainingPercent: $0.remainingPercent) },
            weekly: ring(title: "每周", remainingPercent: snapshot.weekly.remainingPercent),
            statusText: statusText
        )
    }

    private static func missing(statusText: String) -> Self {
        Self(
            fiveHour: nil,
            weekly: .init(
                title: "每周",
                remainingText: "—",
                progress: nil,
                level: .stale,
                accessibilityLabel: "每周剩余额度",
                accessibilityValue: "—"
            ),
            statusText: statusText
        )
    }

    private static func ring(title: String, remainingPercent: Int) -> FloatingQuotaRingPresentation {
        let clampedPercent = min(100, max(0, remainingPercent))
        let remainingText = "\(clampedPercent)%"
        return .init(
            title: title,
            remainingText: remainingText,
            progress: Double(clampedPercent) / 100,
            level: .level(forRemaining: clampedPercent),
            accessibilityLabel: "\(title)剩余额度",
            accessibilityValue: remainingText
        )
    }
}
