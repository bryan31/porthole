import PortholeCore
import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TunnelBadge(state: model.manager.connectedCount > 0 ? .connected : .off, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Porthole").font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.toggleAppearance() } label: {
                    Image(systemName: model.appearance.symbolName)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help("Switch Light/Dark")
                Button { model.openSettingsWindow?(); NSApp.activate(ignoringOtherApps: true) } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            if model.store.tunnels.isEmpty {
                VStack(spacing: 8) {
                    Text("No tunnels yet").font(.callout.weight(.medium))
                    Button("Create a Tunnel…") { model.newTunnel() }
                }
                .padding(20)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.store.tunnels) { tunnel in
                            MenuTunnelRow(tunnel: tunnel)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                Button { model.manager.connectAll() } label: {
                    Label("Connect All", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                Button { model.manager.disconnectAll() } label: {
                    Label("Disconnect All", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .disabled(model.manager.activeCount == 0)
            }
            .controlSize(.regular)
            .padding(10)

            Divider()

            VStack(spacing: 0) {
                MenuActionRow(title: "Open Porthole", systemImage: "macwindow", shortcut: "⌘O") { model.showMainWindow() }
                MenuActionRow(title: "Quit Porthole", systemImage: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .frame(width: 330)
    }

    var summary: String {
        let total = model.store.tunnels.count
        let connected = model.manager.connectedCount
        if total == 0 { return String(localized: "Secure SSH tunnels") }
        if connected == 0 { return String(localized: "\(total) tunnels, none connected") }
        return String(localized: "\(connected) of \(total) connected")
    }
}

private struct MenuTunnelRow: View {
    @Environment(AppModel.self) private var model
    var tunnel: Tunnel
    @State private var hovering = false

    var body: some View {
        let runtime = model.manager.runtimes[tunnel.id]
        let state = runtime?.state ?? .off
        HStack(spacing: 10) {
            StatusDot(state: state, size: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(
                get: { model.manager.isOn(tunnel.id) || state.isBusy },
                set: { model.manager.setOn(tunnel.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            model.selection = [tunnel.id]
            model.showMainWindow()
        }
        .help("Double-click to open in Porthole")
    }

    func detail(_ state: TunnelState) -> String {
        switch state {
        case .failed(let m): return m
        case .reconnecting(let a, _): return String(localized: "Reconnecting (attempt \(a))…")
        case .connecting, .waitingForUser, .disconnecting: return state.title
        default:
            let rules = tunnel.enabledForwardings.prefix(2).map { f -> String in
                switch f.kind {
                case .dynamic: return "SOCKS :\(f.port)"
                case .local: return ":\(f.port) → \(f.targetHost):\(f.targetPort)"
                case .remote: return String(localized: "server :\(String(f.port)) → :\(String(f.targetPort))")
                }
            }
            let more = tunnel.enabledForwardings.count > 2 ? " +\(tunnel.enabledForwardings.count - 2)" : ""
            return rules.isEmpty ? tunnel.hostNotation : rules.joined(separator: ", ") + more
        }
    }
}

private struct MenuActionRow: View {
    var title: LocalizedStringKey
    var systemImage: String
    var shortcut: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.tertiary).font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(hovering ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
