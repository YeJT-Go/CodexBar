import AppKit
import SwiftUI

struct MenuBarWindowPresentation: Equatable, Sendable {
    let title: String
    let remainingText: String
    let resetText: String
}

struct MenuBarPresentation: Equatable, Sendable {
    let label: String
    let fiveHour: MenuBarWindowPresentation?
    let weekly: MenuBarWindowPresentation
    let fiveHourLevel: UsageLevel
    let weeklyLevel: UsageLevel
    let connectionText: String
    let warningText: String?
    let showsWarning: Bool

    var accentLevel: UsageLevel { fiveHour == nil ? weeklyLevel : fiveHourLevel }

    static func make(from state: UsageState) -> Self {
        switch state {
        case .loading:
            return missing(
                label: "周 --",
                connectionText: "正在连接…",
                warningText: nil
            )
        case let .current(snapshot):
            return snapshotPresentation(
                snapshot,
                stale: false,
                connectionText: "已连接",
                warningText: nil
            )
        case let .stale(snapshot, message):
            return snapshotPresentation(
                snapshot,
                stale: true,
                connectionText: "数据已过期",
                warningText: message
            )
        case let .unavailable(message):
            return missing(
                label: "⚠ 周 --",
                connectionText: "不可用",
                warningText: message
            )
        }
    }

    private static func snapshotPresentation(
        _ snapshot: UsageSnapshot,
        stale: Bool,
        connectionText: String,
        warningText: String?
    ) -> Self {
        let fiveHour = snapshot.fiveHour.map { window(title: "5 小时", value: $0) }
        let weekly = window(title: "每周", value: snapshot.weekly)
        let prefix = stale ? "⚠ " : ""
        return Self(
            label: prefix + (snapshot.fiveHour.map { "5h \($0.remainingPercent)% · " } ?? "") + "周 \(snapshot.weekly.remainingPercent)%",
            fiveHour: fiveHour,
            weekly: weekly,
            fiveHourLevel: stale ? .stale : snapshot.fiveHour.map { .level(forRemaining: $0.remainingPercent) } ?? .stale,
            weeklyLevel: stale ? .stale : .level(forRemaining: snapshot.weekly.remainingPercent),
            connectionText: connectionText,
            warningText: warningText,
            showsWarning: warningText != nil
        )
    }

    private static func missing(
        label: String,
        connectionText: String,
        warningText: String?
    ) -> Self {
        Self(
            label: label,
            fiveHour: nil,
            weekly: .init(title: "每周", remainingText: "--", resetText: "未知"),
            fiveHourLevel: .stale,
            weeklyLevel: .stale,
            connectionText: connectionText,
            warningText: warningText,
            showsWarning: warningText != nil
        )
    }

    private static func window(title: String, value: UsageWindow) -> MenuBarWindowPresentation {
        .init(
            title: title,
            remainingText: "\(value.remainingPercent)%",
            resetText: value.resetsAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知"
        )
    }
}

struct MenuBarLabel: View {
    let presentation: MenuBarPresentation

    var body: some View {
        // A non-template image preserves quota colors in the macOS status bar.
        if let image = renderedLabel {
            Image(nsImage: image)
                .renderingMode(.original)
                .accessibilityLabel(presentation.label)
        } else {
            labelContent
        }
    }

    @MainActor private var renderedLabel: NSImage? {
        let renderer = ImageRenderer(content: labelContent.fixedSize())
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }

    private var labelContent: some View {
        HStack(spacing: 5) {
            if presentation.showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityLabel("用量数据异常")
            }
            Circle()
                .fill(presentation.accentLevel.color)
                .frame(width: 6, height: 6)
            Text(presentation.label.replacingOccurrences(of: "⚠ ", with: ""))
                .monospacedDigit()
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(presentation.accentLevel.color)
    }
}

struct MenuBarView: View {
    @ObservedObject var model: UsageViewModel
    @StateObject private var loginItem: LoginItemController
    let lifecycle: AppLifecycleCoordinator

    init(
        model: UsageViewModel,
        loginItems: any LoginItemManaging,
        lifecycle: AppLifecycleCoordinator
    ) {
        self.model = model
        self.lifecycle = lifecycle
        _loginItem = StateObject(wrappedValue: LoginItemController(manager: loginItems))
    }

    var body: some View {
        let presentation = MenuBarPresentation.make(from: model.state)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let fiveHour = presentation.fiveHour {
                    UsageCard(value: fiveHour, level: presentation.fiveHourLevel)
                }
                UsageCard(value: presentation.weekly, level: presentation.weeklyLevel)
            }

            Divider()

            Label(presentation.connectionText, systemImage: presentation.showsWarning
                  ? "exclamationmark.triangle.fill" : "bolt.horizontal.circle")
                .foregroundStyle(presentation.showsWarning ? Color.secondary : Color.primary)

            if let warning = presentation.warningText {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await model.refresh() }
            } label: {
                HStack(spacing: 8) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(model.isRefreshing ? "正在刷新…" : "立即刷新")
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(presentation.accentLevel.color)
            .disabled(model.isRefreshing)

            Text(model.refreshFeedback ?? "等待刷新")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("登录时自动启动", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))

            if let error = loginItem.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("退出 CodexBar") {
                Task { await lifecycle.quit() }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 330)
        .background(presentation.accentLevel.color.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(presentation.accentLevel.color.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onAppear { loginItem.synchronize() }
    }
}

private struct UsageCard: View {
    let value: MenuBarWindowPresentation
    let level: UsageLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.remainingText)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(level.color)
            Text("重置：\(value.resetText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension UsageLevel {
    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        case .stale: .gray
        }
    }
}
