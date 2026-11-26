import AppKit
import PortholeCore
import SwiftUI

/// Sample data used by `--render-snapshots` (UI review without a real server).
@MainActor
enum DemoData {
    static func makeModel(empty: Bool = false) -> AppModel {
        guard !empty else { return AppModel(store: TunnelStore(inMemory: PortholeDocument())) }
        let prod = Tunnel(
            name: "Production Database", note: "Read replica – handle with care",
            host: "bastion.acme.io", user: "deploy", authMethod: .publicKey, identityFile: "~/.ssh/id_ed25519",
            forwardings: [
                Forwarding(kind: .local, port: 15432, targetHost: "pg-replica.internal", targetPort: 5432, note: "Postgres replica"),
                Forwarding(kind: .local, port: 16379, targetHost: "redis.internal", targetPort: 6379, note: "Session cache"),
                Forwarding(kind: .local, port: 8080, targetHost: "grafana.internal", targetPort: 80, note: "Grafana"),
            ],
            autoConnect: true
        )
        let k8s = Tunnel(name: "Staging Kubernetes", host: "jump.staging.acme.io", port: 2222, user: "ops",
                         forwardings: [Forwarding(kind: .local, port: 6443, targetHost: "10.0.0.1", targetPort: 6443, note: "kube-apiserver")])
        let socks = Tunnel(name: "Home Lab Proxy", note: "Browse via home connection", host: "home.example.net", user: "pi",
                           forwardings: [Forwarding(kind: .dynamic, bindAddress: "127.0.0.1", port: 1080, targetHost: "", targetPort: 0)],
                           autoConnect: true)
        let failed = Tunnel(name: "Customer VPN Gateway", host: "gw.customer.example", user: "support", authMethod: .password,
                            forwardings: [Forwarding(kind: .local, port: 3389, targetHost: "rdp-host", targetPort: 3389, note: "Remote desktop")])
        let remote = Tunnel(name: "Share Dev Server", note: "Let the team preview my branch", host: "preview.acme.io", user: "deploy",
                            forwardings: [Forwarding(kind: .remote, port: 8080, targetHost: "localhost", targetPort: 3000, note: "Vite dev server")])
        let redis = Tunnel(name: "Analytics Warehouse", host: "10.20.0.4", user: "analyst",
                           forwardings: [Forwarding(kind: .local, port: 5439, targetHost: "warehouse.internal", targetPort: 5439),
                                         Forwarding(kind: .local, port: 9000, targetHost: "minio.internal", targetPort: 9000, enabled: false)],
                           proxy: ProxySettings(kind: .jumpHost, host: "bastion.acme.io", port: 22))
        let doc = PortholeDocument(tunnels: [prod, k8s, socks, failed, remote, redis],
                                   smartGroups: [SmartGroup(name: "Work", keywords: "acme"), SmartGroup(name: "Databases", keywords: "5432")])
        let model = AppModel(store: TunnelStore(inMemory: doc))
        let m = model.manager
        m.runtime(prod.id).applyDemo(
            state: .connected, connectedSince: Date().addingTimeInterval(-7_980), hostKey: "ssh-ed25519 SHA256:p0Rt4H0le+9xQ2mZkWcH1sYb7Lr3T0nNe5aVvU8dJfE", auth: "publickey",
            forwardStatus: Dictionary(uniqueKeysWithValues: prod.forwardings.map { ($0.id, ForwardStatus.active) }),
            logs: [(.info, String(localized: "Connecting to \(prod.hostNotation)…")), (.info, "Connection established."),
                   (.success, "Authenticated to bastion.acme.io ([203.0.113.10]:22) using \"publickey\"."),
                   (.success, "Local forwarding listening on 127.0.0.1 port 15432."),
                   (.success, "Local forwarding listening on 127.0.0.1 port 16379."),
                   (.success, "Local forwarding listening on 127.0.0.1 port 8080."),
                   (.success, String(localized: "Tunnel is up."))])
        m.runtime(k8s.id).applyDemo(state: .connecting, forwardStatus: [k8s.forwardings[0].id: .pending],
                                    logs: [(.info, String(localized: "Connecting to \(k8s.hostNotation)…"))])
        m.runtime(socks.id).applyDemo(state: .connected, connectedSince: Date().addingTimeInterval(-312), auth: "publickey",
                                      forwardStatus: [socks.forwardings[0].id: .active])
        let rejected = SSHLogParser.friendlyMessage(for: .authFailed("Permission denied"))
        m.runtime(failed.id).applyDemo(state: .failed(rejected),
                                       logs: [(.info, String(localized: "Connecting to \(failed.hostNotation)…")),
                                              (.error, "support@gw.customer.example: Permission denied (publickey,password)."),
                                              (.error, rejected)])
        let closed = SSHLogParser.friendlyMessage(for: .disconnected("Connection to preview.acme.io closed by remote host."))
        let retry = 4
        m.runtime(remote.id).applyDemo(state: .reconnecting(attempt: 2, at: Date().addingTimeInterval(7)),
                                       forwardStatus: [remote.forwardings[0].id: .pending],
                                       logs: [(.warning, String(localized: "Connection lost: \(closed) Retrying in \(retry) s."))],
                                       lastError: closed, reconnects: 2)
        model.selection = [prod.id]
        return model
    }
}

@MainActor
enum Snapshotter {
    static func run(model: AppModel, directory: String) {
        // Offscreen captures can't see Core Animation layers; draw still frames instead.
        Motion.isLive = false
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tunnels = model.store.tunnels

        render(MainWindow().environment(model), size: NSSize(width: 1180, height: 760), to: dir.appendingPathComponent("main-light.png"), dark: false)
        render(MainWindow().environment(model), size: NSSize(width: 1180, height: 760), to: dir.appendingPathComponent("main-dark.png"), dark: true)

        model.selection = [tunnels[3].id]
        render(MainWindow().environment(model), size: NSSize(width: 1180, height: 760), to: dir.appendingPathComponent("main-failed.png"), dark: false)

        model.selection = [tunnels[4].id]
        render(MainWindow().environment(model), size: NSSize(width: 1180, height: 760), to: dir.appendingPathComponent("main-reconnecting.png"), dark: true)

        model.selection = [tunnels[2].id]
        render(MainWindow().environment(model), size: NSSize(width: 1180, height: 760), to: dir.appendingPathComponent("main-socks.png"), dark: true)

        model.selection = [tunnels[5].id]
        render(MainWindow().environment(model), size: NSSize(width: 1180, height: 760), to: dir.appendingPathComponent("main-off.png"), dark: false)

        model.selection = [tunnels[0].id]
        render(MainWindow().environment(model), size: NSSize(width: 860, height: 640), to: dir.appendingPathComponent("main-narrow.png"), dark: false)

        model.selection = Set(tunnels.prefix(3).map(\.id))
        render(MainWindow().environment(model), size: NSSize(width: 1180, height: 760), to: dir.appendingPathComponent("main-multi.png"), dark: false)

        let empty = DemoData.makeModel(empty: true)
        render(MainWindow().environment(empty), size: NSSize(width: 1180, height: 760), to: dir.appendingPathComponent("main-empty.png"), dark: false)
        render(MainWindow().environment(empty), size: NSSize(width: 1180, height: 760), to: dir.appendingPathComponent("main-empty-dark.png"), dark: true)

        let request = EditorRequest(tunnel: tunnels[0], isNew: false)
        for tab in TunnelEditorView.Tab.allCases {
            render(TunnelEditorView(request: request, initialTab: tab).environment(model), size: NSSize(width: 680, height: 640),
                   to: dir.appendingPathComponent("editor-\(tab.rawValue.lowercased()).png"), dark: false)
        }

        // Several rules start folded; this one shows the first opened, the way the user edits it.
        render(TunnelEditorView(request: request, initialTab: .forwarding, expandedRules: [tunnels[0].forwardings[0].id]).environment(model),
               size: NSSize(width: 680, height: 640), to: dir.appendingPathComponent("editor-forwarding-expanded.png"), dark: true)

        var fresh = Tunnel()
        fresh.forwardings = [Forwarding(kind: .local, port: 8080, targetHost: "localhost", targetPort: 80)]
        render(TunnelEditorView(request: EditorRequest(tunnel: fresh, isNew: true)).environment(model), size: NSSize(width: 680, height: 640),
               to: dir.appendingPathComponent("editor-new.png"), dark: false)

        let jump = EditorRequest(tunnel: tunnels[5], isNew: false)
        render(TunnelEditorView(request: jump, initialTab: .connection).environment(model), size: NSSize(width: 680, height: 640),
               to: dir.appendingPathComponent("editor-connection-jump.png"), dark: true)
        render(TunnelEditorView(request: EditorRequest(tunnel: tunnels[4], isNew: false), initialTab: .forwarding).environment(model),
               size: NSSize(width: 680, height: 640), to: dir.appendingPathComponent("editor-forwarding-remote.png"), dark: true)
        render(TunnelEditorView(request: jump, initialTab: .forwarding).environment(model),
               size: NSSize(width: 680, height: 640), to: dir.appendingPathComponent("editor-forwarding-disabled.png"), dark: true)

        render(MenuBarPanel().environment(model), size: NSSize(width: 330, height: 470), to: dir.appendingPathComponent("menubar.png"), dark: true)

        // Offscreen captures paint the selected sidebar row black, so the row switch is checked here
        // on a hand-made accent row instead.
        render(RowSwitchSwatch(), size: NSSize(width: 420, height: 150), to: dir.appendingPathComponent("row-switch-light.png"), dark: false)
        render(RowSwitchSwatch(), size: NSSize(width: 420, height: 150), to: dir.appendingPathComponent("row-switch-dark.png"), dark: true)

        let hostKey = PromptRequest(tunnelID: tunnels[1].id, tunnelName: tunnels[1].displayName,
                                    kind: .hostKey(.init(host: "[jump.staging.acme.io]:2222", keyType: "ED25519", fingerprint: "SHA256:9pM1f3RkQh0vXo2y8Zt1cW5bN7aLsE4dUiGjPfKrT6o")),
                                    message: "", rememberAccount: nil)
        render(PromptView(request: hostKey, onFinish: { _, _ in }), size: NSSize(width: 440, height: 330), to: dir.appendingPathComponent("prompt-hostkey.png"), dark: false)
        let pw = PromptRequest(tunnelID: tunnels[3].id, tunnelName: tunnels[3].displayName, kind: .password,
                               message: "Password for support@gw.customer.example", rememberAccount: "demo")
        render(PromptView(request: pw, onFinish: { _, _ in }), size: NSSize(width: 440, height: 250), to: dir.appendingPathComponent("prompt-password.png"), dark: true)

        render(SettingsView().environment(model), size: NSSize(width: 520, height: 720), to: dir.appendingPathComponent("settings.png"), dark: false)
        // Each tab at the height it asks for, to catch content that no longer fits.
        render(GeneralSettings().environment(model).frame(width: 520), size: NSSize(width: 520, height: 580),
               to: dir.appendingPathComponent("settings-general.png"), dark: false)
        render(AdvancedSettings().environment(model).frame(width: 520), size: NSSize(width: 520, height: 300),
               to: dir.appendingPathComponent("settings-advanced.png"), dark: true)
        render(DataSettings().environment(model).frame(width: 520), size: NSSize(width: 520, height: 400),
               to: dir.appendingPathComponent("settings-data.png"), dark: false)

        print("Snapshots written to \(dir.path)")
        exit(0)
    }

    static func render<V: View>(_ view: V, size: NSSize, to url: URL, dark: Bool) {
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = SnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFrontRegardless()
        window.makeKey()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        window.orderOut(nil)
    }
}

/// Borderless windows can't normally become key; snapshots want the focused look.
private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// The row switch on and off, on a plain row and on a selected (accent, emphasized) row.
private struct RowSwitchSwatch: View {
    var body: some View {
        VStack(spacing: 10) {
            row(selected: false)
            row(selected: true)
        }
        .padding(16)
    }

    func row(selected: Bool) -> some View {
        HStack(spacing: 18) {
            Text(selected ? "Selected" : "Plain")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
            Spacer()
            Toggle("", isOn: .constant(false)).toggleStyle(RowSwitchStyle()).labelsHidden()
            Toggle("", isOn: .constant(true)).toggleStyle(RowSwitchStyle()).labelsHidden()
            Toggle("", isOn: .constant(true)).toggleStyle(RowSwitchStyle()).labelsHidden().disabled(true)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.backgroundProminence, selected ? .increased : .standard)
    }
}
