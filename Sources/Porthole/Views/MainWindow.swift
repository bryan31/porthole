import PortholeCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            DetailContainer()
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search name, host, port…")
        .toolbar { MainToolbar() }
        .sheet(item: $model.editor) { request in
            TunnelEditorView(request: request)
        }
        .sheet(item: $model.logRequest) { request in
            LogSheet(tunnelID: request.id)
        }
        .sheet(item: $model.smartGroupEditor) { group in
            SmartGroupEditor(group: group)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } })) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
        } message: {
            Text("Running tunnels are disconnected and saved passwords are removed from your Keychain. This can't be undone.")
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .frame(minWidth: 840, minHeight: 540)
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            model.openSettingsWindow = { openSettings() }
        }
    }

    var deleteTitle: String {
        let n = model.pendingDeletion?.count ?? 0
        if n == 1, let id = model.pendingDeletion?.first, let t = model.store.tunnel(id) {
            let name = t.displayName
            return String(localized: "Delete “\(name)”?")
        }
        return String(localized: "Delete \(n) tunnels?")
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.selection.count == 1, let id = model.selection.first, model.store.tunnel(id) != nil {
                Button { model.edit(id) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                    .help("Edit tunnel settings (⌘E)")
                Menu {
                    Button("Duplicate") { model.duplicate([id]) }
                    Button("Copy SSH Command") { model.copyCommand(id) }
                    Button("Show Log") { model.showLog(id) }
                    Divider()
                    Button("Delete…", role: .destructive) { model.requestDelete([id]) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More actions")
            }
            Button { model.newTunnel() } label: { Label("New Tunnel", systemImage: "plus") }
                .help("Create a new tunnel (⌘N)")
            AppearanceToolbarButton()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let tunnels = model.visibleTunnels
        List(selection: $model.selection) {
            ForEach(tunnels) { tunnel in
                TunnelRow(tunnel: tunnel)
                    .tag(tunnel.id)
                    .contextMenu { TunnelContextMenu(ids: model.targets(for: tunnel.id)) }
            }
            .onMove(perform: model.canReorder ? { model.store.move(from: $0, to: $1) } : nil)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { FilterBar() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
        .overlay {
            if tunnels.isEmpty && !model.store.tunnels.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text("No tunnel matches this filter. Try other keywords.")
                }
            }
        }
    }
}

struct TunnelRow: View {
    @Environment(AppModel.self) private var model
    var tunnel: Tunnel

    var body: some View {
        let runtime = model.manager.runtimes[tunnel.id]
        let state = runtime?.state ?? .off
        HStack(spacing: 9) {
            StatusDot(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(state: state))
                    .font(.system(size: 11))
                    .foregroundStyle(isFailed(state) ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { model.manager.isOn(tunnel.id) || state.isBusy },
                set: { model.manager.setOn(tunnel.id, $0) }
            ))
            .toggleStyle(RowSwitchStyle())
            .labelsHidden()
            .accessibilityLabel(tunnel.displayName)
            .help(state.isActive ? String(localized: "Disconnect") : String(localized: "Connect"))
        }
        .padding(.vertical, 4)
    }

    func isFailed(_ s: TunnelState) -> Bool {
        if case .failed = s { return true }
        return false
    }

    func subtitle(state: TunnelState) -> String {
        switch state {
        case .connected:
            let n = tunnel.enabledForwardings.count
            let rules = String(localized: "\(n) rules")
            return String(localized: "Connected · \(rules)")
        case .reconnecting(let attempt, _): return String(localized: "Reconnecting (attempt \(attempt))…")
        case .failed(let m): return m
        case .off:
            let rules = tunnel.enabledForwardings.prefix(2).map { $0.kind == .dynamic ? "SOCKS :\($0.port)" : ":\($0.port)" }
            return ([tunnel.hostNotation] + rules).joined(separator: "  ·  ")
        default: return state.title
        }
    }
}

struct TunnelContextMenu: View {
    @Environment(AppModel.self) private var model
    var ids: Set<UUID>

    var body: some View {
        let anyOn = ids.contains { model.manager.isOn($0) || model.manager.state($0).isBusy }
        let anyOff = ids.contains { !model.manager.isOn($0) }
        if anyOff { Button("Connect") { model.manager.connect(ids) } }
        if anyOn { Button("Disconnect") { model.manager.disconnect(ids) } }
        Divider()
        if ids.count == 1, let id = ids.first {
            Button("Edit…") { model.edit(id) }
            Button("Copy SSH Command") { model.copyCommand(id) }
            Button("Show Log") { model.showLog(id) }
        }
        let n = ids.count
        Button(n == 1 ? String(localized: "Duplicate") : String(localized: "Duplicate \(n) Tunnels")) { model.duplicate(ids) }
        Button(n == 1 ? String(localized: "Export…") : String(localized: "Export \(n) Tunnels…")) { model.export(ids) }
        Divider()
        Button(n == 1 ? String(localized: "Delete…") : String(localized: "Delete \(n) Tunnels…"), role: .destructive) { model.requestDelete(ids) }
    }
}

struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            chip(String(localized: "All"), .all)
            chip(String(localized: "Active"), .active)
            if model.count(for: .autoStart) > 0 {
                chip(String(localized: "Auto-start"), .autoStart)
            }
            ForEach(model.store.smartGroups) { group in
                chip(group.name, .group(group.id))
                    .contextMenu {
                        Button("Edit Smart Group…") { model.smartGroupEditor = group }
                        Button("Delete Smart Group", role: .destructive) {
                            if model.filter == .group(group.id) { model.filter = .all }
                            model.store.deleteSmartGroup(group.id)
                        }
                    }
            }
            Button { model.newSmartGroup() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("New Smart Group – saves keywords (e.g. the current search) as a filter")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func chip(_ title: String, _ filter: SidebarFilter) -> some View {
        let selected = model.filter == filter
        return Button {
            withAnimation(.snappy(duration: 0.2)) { model.filter = filter }
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Text("\(model.count(for: filter))")
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.06)), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New Tunnel") { model.newTunnel() }
                Button("New Smart Group…") { model.newSmartGroup() }
                Divider()
                Button("Import Tunnels…") { model.importFile() }
                Button("Import from ~/.ssh/config") { model.importSSHConfig() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add")

            Spacer()
            let connected = model.manager.connectedCount
            let total = model.store.tunnels.count
            Text(connected == 0 ? String(localized: "\(total) tunnels") : String(localized: "\(connected) of \(total) connected"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Menu {
                Button("Connect All") { model.manager.connectAll() }
                Button("Disconnect All") { model.manager.disconnectAll() }
            } label: {
                Image(systemName: "power")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Connect or disconnect all tunnels")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Detail routing

struct DetailContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.selection.filter { model.store.tunnel($0) != nil }
        Group {
            if model.store.tunnels.isEmpty {
                EmptyLibraryView()
            } else if ids.count == 1, let id = ids.first {
                TunnelDetailView(tunnelID: id)
                    .id(id)
            } else if ids.count > 1 {
                MultiSelectionView(ids: ids)
            } else {
                ContentUnavailableView {
                    Label("Select a Tunnel", systemImage: "sidebar.left")
                } description: {
                    Text("Choose a tunnel to see its status and forwarding rules.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var kind: ForwardingKind = .local

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Welcome to Porthole")
                    .font(.largeTitle.weight(.semibold))
                Text("A tunnel forwards ports through an SSH server, so databases, dashboards and internal sites feel like they run on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                HStack(spacing: 12) {
                    Button { model.newTunnel() } label: {
                        Label("Create a Tunnel", systemImage: "plus")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Menu("Import…") {
                        Button("Porthole or SSH Tunnel export…") { model.importFile() }
                        Button("Hosts from ~/.ssh/config") { model.importSSHConfig() }
                    }
                    .controlSize(.large)
                    .fixedSize()
                }
                .padding(.top, 4)
                explainer
                    .padding(.top, 20)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    /// Shows each kind of rule as a route diagram, so it's clear which one to pick.
    var explainer: some View {
        let example = Self.example(kind)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Which rule do you need?").font(.headline)
                Spacer()
                Picker("Rule type", selection: $kind.animation(.snappy(duration: 0.25))) {
                    ForEach(ForwardingKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            RouteDiagram(tunnel: example.tunnel, forwardings: [example.forwarding], style: .preview, compact: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary(kind)).font(.callout.weight(.medium))
                Text(example.forwarding.explanation(serverName: example.tunnel.host))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: 620)
        .surface()
    }

    func summary(_ kind: ForwardingKind) -> LocalizedStringKey {
        switch kind {
        case .local: return "Reach a remote service on a local port"
        case .remote: return "Share a local service with the server"
        case .dynamic: return "Browse through the server"
        }
    }

    static func example(_ kind: ForwardingKind) -> (tunnel: Tunnel, forwarding: Forwarding) {
        let forwarding: Forwarding
        switch kind {
        case .local: forwarding = Forwarding(kind: .local, port: 5432, targetHost: "db.internal", targetPort: 5432)
        case .remote: forwarding = Forwarding(kind: .remote, port: 8080, targetHost: "localhost", targetPort: 3000)
        case .dynamic: forwarding = Forwarding(kind: .dynamic, port: 1080, targetHost: "", targetPort: 0)
        }
        var tunnel = Tunnel()
        tunnel.host = "server.example.com"
        tunnel.forwardings = [forwarding]
        return (tunnel, forwarding)
    }
}

struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    var ids: Set<UUID>

    var body: some View {
        let tunnels = model.store.tunnels.filter { ids.contains($0.id) }
        let connected = tunnels.filter { model.manager.state($0.id) == .connected }.count
        VStack(spacing: 18) {
            ZStack {
                ForEach(Array(tunnels.prefix(3).enumerated()), id: \.offset) { index, t in
                    TunnelBadge(state: model.manager.state(t.id), size: 64)
                        .rotationEffect(.degrees(Double(index - 1) * 9))
                        .offset(x: CGFloat(index - 1) * 26)
                }
            }
            .frame(height: 80)
            Text("\(tunnels.count) of \(model.store.tunnels.count) selected")
                .font(.title2.weight(.semibold))
            Text(connected == 0 ? String(localized: "None connected") : String(localized: "\(connected) connected"))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Connect All") { model.manager.connect(ids) }
                    .buttonStyle(.borderedProminent)
                Button("Disconnect All") { model.manager.disconnect(ids) }
                Button("Delete…", role: .destructive) { model.requestDelete(ids) }
            }
            .controlSize(.large)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tunnels.prefix(10)) { t in
                    HStack(spacing: 8) {
                        StatusDot(state: model.manager.state(t.id), size: 7)
                        Text(t.displayName).font(.callout.weight(.medium))
                        Spacer()
                        Text(t.hostNotation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if tunnels.count > 10 {
                    Text("+\(tunnels.count - 10) more…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 380)
            .padding(14)
            .surface(radius: 12)
        }
        .padding(40)
    }
}
