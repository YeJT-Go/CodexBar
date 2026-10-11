import SwiftUI

struct FloatingQuotaCardView: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        FloatingQuotaCardContent(
            presentation: .make(from: model.state)
        )
    }
}

struct FloatingQuotaCardContent: View {
    let presentation: FloatingQuotaCardPresentation

    var body: some View {
        VStack(spacing: 14) {
            FloatingQuotaRingView(presentation: fiveHourPresentation)
            FloatingQuotaRingView(presentation: presentation.weekly)

            if let statusText = presentation.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 148)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fiveHourPresentation: FloatingQuotaRingPresentation {
        presentation.fiveHour ?? .init(
            title: "5 小时",
            remainingText: "—",
            progress: nil,
            level: .stale,
            accessibilityLabel: "5 小时剩余额度",
            accessibilityValue: "—"
        )
    }
}

private struct FloatingQuotaRingView: View {
    let presentation: FloatingQuotaRingPresentation

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.12), lineWidth: 8)

            if let progress = presentation.progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        presentation.level.color,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 2) {
                Text(presentation.remainingText)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                Text(presentation.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 82, height: 82)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(presentation.accessibilityLabel))
        .accessibilityValue(Text(presentation.accessibilityValue))
    }
}

private extension FloatingQuotaLevel {
    var color: Color {
        switch self {
        case .healthy:
            .green
        case .warning:
            .orange
        case .critical:
            .red
        case .stale:
            .secondary
        }
    }
}
