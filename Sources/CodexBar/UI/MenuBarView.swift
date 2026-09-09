import AppKit
import SwiftUI

struct MenuBarWindowPresentation: Equatable, Sendable {
    let title: String
    let remainingText: String
    let resetText: String
}

struct MenuBarPresentation: Equatable, Sendable {
    let label: String
    let fiveHour: MenuBarWindowPresentation
    let weekly: MenuBarWindowPresentation
    let fiveHourLevel: UsageLevel
    let weeklyLevel: UsageLevel
    let connectionText: String
    let warningText: String?
    let showsWarning: Bool

    static func make(from state: UsageState) -> Self {
        switch state {
        case .loading:
            return missing(
                label: "5h -- · 周 --",
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
                label: "⚠ 5h -- · 周 --",
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
        let fiveHour = window(title: "5 小时", value: snapshot.fiveHour)
        let weekly = window(title: "每周", value: snapshot.weekly)
        let prefix = stale ? "⚠ " : ""
        return Self(
            label: "\(prefix)5h \(snapshot.fiveHour.remainingPercent)% · 周 \(snapshot.weekly.remainingPercent)%",
            fiveHour: fiveHour,
            weekly: weekly,
            fiveHourLevel: stale ? .stale : .level(forRemaining: snapshot.fiveHour.remainingPercent),
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
            fiveHour: .init(title: "5 小时", remainingText: "--", resetText: "未知"),
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
        HStack(spacing: 5) {
            if presentation.showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityLabel("用量数据异常")
            }
            Circle()
                .fill(presentation.fiveHourLevel.color)
                .frame(width: 6, height: 6)
            Circle()
                .fill(presentation.weeklyLevel.color)
                .frame(width: 6, height: 6)
            Text(presentation.label.replacingOccurrences(of: "⚠ ", with: ""))
                .monospacedDigit()
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: UsageViewModel
    @StateObject private var loginItem: LoginItemController

    init(model: UsageViewModel, loginItems: any LoginItemManaging) {
        self.model = model
        _loginItem = StateObject(wrappedValue: LoginItemController(manager: loginItems))
    }

    var body: some View {
        let presentation = MenuBarPresentation.make(from: model.state)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                UsageCard(value: presentation.fiveHour, level: presentation.fiveHourLevel)
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
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

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
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 330)
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
