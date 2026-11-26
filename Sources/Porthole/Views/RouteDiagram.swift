import PortholeCore
import SwiftUI

/// Where a tunnel's traffic goes, drawn as a bow tie. Every forwarding rule has its own lane;
/// all lanes squeeze into the one encrypted SSH connection between this Mac and the server,
/// then fan out again on the far side:
///
///                     This Mac                              bastion.acme.io
///     localhost:15432 ─╮                                   ╭─▶ pg.internal:5432
///     localhost:16379 ─┼──( 💻 )═════════ 🔒 ═════════( 🗄 )──┼─▶ redis.internal:6379
///     SOCKS :1080     ─╯           Encrypted SSH           ╰─▶ 🌐 Any website or host
///
/// Left of this Mac are addresses on the Mac's side, right of the server addresses on the
/// server's side. A filled chip is where connections enter (the listening port), an outlined
/// chip is where they end up. While a rule is live, dots travel its lane in the direction
/// traffic flows.
struct RouteDiagram: View, Equatable {
    enum Style {
        /// Colored by live status.
        case live
        /// Editor preview: every enabled rule in its kind color, flowing the way a live rule does.
        case preview
    }

    /// Only the parts of the tunnel the drawing shows, so an unchanged diagram compares equal
    /// (the editor skips redrawing the other rules' previews while you type).
    var host: String
    var proxy: ProxySettings
    var forwardings: [Forwarding]
    var state: TunnelState
    var statuses: [UUID: ForwardStatus]
    var style: Style
    var compact: Bool
    var maxLanes: Int

    init(tunnel: Tunnel, forwardings: [Forwarding], state: TunnelState = .off, statuses: [UUID: ForwardStatus] = [:],
         style: Style = .live, compact: Bool = false, maxLanes: Int = 8) {
        host = tunnel.host
        proxy = tunnel.proxy
        self.forwardings = forwardings
        self.state = state
        self.statuses = statuses
        self.style = style
        self.compact = compact
        self.maxLanes = maxLanes
    }

    var body: some View {
        let all = forwardings.map { Lane(forwarding: $0, look: look(for: $0)) }
        let lanes = Array(all.prefix(maxLanes))
        VStack(spacing: 10) {
            if compact {
                diagram(lanes, .compact)
            } else {
                ViewThatFits(in: .horizontal) {
                    diagram(lanes, .regular)
                    diagram(lanes, .compact)
                    diagram(lanes, .compact, shortLocal: true)
                }
            }
            if all.count > lanes.count {
                Text("+\(all.count - lanes.count) more…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, compact ? 12 : 18)
        .padding(.vertical, compact ? 12 : 16)
        .frame(maxWidth: .infinity)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(forwardings.map { $0.explanation(serverName: serverName) }.joined(separator: " "))
    }

    // MARK: Model

    struct Lane {
        var forwarding: Forwarding
        var look: LaneLook
        /// Traffic enters on the Mac's side and leaves on the server's side.
        var flowsRight: Bool { forwarding.kind != .remote }
    }

    enum LaneLook: Equatable {
        case planned, idle, disabled, pending, active, failed
        var isMoving: Bool { self == .planned || self == .active || self == .pending }
        var isMuted: Bool { self == .idle || self == .disabled }
    }

    func look(for f: Forwarding) -> LaneLook {
        guard f.enabled else { return .disabled }
        if style == .preview { return .planned }
        switch statuses[f.id] ?? .idle {
        case .active: return .active
        case .pending: return .pending
        case .failed: return .failed
        case .idle: return state.isBusy ? .pending : .idle
        }
    }

    func color(_ lane: Lane) -> Color {
        switch lane.look {
        case .planned, .active: return lane.forwarding.kind.tint
        case .pending: return .orange
        case .failed: return .red
        case .idle, .disabled: return Theme.idle
        }
    }

    /// The SSH connection takes the color of the tunnel's state.
    var tubeColor: Color {
        if style == .preview { return Theme.sea }
        switch state {
        case .connected: return .green
        case .failed: return .red
        case .off: return Theme.idle
        default: return .orange
        }
    }

    var tubeIsDown: Bool {
        guard style == .live else { return false }
        switch state {
        case .off, .failed: return true
        default: return false
        }
    }

    var serverName: String {
        let host = host.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? String(localized: "the SSH server") : host
    }

    var viaName: String? {
        guard proxy.kind != .none else { return nil }
        let host = proxy.host.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? proxy.kind.title : host
    }

    // MARK: Drawing

    /// `shortLocal` drops "localhost" from addresses, keeping just the port, for very narrow windows.
    func diagram(_ lanes: [Lane], _ m: RouteMetrics, shortLocal: Bool = false) -> some View {
        let showVia = !m.compact && viaName != nil
        let g = RouteGeometry(m: m, laneCount: lanes.count, captionLines: showVia ? 2 : 1)
        return RouteLayout(m: m, g: g, flowsRight: lanes.map(\.flowsRight)) {
            TubeView(color: tubeColor, down: tubeIsDown)
                .layoutValue(key: SlotKey.self, value: .tube)

            ForEach(Array(lanes.enumerated()), id: \.element.forwarding.id) { i, lane in
                let c = color(lane)
                let y = g.laneY(i), inside = g.cy + g.tubeOffset(i, of: lanes.count)
                let stagger = CGFloat(i) / CGFloat(max(lanes.count, 1))
                LaneStroke(shape: LaneCurve(fromY: y, toY: inside, straightEnd: m.node / 2), color: c, look: lane.look, m: m)
                    .layoutValue(key: SlotKey.self, value: .macFan(i))
                LaneStroke(shape: LaneCurve(fromY: inside, toY: inside), color: c, look: lane.look, inTube: true, m: m)
                    .layoutValue(key: SlotKey.self, value: .tubeLane(i))
                LaneStroke(shape: LaneCurve(fromY: inside, toY: y, straightStart: m.node / 2), color: c, look: lane.look, m: m)
                    .layoutValue(key: SlotKey.self, value: .serverFan(i))
                LanePulses(path: LanePath(chipY: y, tubeY: inside, fan: m.laneFan, straight: m.node / 2),
                           color: c, look: lane.look, forward: lane.flowsRight, stagger: stagger, m: m)
                    .layoutValue(key: SlotKey.self, value: .pulses(i))
                ArrowHead(pointsRight: lane.flowsRight, color: c, look: lane.look, m: m)
                    .layoutValue(key: SlotKey.self, value: .arrow(i))
            }

            RouteNode(symbol: "laptopcomputer", m: m)
                .layoutValue(key: SlotKey.self, value: .macNode)
            RouteNode(symbol: "server.rack", m: m)
                .layoutValue(key: SlotKey.self, value: .serverNode)
            LockBadge(color: tubeColor, failed: style == .live && isFailed, m: m)
                .layoutValue(key: SlotKey.self, value: .badge)

            ForEach(Array(lanes.enumerated()), id: \.element.forwarding.id) { i, lane in
                macSide(lane, m, short: shortLocal)
                    .help(lane.forwarding.explanation(serverName: serverName))
                    .layoutValue(key: SlotKey.self, value: .macItem(i))
                serverSide(lane, m, short: shortLocal)
                    .help(lane.forwarding.explanation(serverName: serverName))
                    .layoutValue(key: SlotKey.self, value: .serverItem(i))
            }
            if lanes.isEmpty {
                Text("No forwarding rules yet.")
                    .font(.system(size: m.title, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutValue(key: SlotKey.self, value: .serverItem(0))
            }

            Text("This Mac")
                .font(.system(size: m.title, weight: .semibold))
                .lineLimit(1)
                .layoutValue(key: SlotKey.self, value: .macTitle)
            serverTitle(m)
                .layoutValue(key: SlotKey.self, value: .serverTitle)
            caption(m, showVia: showVia)
                .layoutValue(key: SlotKey.self, value: .caption)
        }
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    func serverTitle(_ m: RouteMetrics) -> some View {
        let host = host.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 1) {
            Text(host.isEmpty ? String(localized: "SSH server") : host)
                .font(.system(size: m.title, weight: .semibold))
            if !m.compact, !host.isEmpty {
                Text("SSH server")
                    .font(.system(size: m.subtitle))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .help(host)
    }

    func caption(_ m: RouteMetrics, showVia: Bool) -> some View {
        VStack(spacing: 1) {
            Group {
                if m.compact {
                    Text(verbatim: "SSH")
                } else {
                    Text("Encrypted SSH")
                }
            }
            .font(.system(size: m.caption, weight: .medium))
            .foregroundStyle(.secondary)
            if showVia, let via = viaName {
                Text("via \(via)")
                    .font(.system(size: m.caption - 0.5))
                    .foregroundStyle(.tertiary)
                    .help(proxy.kind.title)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// What sits left of this Mac: where local and SOCKS connections enter, or where a
    /// remote forward delivers them.
    @ViewBuilder
    func macSide(_ lane: Lane, _ m: RouteMetrics, short: Bool) -> some View {
        let f = lane.forwarding
        switch f.kind {
        case .local:
            AddressChip(address: shorten(f.listenDisplayAddress, short), role: .entry, color: color(lane), look: lane.look, m: m)
        case .dynamic:
            AddressChip(address: shorten(f.listenDisplayAddress, short), role: .entry, color: color(lane), look: lane.look, m: m, tag: "SOCKS")
        case .remote:
            AddressChip(address: shorten(f.targetDisplayAddress, short), role: .exit, color: color(lane), look: lane.look, m: m)
        }
    }

    /// `localhost:15432` → `:15432`; the column header already says which machine it is.
    func shorten(_ address: String, _ short: Bool) -> String {
        guard short else { return address }
        for host in ["localhost:", "127.0.0.1:"] where address.hasPrefix(host) {
            return String(address.dropFirst(host.count - 1))
        }
        return address
    }

    /// What sits right of the server: where traffic ends up, or where a remote forward listens.
    @ViewBuilder
    func serverSide(_ lane: Lane, _ m: RouteMetrics, short: Bool) -> some View {
        let f = lane.forwarding
        switch f.kind {
        case .local:
            AddressChip(address: f.targetDisplayAddress, role: .exit, color: color(lane), look: lane.look, m: m)
        case .dynamic:
            AddressChip(label: String(localized: "Any website or host"), symbol: "globe", color: color(lane), look: lane.look, m: m)
        case .remote:
            HStack(spacing: 8) {
                AddressChip(address: shorten(remoteListenAddress(f), short), role: .entry, color: color(lane), look: lane.look, m: m)
                if !m.compact {
                    Label(remoteVisitors(f), systemImage: "person.2")
                        .font(.system(size: m.subtitle))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
        }
    }

    func remoteListenAddress(_ f: Forwarding) -> String {
        f.bindAddress.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost:\(f.port)" : f.listenDisplayAddress
    }

    /// Who can open a remote forward: by default the server only listens on its loopback interface.
    func remoteVisitors(_ f: Forwarding) -> String {
        switch f.bindAddress.trimmingCharacters(in: .whitespaces) {
        case "", "localhost", "127.0.0.1", "::1", "[::1]":
            return String(localized: "Programs on the server")
        default:
            return String(localized: "Anyone who can reach the server")
        }
    }
}

// MARK: - Metrics & geometry

struct RouteMetrics {
    var compact: Bool
    /// Address chips.
    var chipFont: CGFloat, chipHeight: CGFloat, chipPadding: CGFloat
    /// Distance between lanes.
    var pitch: CGFloat
    /// Diameter of the Mac and server nodes.
    var node: CGFloat
    /// Horizontal room for lanes to curve from the chips into a node.
    var fan: CGFloat
    var tubeMin: CGFloat, tubeMax: CGFloat, tubeHeight: CGFloat
    var badge: CGFloat
    var line: CGFloat, dot: CGFloat, arrow: CGFloat
    var title: CGFloat, subtitle: CGFloat
    /// Room above the lanes for the node titles.
    var header: CGFloat, headerGap: CGFloat
    var caption: CGFloat, captionGap: CGFloat, captionLine: CGFloat
    /// Address columns shrink to `columnMin` before the layout gives up, and never grow past `columnMax`.
    var columnMin: CGFloat, columnMax: CGFloat
    /// Gap between a lane's end and its chip.
    var endGap: CGFloat

    /// Width of the part of a lane between its chip and the center of a node.
    var laneFan: CGFloat { fan + node / 2 - endGap }

    static let regular = RouteMetrics(
        compact: false, chipFont: 11.5, chipHeight: 24, chipPadding: 8, pitch: 34, node: 40, fan: 58,
        tubeMin: 110, tubeMax: 300, tubeHeight: 14, badge: 20, line: 1.5, dot: 2.5, arrow: 4.5,
        title: 12, subtitle: 10.5, header: 30, headerGap: 14, caption: 11, captionGap: 8, captionLine: 14,
        columnMin: 96, columnMax: 300, endGap: 4)

    static let compact = RouteMetrics(
        compact: true, chipFont: 10.5, chipHeight: 20, chipPadding: 6, pitch: 26, node: 30, fan: 36,
        tubeMin: 48, tubeMax: 220, tubeHeight: 10, badge: 16, line: 1.5, dot: 2, arrow: 3.5,
        title: 11, subtitle: 10, header: 14, headerGap: 10, caption: 10, captionGap: 5, captionLine: 12,
        columnMin: 72, columnMax: 200, endGap: 3)
}

/// The vertical half of the layout. It doesn't depend on the width, so the lane shapes can use it directly.
struct RouteGeometry {
    var m: RouteMetrics
    var laneCount: Int
    var captionLines: Int

    var laneSpan: CGFloat { CGFloat(max(laneCount, 1) - 1) * m.pitch }
    var above: CGFloat { max(laneSpan / 2 + m.chipHeight / 2, m.node / 2) }
    var below: CGFloat {
        max(laneSpan / 2 + m.chipHeight / 2, m.node / 2,
            m.tubeHeight / 2 + m.captionGap + CGFloat(captionLines) * m.captionLine)
    }
    /// The middle of the SSH connection.
    var cy: CGFloat { m.header + m.headerGap + above }
    var height: CGFloat { cy + below }

    func laneY(_ i: Int) -> CGFloat { cy - laneSpan / 2 + CGFloat(i) * m.pitch }

    /// Lanes run side by side inside the SSH connection, like fibres in a cable.
    func tubeOffset(_ i: Int, of n: Int) -> CGFloat {
        guard n > 1 else { return 0 }
        let spacing = min(3.5, (m.tubeHeight - 5) / CGFloat(n - 1))
        return (CGFloat(i) - CGFloat(n - 1) / 2) * spacing
    }
}

private enum Slot: Hashable {
    case tube, tubeLane(Int), macFan(Int), serverFan(Int), pulses(Int), arrow(Int)
    case macNode, serverNode, badge
    case macItem(Int), serverItem(Int)
    case macTitle, serverTitle, caption
}

private struct SlotKey: LayoutValueKey {
    static let defaultValue: Slot? = nil
}

/// Places the pieces of the bow tie. Address columns size to their longest chip; the SSH
/// connection in the middle takes what's left, within limits, and the whole drawing is centered.
private struct RouteLayout: Layout {
    var m: RouteMetrics
    var g: RouteGeometry
    var flowsRight: [Bool]

    struct Columns {
        var mac: CGFloat
        var server: CGFloat
        var tube: CGFloat
        var total: CGFloat { mac + server + 2 * m.fan + 2 * m.node + tube }
        var m: RouteMetrics
    }

    /// The widest chip on each side. SwiftUI rebuilds it whenever the subviews change.
    struct Cache {
        var mac: CGFloat
        var server: CGFloat
    }

    func makeCache(subviews: Subviews) -> Cache {
        var mac: CGFloat = 0, server: CGFloat = 0
        for s in subviews {
            switch s[SlotKey.self] {
            case .macItem: mac = max(mac, s.sizeThatFits(.unspecified).width)
            case .serverItem: server = max(server, s.sizeThatFits(.unspecified).width)
            default: break
            }
        }
        return Cache(mac: ceil(mac), server: ceil(server))
    }

    // Nothing lines up with the inside of the drawing. Without these, SwiftUI merges every
    // piece's alignment guides, laying the whole drawing out again just to find its edges.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func columns(width: CGFloat?, cache: Cache) -> Columns {
        var mac = min(cache.mac, m.columnMax)
        var server = min(cache.server, m.columnMax)
        let core = 2 * m.fan + 2 * m.node
        guard let width, width.isFinite else {
            return Columns(mac: mac, server: server, tube: m.tubeMin, m: m)
        }
        // Equal columns keep the SSH connection in the middle; use them when there's room.
        let even = max(mac, server)
        if 2 * even + core + m.tubeMin <= width {
            mac = even
            server = even
        }
        // Too narrow: first shorten the SSH connection, then the addresses (they truncate in the middle).
        let floor = m.badge + 16
        var tube = min(m.tubeMax, max(floor, width - mac - server - core))
        let overflow = mac + server + core + tube - width
        if overflow > 0 {
            let spare = max(0, mac - m.columnMin) + max(0, server - m.columnMin)
            let cut = min(overflow, spare)
            if spare > 0 {
                mac -= cut * max(0, mac - m.columnMin) / spare
                server -= cut * max(0, server - m.columnMin) / spare
            }
            tube = max(floor, tube - (overflow - cut))
        }
        return Columns(mac: mac, server: server, tube: tube, m: m)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let c = columns(width: width, cache: cache)
        return CGSize(width: width ?? c.total, height: g.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let c = columns(width: bounds.width, cache: cache)
        let left = bounds.minX + max(0, (bounds.width - c.total) / 2)
        let top = bounds.minY
        let macEdge = left + c.mac                       // right edge of the Mac-side chips
        let macX = macEdge + m.fan + m.node / 2          // center of the Mac node
        let serverX = macX + m.node + c.tube             // center of the server node
        let serverEdge = serverX + m.node / 2 + m.fan    // left edge of the server-side chips
        let midX = (macX + serverX) / 2
        let cy = top + g.cy
        let full = ProposedViewSize(width: nil, height: g.height)

        func span(_ s: LayoutSubview, from x0: CGFloat, to x1: CGFloat) {
            s.place(at: CGPoint(x: x0, y: top), anchor: .topLeading,
                    proposal: ProposedViewSize(width: max(0, x1 - x0), height: full.height))
        }

        for s in subviews {
            guard let slot = s[SlotKey.self] else { continue }
            switch slot {
            case .tube:
                s.place(at: CGPoint(x: macX, y: cy - m.tubeHeight / 2), anchor: .topLeading,
                        proposal: ProposedViewSize(width: serverX - macX, height: m.tubeHeight))
            case .tubeLane:
                span(s, from: macX, to: serverX)
            case .macFan:
                span(s, from: macEdge + m.endGap, to: macX)
            case .serverFan:
                span(s, from: serverX, to: serverEdge - m.endGap)
            case .pulses:
                span(s, from: macEdge + m.endGap, to: serverEdge - m.endGap)
            case .arrow(let i):
                let right = i < flowsRight.count ? flowsRight[i] : true
                let y = top + g.laneY(i)
                if right {
                    s.place(at: CGPoint(x: serverEdge - m.endGap + m.line / 2, y: y), anchor: .trailing, proposal: .unspecified)
                } else {
                    s.place(at: CGPoint(x: macEdge + m.endGap - m.line / 2, y: y), anchor: .leading, proposal: .unspecified)
                }
            case .macNode:
                s.place(at: CGPoint(x: macX, y: cy), anchor: .center, proposal: .unspecified)
            case .serverNode:
                s.place(at: CGPoint(x: serverX, y: cy), anchor: .center, proposal: .unspecified)
            case .badge:
                s.place(at: CGPoint(x: midX, y: cy), anchor: .center, proposal: .unspecified)
            case .macItem(let i):
                s.place(at: CGPoint(x: macEdge, y: top + g.laneY(i)), anchor: .trailing,
                        proposal: ProposedViewSize(width: c.mac, height: nil))
            case .serverItem(let i):
                let y = flowsRight.isEmpty ? cy : top + g.laneY(i)
                s.place(at: CGPoint(x: serverEdge, y: y), anchor: .leading,
                        proposal: ProposedViewSize(width: max(c.server, flowsRight.isEmpty ? bounds.maxX - serverEdge : 0), height: nil))
            case .macTitle:
                placeTitle(s, centeredAt: macX, from: bounds.minX, to: midX - m.badge, top: top)
            case .serverTitle:
                placeTitle(s, centeredAt: serverX, from: midX + m.badge, to: bounds.maxX, top: top)
            case .caption:
                let width = max(c.tube + m.node - 8, 0)
                s.place(at: CGPoint(x: midX, y: cy + m.tubeHeight / 2 + m.captionGap), anchor: .top,
                        proposal: ProposedViewSize(width: width, height: nil))
            }
        }
    }

    /// Titles sit above their node, nudged sideways if they'd run off the edge or into the other title.
    func placeTitle(_ s: LayoutSubview, centeredAt x: CGFloat, from lower: CGFloat, to upper: CGFloat, top: CGFloat) {
        let room = max(0, upper - lower)
        let width = min(s.sizeThatFits(.unspecified).width, room)
        let center = max(lower + width / 2, min(x, upper - width / 2))
        s.place(at: CGPoint(x: center, y: top), anchor: .top, proposal: ProposedViewSize(width: width, height: nil))
    }
}

// MARK: - Pieces

/// One lane between two points, given in the drawing's coordinates: a straight run, an S-curve,
/// and another straight run. The straight parts hide under the round nodes.
private struct LaneCurve: Shape {
    var fromY: CGFloat
    var toY: CGFloat
    var straightStart: CGFloat = 0
    var straightEnd: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let a = CGPoint(x: rect.minX, y: rect.minY + fromY)
        let b = CGPoint(x: rect.maxX, y: rect.minY + toY)
        let s = CGPoint(x: min(b.x, a.x + straightStart), y: a.y)
        let e = CGPoint(x: max(s.x, b.x - straightEnd), y: b.y)
        var p = Path()
        p.move(to: a)
        if straightStart > 0 { p.addLine(to: s) }
        if abs(a.y - b.y) < 0.5 {
            p.addLine(to: e)
        } else {
            let d = (e.x - s.x) * 0.55
            p.addCurve(to: e, control1: CGPoint(x: s.x + d, y: s.y), control2: CGPoint(x: e.x - d, y: e.y))
        }
        if straightEnd > 0 { p.addLine(to: b) }
        return p
    }
}

/// A lane's line: dashed while nothing can flow, solid when it failed, and faint while traffic
/// can flow (then `LanePulses` streams along it). Inside the SSH connection a flowing lane shows
/// only its pulses, so the cable stays clean.
private struct LaneStroke<S: Shape>: View {
    var shape: S
    var color: Color
    var look: RouteDiagram.LaneLook
    var inTube = false
    var m: RouteMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch look {
            case .idle:
                if !inTube {
                    shape.stroke(color, style: StrokeStyle(lineWidth: m.line, lineCap: .round, dash: [3, 4]))
                }
            case .disabled:
                if !inTube {
                    shape.stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: m.line, lineCap: .round, dash: [2, 5]))
                }
            case .failed:
                shape.stroke(color.opacity(inTube ? 0.5 : 0.85), style: StrokeStyle(lineWidth: m.line, lineCap: .round))
            case .planned, .active, .pending:
                if !inTube {
                    shape.stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: m.line, lineCap: .round))
                } else if reduceMotion {
                    // No pulses with Reduce Motion: a steady line shows the lane is open.
                    shape.stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: m.line, lineCap: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Short pulses streaming chip to chip while traffic can flow. Editor previews (`planned`)
/// stream exactly like a live rule, so the picture matches the main window.
private struct LanePulses: View {
    var path: LanePath
    var color: Color
    var look: RouteDiagram.LaneLook
    var forward: Bool
    /// 0..<1: shifts this lane's pulses so neighbouring lanes don't march in step.
    var stagger: CGFloat
    var m: RouteMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if look.isMoving && !reduceMotion {
            let pattern = DashFlowPattern(dash: m.compact ? 5 : 7, period: m.compact ? 22 : 28,
                                          speed: look == .pending ? 12 : 34, forward: forward, offset: stagger)
            DashFlow(shape: path, color: color, lineWidth: m.dot, pattern: pattern)
                .accessibilityHidden(true)
        }
    }
}

/// A whole lane as one path, so pulses run on without a break from the chip on the Mac's side,
/// through the SSH connection, to the chip on the server's side. Same course as the three
/// `LaneCurve` pieces: the straight bits next to the tube hide under the nodes.
struct LanePath: Shape {
    /// Where the lane meets its chips.
    var chipY: CGFloat
    /// Where it runs inside the SSH connection.
    var tubeY: CGFloat
    /// Width of each end, chip to node center.
    var fan: CGFloat
    /// Straight run under each node.
    var straight: CGFloat

    func path(in rect: CGRect) -> Path {
        let leftNode = min(rect.minX + fan, rect.midX)
        let rightNode = max(rect.maxX - fan, leftNode)
        let chip = rect.minY + chipY, tube = rect.minY + tubeY
        var p = Path()
        let a = CGPoint(x: rect.minX, y: chip)
        let e = CGPoint(x: max(a.x, leftNode - straight), y: tube)
        p.move(to: a)
        curve(&p, from: a, to: e)
        p.addLine(to: CGPoint(x: rightNode, y: tube))
        let s = CGPoint(x: min(rect.maxX, rightNode + straight), y: tube)
        p.addLine(to: s)
        curve(&p, from: s, to: CGPoint(x: rect.maxX, y: chip))
        return p
    }

    private func curve(_ p: inout Path, from a: CGPoint, to b: CGPoint) {
        if abs(a.y - b.y) < 0.5 {
            p.addLine(to: b)
        } else {
            let d = (b.x - a.x) * 0.55
            p.addCurve(to: b, control1: CGPoint(x: a.x + d, y: a.y), control2: CGPoint(x: b.x - d, y: b.y))
        }
    }
}

private struct ArrowHead: View {
    var pointsRight: Bool
    var color: Color
    var look: RouteDiagram.LaneLook
    var m: RouteMetrics

    var body: some View {
        Chevron()
            .stroke(color.opacity(look == .disabled ? 0.45 : 1),
                    style: StrokeStyle(lineWidth: m.line + 0.25, lineCap: .round, lineJoin: .round))
            .frame(width: m.arrow, height: m.arrow * 2)
            .scaleEffect(x: pointsRight ? 1 : -1)
            .accessibilityHidden(true)
    }

    struct Chevron: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
        }
    }
}

/// The SSH connection: a translucent cable the lanes run through.
private struct TubeView: View {
    var color: Color
    var down: Bool

    var body: some View {
        Capsule()
            .fill(color.opacity(down ? 0.06 : 0.13))
            .overlay(
                Capsule().strokeBorder(color.opacity(down ? 0.55 : 0.32),
                                       style: StrokeStyle(lineWidth: 1, dash: down ? [3, 3] : []))
            )
            .accessibilityHidden(true)
    }
}

/// A machine on the route: this Mac, a jump host or proxy, the SSH server.
struct RouteNode: View {
    var symbol: String
    var m: RouteMetrics

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: m.node * 0.4, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: m.node, height: m.node)
            // The shadow comes from the plain circle, not the composited node.
            .background(Circle().fill(Theme.surface).shadow(color: Theme.nodeShadow, radius: 3, y: 1))
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Sits on the SSH connection: a lock while it's encrypted, a cross when it failed.
struct LockBadge: View {
    var color: Color
    var failed = false
    var m: RouteMetrics

    var body: some View {
        Image(systemName: failed ? "xmark" : "lock.fill")
            .font(.system(size: m.badge * (failed ? 0.42 : 0.46), weight: .bold))
            .foregroundStyle(.white)
            .frame(width: m.badge, height: m.badge)
            .background(color.gradient, in: Circle())
            .padding(2)
            .background(Theme.well, in: Circle())
            .accessibilityHidden(true)
    }
}

/// An address on one side of a lane. Filled = connections enter here; outlined = they end up here.
private struct AddressChip: View {
    enum Role { case entry, exit }

    var text: String
    var isAddress: Bool
    var symbol: String?
    var role: Role
    var color: Color
    var look: RouteDiagram.LaneLook
    var m: RouteMetrics
    var tag: String?

    init(address: String, role: Role, color: Color, look: RouteDiagram.LaneLook, m: RouteMetrics, tag: String? = nil) {
        self.text = address
        self.isAddress = true
        self.role = role
        self.color = color
        self.look = look
        self.m = m
        self.tag = tag
    }

    init(label: String, symbol: String, color: Color, look: RouteDiagram.LaneLook, m: RouteMetrics) {
        self.text = label
        self.isAddress = false
        self.symbol = symbol
        self.role = .exit
        self.color = color
        self.look = look
        self.m = m
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: m.chipHeight * 0.32, style: .continuous)
        let muted = look.isMuted
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: m.chipFont - 0.5, weight: .semibold))
                    .foregroundStyle(color)
            }
            if let tag {
                Text(verbatim: tag)
                    .font(.system(size: m.chipFont - 3, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
            }
            label
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(muted ? .secondary : .primary)
        }
        .padding(.horizontal, m.chipPadding)
        .frame(height: m.chipHeight)
        .background(role == .entry ? AnyShapeStyle(color.opacity(muted ? 0.08 : 0.14)) : AnyShapeStyle(Theme.surface), in: shape)
        .overlay(shape.strokeBorder(color.opacity(role == .entry ? (muted ? 0.25 : 0.32) : (muted ? 0.4 : 0.55)), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if look == .failed {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .font(.system(size: m.chipFont + 1))
                    .background(Circle().fill(Theme.well).padding(-1))
                    .offset(x: 5, y: -6)
            }
        }
        .opacity(look == .disabled ? 0.55 : 1)
    }

    /// `localhost:15432` with the port emphasized, since that's the part people look for.
    var label: Text {
        guard isAddress else {
            return Text(text).font(.system(size: m.chipFont + 0.5, weight: .medium))
        }
        let font = Font.system(size: m.chipFont, design: .monospaced)
        guard let colon = text.lastIndex(of: ":"), colon != text.startIndex else {
            return Text(verbatim: text).font(font.weight(.medium))
        }
        let host = String(text[..<colon]), port = String(text[colon...])
        return Text(verbatim: host).font(font) + Text(verbatim: port).font(font.weight(.bold))
    }
}

// MARK: - Route to the server (proxy / jump host)

/// This Mac → (proxy or jump host) → SSH server, for the Connection settings.
struct HopsView: View {
    var tunnel: Tunnel
    private let m = RouteMetrics.compact

    struct Hop: Identifiable {
        var id: String
        var symbol: String
        var title: String
        var subtitle: String?
    }

    var hops: [Hop] {
        var hops = [Hop(id: "mac", symbol: "laptopcomputer", title: String(localized: "This Mac"), subtitle: nil)]
        if tunnel.proxy.kind != .none {
            let isJump = tunnel.proxy.kind == .jumpHost
            let placeholder = isJump ? String(localized: "Jump host") : String(localized: "Proxy server")
            let host = tunnel.proxy.host.trimmingCharacters(in: .whitespaces)
            hops.append(Hop(id: "proxy", symbol: isJump ? "arrow.triangle.branch" : "shield.lefthalf.filled",
                            title: host.isEmpty ? placeholder : (tunnel.proxy.port > 0 ? "\(host):\(tunnel.proxy.port)" : host),
                            subtitle: tunnel.proxy.kind.title))
        }
        hops.append(Hop(id: "server", symbol: "server.rack",
                        title: tunnel.host.isEmpty ? String(localized: "SSH server") : "\(tunnel.host):\(tunnel.port)",
                        subtitle: tunnel.host.isEmpty ? nil : String(localized: "SSH server")))
        return hops
    }

    var body: some View {
        let hops = hops
        HStack(alignment: .top, spacing: 0) {
            ForEach(hops) { hop in
                VStack(spacing: 6) {
                    RouteNode(symbol: hop.symbol, m: m)
                    VStack(spacing: 1) {
                        Text(hop.title)
                            .font(.system(size: m.title, weight: .semibold))
                            .truncationMode(.middle)
                        if let subtitle = hop.subtitle {
                            Text(subtitle)
                                .font(.system(size: m.subtitle))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                }
                .frame(maxWidth: .infinity)
                .help(hop.subtitle.map { "\(hop.title) – \($0)" } ?? hop.title)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .background(alignment: .top) {
            // One cable from the first machine to the last, with a lock on each encrypted hop.
            GeometryReader { geo in
                let step = geo.size.width / CGFloat(hops.count)
                TubeView(color: Theme.sea, down: false)
                    .frame(width: step * CGFloat(hops.count - 1), height: m.tubeHeight)
                    .position(x: geo.size.width / 2, y: m.node / 2)
                ForEach(1..<hops.count, id: \.self) { i in
                    LockBadge(color: Theme.sea, m: m)
                        .position(x: step * CGFloat(i), y: m.node / 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.snappy(duration: 0.25), value: tunnel.proxy.kind)
    }
}
