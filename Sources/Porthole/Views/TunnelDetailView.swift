import PortholeCore
import SwiftUI

struct TunnelDetailView: View {
    @Environment(AppModel.self) private var model
    var tunnelID: UUID

    var body: some View {
        if let tunnel = model.store.tunnel(tunnelID) {
            let runtime = model.manager.runtimes[tunnelID]
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(tunnel, runtime)
                        .padding(.bottom, 4)
                    banner(tunnel, runtime)
                    forwardings(tunnel, runtime)
                    connection(tunnel, runtime)
                    if !tunnel.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Card("Note", systemImage: "note.text") {
                            Text(tunnel.note)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                        }
                    }
                    // Its own view: new log lines then redraw only this card, not the whole page.
                    ActivityCard(runtime: runtime) { model.showLog(tunnelID) }
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 28)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Header

    func header(_ tunnel: Tunnel, _ runtime: TunnelRuntime?) -> some View {
        let state = runtime?.state ?? .off
        return HStack(alignment: .center, spacing: 14) {
            TunnelBadge(state: state, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(tunnel.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                let address = HStack(spacing: 3) {
                    Text(tunnel.hostNotation)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    CopyButton(value: tunnel.hostNotation, help: String(localized: "Copy server address"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        StatusPill(runtime: runtime).fixedSize()
                        address.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        StatusPill(runtime: runtime).fixedSize()
                        address
                    }
                }
            }
            Spacer(minLength: 12)
            Button("Edit…") { model.edit(tunnelID) }
                .help("Edit tunnel settings (⌘E)")
            Toggle("Connect", isOn: Binding(
                get: { model.manager.isOn(tunnelID) || state.isBusy },
                set: { model.manager.setOn(tunnelID, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.large)
            .labelsHidden()
            .help(state.isActive ? String(localized: "Disconnect (⌘.)") : String(localized: "Connect (⌘R)"))
        }
    }

    // MARK: Banners

    @ViewBuilder
    func banner(_ tunnel: Tunnel, _ runtime: TunnelRuntime?) -> some View {
        switch runtime?.state ?? .off {
        case .failed(let message):
            Banner(color: .red, symbol: "exclamationmark.triangle.fill") {
                Text("Couldn't connect").font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Try Again") { model.manager.connect(tunnelID) }
                        .buttonStyle(.borderedProminent)
                    Button("Show Log") { model.showLog(tunnelID) }
                    Button("Edit Settings…") { model.edit(tunnelID) }
                }
                .controlSize(.small)
                .padding(.top, 6)
            }
        case .reconnecting(_, _):
            Banner(color: .orange, symbol: "wifi.exclamationmark") {
                Text("Connection lost").font(.system(size: 13, weight: .semibold))
                Text(runtime?.lastError ?? String(localized: "Porthole will reconnect automatically."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } trailing: {
                Button("Retry Now") { runtime?.retryNow() }
            }
        case .waitingForUser:
            Banner(color: .blue, symbol: "key.fill") {
                Text("Waiting for you to answer the server's prompt…").font(.system(size: 13))
            }
        default:
            EmptyView()
        }
    }

    // MARK: Forwardings

    func forwardings(_ tunnel: Tunnel, _ runtime: TunnelRuntime?) -> some View {
        let count = tunnel.forwardings.count
        return Card("Port Forwarding", systemImage: "arrow.left.arrow.right",
                    trailing: AnyView(Text("\(tunnel.enabledForwardings.count) of \(count) enabled")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit())) {
            RouteDiagram(tunnel: tunnel, forwardings: tunnel.forwardings,
                         state: runtime?.state ?? .off, statuses: runtime?.forwardStatus ?? [:])
            if tunnel.forwardings.isEmpty {
                Button("Add Rule…") { model.edit(tunnelID) }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tunnel.forwardings.enumerated()), id: \.element.id) { index, f in
                        if index > 0 { Divider().padding(.leading, 46).padding(.trailing, 8) }
                        ForwardRuleRow(forwarding: f, status: runtime?.forwardStatus[f.id] ?? .idle, serverName: tunnel.host)
                    }
                }
                .padding(.horizontal, -8)
                .padding(.bottom, -6)
            }
        }
    }

    // MARK: Connection info

    func connection(_ tunnel: Tunnel, _ runtime: TunnelRuntime?) -> some View {
        Card("Connection", systemImage: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                InfoRow(label: "Server", value: "\(tunnel.host):\(tunnel.port)", monospaced: true)
                InfoRow(label: "User", value: tunnel.user.isEmpty ? String(localized: "Default (\(NSUserName()))") : tunnel.user)
                InfoRow(label: "Authentication", value: authDescription(tunnel, runtime))
                InfoRow(label: "Host key", value: runtime?.hostKey ?? String(localized: "Shown after the first connection"), monospaced: runtime?.hostKey != nil, copyable: runtime?.hostKey != nil)
                if tunnel.proxy.kind != .none {
                    InfoRow(label: "Route", value: "\(tunnel.proxy.kind.title) · \(tunnel.proxy.host):\(tunnel.proxy.port)")
                }
                InfoRow(label: "Keep-alive", value: tunnel.keepAliveInterval == 0 ? String(localized: "Off")
                        : String(localized: "Every \(tunnel.keepAliveInterval) s, give up after \(String(localized: "\(tunnel.keepAliveCountMax) missed replies"))"))
                if let r = runtime, r.reconnectCount > 0 {
                    InfoRow(label: "Reconnects", value: "\(r.reconnectCount)")
                }
            }
            Divider()
            HStack(spacing: 18) {
                Toggle("Connect when Porthole launches", isOn: Binding(
                    get: { model.store.tunnel(tunnelID)?.autoConnect ?? false },
                    set: { model.store.setAutoConnect(tunnelID, $0) }
                ))
                Spacer()
                Button {
                    model.copyCommand(tunnelID)
                } label: {
                    Label("Copy ssh Command", systemImage: "terminal")
                }
                .controlSize(.small)
            }
            .toggleStyle(.checkbox)
        }
    }

    func authDescription(_ tunnel: Tunnel, _ runtime: TunnelRuntime?) -> String {
        var base = tunnel.authMethod.shortTitle
        if tunnel.authMethod == .publicKey, !tunnel.identityFile.isEmpty {
            base += " · " + (tunnel.identityFile as NSString).lastPathComponent
        }
        if let used = runtime?.authenticatedWith { base += "  " + String(localized: "(signed in with \(used))") }
        return base
    }
}

// MARK: - Activity

/// The latest log lines. ssh's verbose output can add many lines a second while a tunnel is
/// busy, so only this card watches the log.
struct ActivityCard: View {
    var runtime: TunnelRuntime?
    var showLog: () -> Void

    var body: some View {
        Card("Activity", systemImage: "waveform.path.ecg",
             trailing: AnyView(Button("Full Log", action: showLog).controlSize(.small))) {
            let entries = Array((runtime?.logs ?? []).lazy.filter { $0.level != .debug }.suffix(8))
            if entries.isEmpty {
                Text("Nothing yet. Turn the tunnel on to see what's happening.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(entries) { LogLineView(entry: $0) }
                }
            }
        }
    }
}

struct ForwardRuleRow: View {
    var forwarding: Forwarding
    var status: ForwardStatus
    var serverName: String
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            KindBadge(kind: forwarding.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(forwarding.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                ForwardAddressLine(forwarding: forwarding)
                    .textSelection(.enabled)
                if case .failed(let message) = status {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(forwarding.explanation(serverName: serverName))
            Spacer(minLength: 8)
            if forwarding.enabled {
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text(status.label)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            } else {
                Text("Disabled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.7), in: Capsule())
                    .frame(minWidth: 70, alignment: .leading)
            }
            HStack(spacing: 8) {
                if forwarding.kind.listensLocally {
                    CopyButton(value: copyValue, help: String(localized: "Copy \(copyValue)"))
                }
                if forwarding.kind == .local, let url = browserURL {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Open \(url.absoluteString)"))
                        .disabled(status != .active)
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(forwarding.enabled ? 1 : 0.6)
    }

    var copyValue: String {
        forwarding.kind == .dynamic ? "socks5://\(forwarding.listenDisplayAddress)" : forwarding.listenDisplayAddress
    }

    var browserURL: URL? {
        let webPorts: Set<Int> = [80, 443, 3000, 4200, 5000, 5173, 8000, 8080, 8443, 8888, 9000, 9090]
        guard webPorts.contains(forwarding.targetPort) || webPorts.contains(forwarding.port) else { return nil }
        let scheme = (forwarding.targetPort == 443 || forwarding.targetPort == 8443) ? "https" : "http"
        let host = forwarding.listenDisplayAddress.hasPrefix("0.0.0.0") ? "localhost:\(forwarding.port)" : forwarding.listenDisplayAddress
        return URL(string: "\(scheme)://\(host)")
    }
}

/// `💻 localhost:15432 → 🗄 db.internal:5432`, with icons saying which machine each address
/// belongs to. The icons go first when space runs out.
struct ForwardAddressLine: View {
    var forwarding: Forwarding

    var body: some View {
        ViewThatFits(in: .horizontal) {
            addresses(icons: true)
            addresses(icons: false)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    func addresses(icons: Bool) -> some View {
        HStack(spacing: 5) {
            switch forwarding.kind {
            case .local:
                endpoint(icons ? "laptopcomputer" : nil, forwarding.listenDisplayAddress)
                arrow
                endpoint(icons ? "server.rack" : nil, forwarding.targetDisplayAddress)
            case .remote:
                let bind = forwarding.bindAddress.trimmingCharacters(in: .whitespaces)
                endpoint(icons ? "server.rack" : nil, bind.isEmpty ? "localhost:\(forwarding.port)" : forwarding.listenDisplayAddress)
                arrow
                endpoint(icons ? "laptopcomputer" : nil, forwarding.targetDisplayAddress)
            case .dynamic:
                endpoint(icons ? "laptopcomputer" : nil, forwarding.listenDisplayAddress)
                arrow
                if icons { Image(systemName: "globe").foregroundStyle(.tertiary) }
                Text("Any website or host").lineLimit(1)
            }
        }
    }

    var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(forwarding.kind.tint.opacity(0.8))
    }

    func endpoint(_ symbol: String?, _ address: String) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(address).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// A tinted notice above the tunnel's details.
struct Banner<Content: View, Trailing: View>: View {
    var color: Color
    var symbol: String
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    init(color: Color, symbol: String, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.color = color
        self.symbol = symbol
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 18)
            VStack(alignment: .leading, spacing: 3) { content }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(color.opacity(0.08), in: shape)
        .overlay(shape.strokeBorder(color.opacity(0.2), lineWidth: 1))
    }
}

struct LogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var tunnelID: UUID
    @State private var showDebug = false
    @State private var query = ""

    var body: some View {
        let runtime = model.manager.runtimes[tunnelID]
        let name = model.store.tunnel(tunnelID)?.displayName ?? "Tunnel"
        let entries = (runtime?.logs ?? []).filter { (showDebug || $0.level != .debug) && (query.isEmpty || $0.message.localizedCaseInsensitiveContains(query)) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Log").font(.headline)
                Text(name).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Toggle("ssh debug output", isOn: $showDebug)
                    .toggleStyle(.checkbox)
                Button {
                    let text = entries.map { "\(LogLineView.timeFormatter.string(from: $0.date)) [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy log")
                Button { runtime?.clearLog() } label: { Image(systemName: "trash") }
                    .help("Clear log")
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(entries) { LogLineView(entry: $0).id($0.id) }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear { if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: entries.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .overlay {
                    if entries.isEmpty {
                        Text("No log entries.").foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(entries.count) entries").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 780, height: 520)
    }
}

struct SmartGroupEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var group: SmartGroup

    var body: some View {
        let isNew = !model.store.smartGroups.contains { $0.id == group.id }
        let matches = model.store.tunnels.filter { $0.matches(query: group.keywords) }
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? String(localized: "New Smart Group") : String(localized: "Edit Smart Group")).font(.title3.weight(.semibold))
            Text("A Smart Group shows every tunnel whose name, note, host or ports contain all of the keywords.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $group.name, prompt: Text("e.g. Work"))
                TextField("Keywords", text: $group.keywords, prompt: Text("Separate keywords with spaces"))
            }
            .formStyle(.columns)
            let names = matches.prefix(4).map(\.displayName).formatted(.list(type: .and)) + (matches.count > 4 ? "…" : "")
            Text(matches.isEmpty ? String(localized: "No tunnels match yet.") : String(localized: "Matching tunnels: \(names)"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        if model.filter == .group(group.id) { model.filter = .all }
                        model.store.deleteSmartGroup(group.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var g = group
                    if g.name.trimmingCharacters(in: .whitespaces).isEmpty { g.name = g.keywords }
                    if isNew { model.store.addSmartGroup(g) } else { model.store.updateSmartGroup(g) }
                    model.filter = .group(g.id)
                    model.searchText = ""
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(group.keywords.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
