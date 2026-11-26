import AppKit
import Observation
import PortholeCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarFilter: Hashable {
    case all
    case active
    case autoStart
    case group(UUID)
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var tunnel: Tunnel
    var isNew: Bool
}

struct LogRequest: Identifiable {
    let id: UUID
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum Presentation: String, CaseIterable, Identifiable {
    case both, menuBarOnly, dockOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return String(localized: "Dock and menu bar")
        case .menuBarOnly: return String(localized: "Menu bar only")
        case .dockOnly: return String(localized: "Dock only")
        }
    }
}

/// UI-level state shared by the main window, menu bar panel and menu commands.
@MainActor
@Observable
final class AppModel {
    let store: TunnelStore
    let manager: TunnelManager
    let prompts: PromptPresenter

    var selection: Set<UUID> = []
    var filter: SidebarFilter = .all
    var searchText = ""
    var editor: EditorRequest?
    var logRequest: LogRequest?
    var smartGroupEditor: SmartGroup?
    var pendingDeletion: Set<UUID>?
    var alert: AppAlert?
    /// Light, dark or follow the system. Applied app-wide (windows, menu bar panel, prompts).
    var appearance: AppearanceMode = .stored {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: SettingsKey.appearance)
            appearance.apply()
        }
    }

    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    init(store: TunnelStore) {
        self.store = store
        let prompts = PromptPresenter()
        self.prompts = prompts
        self.manager = TunnelManager(store: store, prompts: prompts)
    }

    // MARK: Derived

    var visibleTunnels: [Tunnel] {
        var list = store.tunnels
        switch filter {
        case .all: break
        case .active: list = list.filter { manager.isOn($0.id) || manager.state($0.id).isBusy }
        case .autoStart: list = list.filter(\.autoConnect)
        case .group(let id):
            if let g = store.smartGroups.first(where: { $0.id == id }) {
                list = list.filter { $0.matches(query: g.keywords) }
            }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.matches(query: q) } }
        return list
    }

    var canReorder: Bool { filter == .all && searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func count(for filter: SidebarFilter) -> Int {
        switch filter {
        case .all: return store.tunnels.count
        case .active: return store.tunnels.filter { manager.isOn($0.id) || manager.state($0.id).isBusy }.count
        case .autoStart: return store.tunnels.filter(\.autoConnect).count
        case .group(let id):
            guard let g = store.smartGroups.first(where: { $0.id == id }) else { return 0 }
            return store.tunnels.filter { $0.matches(query: g.keywords) }.count
        }
    }

    var selectedTunnels: [Tunnel] { store.tunnels.filter { selection.contains($0.id) } }

    /// Context-menu target: the clicked row, or the whole selection when the row is part of it.
    func targets(for id: UUID) -> Set<UUID> {
        selection.contains(id) ? selection : [id]
    }

    // MARK: Actions

    func newTunnel() {
        var t = Tunnel()
        t.forwardings = [Forwarding(kind: .local, port: 8080, targetHost: "localhost", targetPort: 80)]
        editor = EditorRequest(tunnel: t, isNew: true)
        showMainWindow()
    }

    func edit(_ id: UUID) {
        guard let t = store.tunnel(id) else { return }
        editor = EditorRequest(tunnel: t, isNew: false)
        showMainWindow()
    }

    func save(_ tunnel: Tunnel, isNew: Bool) {
        if isNew {
            store.add(tunnel)
            selection = [tunnel.id]
            filter = .all
        } else {
            let old = store.update(tunnel)
            manager.tunnelDidChange(tunnel, old: old)
        }
    }

    func duplicate(_ ids: Set<UUID>) {
        let ordered = store.tunnels.map(\.id).filter { ids.contains($0) }
        let created = store.duplicate(ordered)
        selection = Set(created)
    }

    func requestDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
    }

    func confirmDelete() {
        guard let ids = pendingDeletion else { return }
        manager.tunnelsWillBeDeleted(Array(ids))
        store.delete(ids)
        selection.subtract(ids)
        pendingDeletion = nil
    }

    func copyCommand(_ id: UUID) {
        guard let t = store.tunnel(id) else { return }
        let builder = SSHCommandBuilder(context: .init(sshPath: manager.sshPath, helperExecutable: Bundle.main.executablePath))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(builder.displayCommand(for: t), forType: .string)
    }

    func showLog(_ id: UUID) {
        logRequest = LogRequest(id: id)
        showMainWindow()
    }

    func newSmartGroup() {
        smartGroupEditor = SmartGroup(name: "", keywords: searchText)
        showMainWindow()
    }

    func toggleAppearance() {
        appearance = appearance.toggled
    }

    func showMainWindow() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Import / export

    func importFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Tunnels")
        panel.message = String(localized: "Choose a Porthole export, or a file exported from SSH Tunnel (File ▸ Export Selected Tunnels…).")
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var total = 0
        for url in panel.urls {
            do {
                total += try store.importData(try Data(contentsOf: url), source: .portholeOrLegacy)
            } catch {
                alert = AppAlert(title: String(localized: "Couldn't import “\(url.lastPathComponent)”"), message: error.localizedDescription)
                return
            }
        }
        alert = AppAlert(title: total == 0 ? String(localized: "Nothing to import") : String(localized: "Imported \(total) tunnels"),
                         message: total == 0 ? String(localized: "No new tunnels were found in the selected file.")
                             : String(localized: "Passwords are not part of exports; you'll be asked for them on first connect."))
    }

    func importSSHConfig() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let data = try? Data(contentsOf: url) else {
            alert = AppAlert(title: String(localized: "No SSH config found"), message: String(localized: "Porthole looked for \(url.path)."))
            return
        }
        let count = (try? store.importData(data, source: .sshConfig)) ?? 0
        alert = AppAlert(title: count == 0 ? String(localized: "No forwarding hosts found") : String(localized: "Imported \(count) tunnels"),
                         message: count == 0 ? String(localized: "Only Host entries with LocalForward, RemoteForward or DynamicForward are imported.")
                             : String(localized: "They use your ~/.ssh/config settings for each host."))
    }

    func export(_ ids: Set<UUID>?) {
        let panel = NSSavePanel()
        panel.title = ids == nil ? String(localized: "Export All Tunnels") : String(localized: "Export Selected Tunnels")
        panel.nameFieldStringValue = ids == nil ? "Porthole Tunnels.json" : "Porthole Export.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData(ids).write(to: url, options: .atomic)
        } catch {
            alert = AppAlert(title: String(localized: "Export failed"), message: error.localizedDescription)
        }
    }
}
