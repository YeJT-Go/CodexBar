import Foundation

enum RateLimitParseError: Error, Equatable {
    case missingWindow
}

struct RateLimitParser: Sendable {
    func parse(_ response: RateLimitsResponse, now: Date = Date()) throws -> UsageSnapshot {
        let snapshot = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        guard let weekly = window(for: 10_080, in: snapshot) else {
            throw RateLimitParseError.missingWindow
        }

        return UsageSnapshot(
            fiveHour: window(for: 300, in: snapshot).map(usageWindow(from:)),
            weekly: usageWindow(from: weekly),
            fetchedAt: now
        )
    }

    private func window(for duration: Int, in snapshot: RateLimitSnapshotDTO) -> RateLimitWindowDTO? {
        let windows = [snapshot.primary, snapshot.secondary]
        if let exact = windows.compactMap({ $0 }).first(where: { $0.windowDurationMins == duration }) {
            return exact
        }

        // A missing duration is the only case where the endpoint's positional
        // primary/secondary convention is used as a fallback.
        if duration == 300, let primary = snapshot.primary, primary.windowDurationMins == nil {
            return primary
        }
        if duration == 10_080, let secondary = snapshot.secondary, secondary.windowDurationMins == nil {
            return secondary
        }
        return nil
    }

    private func usageWindow(from dto: RateLimitWindowDTO) -> UsageWindow {
        UsageWindow(
            remainingPercent: UsageWindow.remaining(fromUsed: dto.usedPercent),
            resetsAt: dto.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
