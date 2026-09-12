import AppKit
import SwiftUI

enum UsageAppearance: Equatable, Sendable {
    case light
    case dark

    init(colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }
}

enum UsageColorToken: Equatable, Sendable {
    case systemGreen
    case deepGold
    case systemYellow
    case systemRed
    case systemGray

    static func make(for level: UsageLevel, appearance: UsageAppearance) -> Self {
        switch level {
        case .healthy:
            return .systemGreen
        case .warning:
            return appearance == .light ? .deepGold : .systemYellow
        case .critical:
            return .systemRed
        case .stale:
            return .systemGray
        }
    }
}

struct MenuBarWindowPresentation: Equatable, Sendable {
    let title: String
    let remainingText: String
    let remainingPercent: Int?
    let resetText: String
}

struct TokenUsagePresentation: Equatable, Sendable {
    let valueText: String
    let warningText: String?

    static func make(
        from state: TokenUsageState,
        locale: Locale = .current
    ) -> Self {
        switch state {
        case .loading:
            return .init(valueText: "--", warningText: nil)
        case let .current(usage):
            return .init(valueText: formattedValue(usage.tokens, locale: locale), warningText: nil)
        case let .stale(usage, message):
            return .init(valueText: formattedValue(usage.tokens, locale: locale), warningText: message)
        case let .unavailable(message):
            return .init(valueText: "--", warningText: message)
        }
    }

    private static func formattedValue(_ tokens: Int64, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: tokens)) ?? String(tokens)
        return "\(number) tokens"
    }
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
            weekly: .init(
                title: "每周",
                remainingText: "--",
                remainingPercent: nil,
                resetText: "未知"
            ),
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
            remainingPercent: value.remainingPercent,
            resetText: value.resetsAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知"
        )
    }
}

struct MenuBarLabel: View {
    let presentation: MenuBarPresentation
    @Environment(\.colorScheme) private var colorScheme

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
        let accentColor = UsageColorToken.make(
            for: presentation.accentLevel,
            appearance: UsageAppearance(colorScheme: colorScheme)
        ).color

        return HStack(spacing: 5) {
            if presentation.showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityLabel("用量数据异常")
            }
            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)
            Text(presentation.label.replacingOccurrences(of: "⚠ ", with: ""))
                .monospacedDigit()
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(accentColor)
    }
}

struct MenuBarView: View {
    @ObservedObject var model: UsageViewModel
    @StateObject private var loginItem: LoginItemController
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
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
        let tokenPresentation = TokenUsagePresentation.make(
            from: model.tokenState,
            locale: locale
        )
        let appearance = UsageAppearance(colorScheme: colorScheme)
        let accentColor = UsageColorToken.make(
            for: presentation.accentLevel,
            appearance: appearance
        ).color

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CodexBar")
                        .font(.headline)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 7, height: 7)
                        Text(model.refreshFeedback ?? presentation.connectionText)
                            .lineLimit(2)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                Button {
                    Task { await model.refresh() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(model.isRefreshing ? "刷新中…" : "刷新")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isRefreshing)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("今日使用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tokenPresentation.valueText)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                if let warning = tokenPresentation.warningText {
                    InlineWarning(text: warning)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                if let fiveHour = presentation.fiveHour {
                    QuotaRow(
                        value: fiveHour,
                        level: presentation.fiveHourLevel,
                        appearance: appearance
                    )
                    Divider()
                }
                QuotaRow(
                    value: presentation.weekly,
                    level: presentation.weeklyLevel,
                    appearance: appearance
                )
            }

            if let warning = presentation.warningText {
                InlineWarning(text: warning)
            }

            Divider()

            HStack(spacing: 16) {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                Spacer(minLength: 0)
                Button("退出 CodexBar") {
                    Task { await lifecycle.quit() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
            }

            if let error = loginItem.errorMessage {
                InlineWarning(text: error, color: .red)
            }
        }
        .padding(18)
        .frame(width: 350)
        .onAppear { loginItem.synchronize() }
    }
}

private struct QuotaRow: View {
    let value: MenuBarWindowPresentation
    let level: UsageLevel
    let appearance: UsageAppearance

    var body: some View {
        let accentColor = UsageColorToken.make(for: level, appearance: appearance).color

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(value.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(value.remainingText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(accentColor)
            }

            ProgressView(value: Double(value.remainingPercent ?? 0), total: 100)
                .progressViewStyle(.linear)
                .tint(accentColor)
                .accessibilityLabel("\(value.title)剩余额度")
                .accessibilityValue(value.remainingText)

            Text("重置：\(value.resetText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct InlineWarning: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension UsageColorToken {
    var color: Color {
        switch self {
        case .systemGreen:
            .green
        case .deepGold:
            Color(red: 154 / 255, green: 103 / 255, blue: 0)
        case .systemYellow:
            .yellow
        case .systemRed:
            .red
        case .systemGray:
            .gray
        }
    }
}
