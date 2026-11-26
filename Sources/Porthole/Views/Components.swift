import AppKit
import PortholeCore
import SwiftUI

// MARK: - Colors

extension TunnelState {
    var color: Color {
        switch self {
        case .off: return Color.secondary.opacity(0.55)
        case .connecting, .disconnecting: return .orange
        case .waitingForUser: return .blue
        case .connected: return .green
        case .reconnecting: return .orange
        case .failed: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "power"
        case .connecting, .disconnecting: return "arrow.triangle.2.circlepath"
        case .waitingForUser: return "key.fill"
        case .connected: return "checkmark"
        case .reconnecting: return "arrow.clockwise"
        case .failed: return "exclamationmark"
        }
    }
}

extension ForwardingKind {
    var tint: Color {
        switch self {
        case .local: return .blue
        case .remote: return .purple
        case .dynamic: return .teal
        }
    }

    var shortLabel: String {
        switch self {
        case .local: return "L"
        case .remote: return "R"
        case .dynamic: return "D"
        }
    }

    /// Which way connections go: out from this Mac, back to it, or anywhere.
    var badgeSymbol: String {
        switch self {
        case .local: return "arrow.right"
        case .remote: return "arrow.left"
        case .dynamic: return "globe"
        }
    }
}

extension Forwarding {
    /// The rule's name in lists: its note, or what kind of forward it is.
    var displayTitle: String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? String(localized: "\(kind.title) forwarding") : note
    }
}

extension ForwardStatus {
    var color: Color {
        switch self {
        case .idle: return Color.secondary.opacity(0.4)
        case .pending: return .orange
        case .active: return .green
        case .failed: return .red
        }
    }

    var label: String {
        switch self {
        case .idle: return String(localized: "Inactive")
        case .pending: return String(localized: "Starting")
        case .active: return String(localized: "Active")
        case .failed: return String(localized: "Failed")
        }
    }
}

// MARK: - Status indicator

struct StatusDot: View {
    var state: TunnelState
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if state.isBusy && !reduceMotion {
                // A Core Animation ripple: it can't pick up layout changes and drift around the
                // window the way a repeating SwiftUI animation can, and it costs no frames here.
                PulsingRing(color: state.color, opacity: 0.55, lineWidth: 1.5)
                    .frame(width: size * 2, height: size * 2)
            }
            Circle()
                .fill(state.color)
                .frame(width: size, height: size)
                .shadow(color: state == .connected ? Color.green.opacity(0.5) : .clear, radius: 2.5)
        }
        .frame(width: size * 2, height: size * 2)
    }
}

struct StatusPill: View {
    var runtime: TunnelRuntime?
    var state: TunnelState { runtime?.state ?? .off }

    var body: some View {
        HStack(spacing: 6) {
            if state.isBusy && state != .waitingForUser {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(state.color).frame(width: 7, height: 7)
            }
            label
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(state.color.opacity(state == .off ? 0.10 : 0.13), in: Capsule())
        .foregroundStyle(state == .off ? Color.secondary : state.color)
    }

    /// Only a running clock or a countdown needs ticking; each tick lays the window out again.
    @ViewBuilder
    var label: some View {
        if state == .connected, let since = runtime?.connectedSince {
            TimelineView(ElapsedTimeSchedule(since: since)) { context in
                Text(text(now: context.date)).monospacedDigit()
            }
        } else if case .reconnecting = state {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(text(now: context.date)).monospacedDigit()
            }
        } else {
            Text(text(now: Date())).monospacedDigit()
        }
    }

    func text(now: Date) -> String {
        switch state {
        case .connected:
            if let since = runtime?.connectedSince {
                let elapsed = Self.duration(now.timeIntervalSince(since))
                return String(localized: "Connected · \(elapsed)")
            }
            return String(localized: "Connected")
        case .reconnecting(let attempt, let at):
            let s = max(0, Int(at.timeIntervalSince(now).rounded(.up)))
            return s > 0 ? String(localized: "Reconnecting in \(s) s · attempt \(attempt)") : String(localized: "Reconnecting…")
        case .failed:
            return String(localized: "Connection failed")
        default:
            return state.title
        }
    }

    /// Localized "2h 13m" style duration, two most significant units.
    static func duration(_ t: TimeInterval) -> String {
        durationFormatter.string(from: max(0, t.rounded(.down))) ?? ""
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        return f
    }()
}

/// Ticks when an elapsed-time label can change: every second for the first hour, then every
/// minute, then every hour (the label shows its two largest units, e.g. "2h 13m").
struct ElapsedTimeSchedule: TimelineSchedule {
    var since: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let current = next
            let elapsed = max(0, current.timeIntervalSince(since))
            let step: TimeInterval = elapsed < 3_600 ? 1 : (elapsed < 86_400 ? 60 : 3_600)
            next = since.addingTimeInterval((floor(elapsed / step) + 1) * step)
            return current
        }
    }
}

// MARK: - Row switch

/// A small on/off switch for sidebar rows.
///
/// The system switch fills with the accent color, which disappears on a selected sidebar row
/// (that row is filled with the accent color too). On an emphasized row this switch flips its
/// colors: when on, a solid white track with an accent knob; when off, a faint white track.
struct RowSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowSwitch(configuration: configuration)
    }
}

private struct RowSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private let size = CGSize(width: 30, height: 17)
    private let inset: CGFloat = 2

    var body: some View {
        let on = configuration.isOn
        let emphasized = prominence == .increased
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(track(on: on, emphasized: emphasized))
                Capsule()
                    .strokeBorder(edge(on: on, emphasized: emphasized), lineWidth: 0.5)
                Circle()
                    .fill(knob(on: on, emphasized: emphasized))
                    .shadow(color: .black.opacity(emphasized ? 0.12 : 0.22), radius: 0.8, y: 0.5)
                    .padding(inset)
            }
            .frame(width: size.width, height: size.height)
            .animation(.snappy(duration: 0.18), value: on)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func track(on: Bool, emphasized: Bool) -> Color {
        switch (on, emphasized) {
        case (true, false): return .accentColor
        case (true, true): return .white
        case (false, false): return Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.11)
        case (false, true): return Color.white.opacity(0.24)
        }
    }

    private func edge(on: Bool, emphasized: Bool) -> Color {
        if emphasized { return on ? .clear : Color.white.opacity(0.35) }
        return on ? .clear : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }

    private func knob(on: Bool, emphasized: Bool) -> Color {
        if emphasized && on { return .accentColor }
        return colorScheme == .dark && !emphasized && !on ? Color(white: 0.85) : .white
    }
}

// MARK: - Tunnel badge

/// The porthole: a ring with the state's symbol, on a soft tint of the state's color.
struct TunnelBadge: View {
    var state: TunnelState
    var size: CGFloat = 44
    /// Overrides the state color, e.g. for the editor, which isn't about a live state.
    var tint: Color?

    var body: some View {
        let color = tint ?? badgeColor
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.surface)
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(color.opacity(0.14))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 1)
            Circle()
                .strokeBorder(color, lineWidth: max(1.5, size * 0.055))
                .frame(width: size * 0.56, height: size * 0.56)
            Image(systemName: tint != nil || state == .connected ? "arrow.right" : state.symbolName)
                .font(.system(size: size * 0.22, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    var badgeColor: Color {
        switch state {
        case .off: return .secondary
        case .connected: return .green
        default: return state.color
        }
    }
}

// MARK: - Flow layout

/// Lays children out left to right and wraps onto new lines, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, systemImage: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(alignment: .center, spacing: 7) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    trailing
                }
                .frame(minHeight: 20)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

struct KindBadge: View {
    var kind: ForwardingKind

    var size: CGFloat = 26

    var body: some View {
        Image(systemName: kind.badgeSymbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(kind.tint)
            .frame(width: size, height: size)
            .background(kind.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .help(String(localized: "\(kind.title) forwarding"))
    }
}

struct CopyButton: View {
    var value: String
    var help: String = String(localized: "Copy")
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 14)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct InfoRow: View {
    var label: LocalizedStringKey
    var value: String
    var monospaced = false
    var copyable = false

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            HStack(spacing: 6) {
                Text(value)
                    .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .textSelection(.enabled)
                    .lineLimit(2)
                if copyable && !value.isEmpty { CopyButton(value: value) }
            }
            .gridColumnAlignment(.leading)
        }
    }
}

extension LogLevel {
    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var symbol: String {
        switch self {
        case .debug: return "ant"
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct LogLineView: View {
    var entry: LogEntry
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.date))
                .foregroundStyle(.tertiary)
            Image(systemName: entry.level.symbol)
                .foregroundStyle(entry.level.color)
                .font(.system(size: 10))
                .frame(width: 12)
            Text(entry.message)
                .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
    }
}
