import Foundation
import Observation
import PortholeCore

/// Persists tunnels and smart groups as JSON in Application Support.
@MainActor
@Observable
final class TunnelStore {
    private(set) var tunnels: [Tunnel] = []
    private(set) var smartGroups: [SmartGroup] = []
    private(set) var loadError: String?

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Porthole", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `PORTHOLE_DATA_FILE` lets developers run against a scratch file instead of their real tunnels.
    nonisolated static var defaultFileURL: URL {
        if let custom = ProcessInfo.processInfo.environment["PORTHOLE_DATA_FILE"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return supportDirectory.appendingPathComponent("tunnels.json")
    }

    /// `fileURL == nil` keeps everything in memory (used for snapshots).
    init(fileURL: URL? = TunnelStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    convenience init(inMemory document: PortholeDocument) {
        self.init(fileURL: nil)
        tunnels = document.tunnels
        smartGroups = document.smartGroups
    }

    func tunnel(_ id: UUID) -> Tunnel? { tunnels.first { $0.id == id } }

    // MARK: Mutations

    func add(_ tunnel: Tunnel) {
        tunnels.append(tunnel)
        scheduleSave()
    }

    @discardableResult
    func update(_ tunnel: Tunnel) -> Tunnel? {
        guard let i = tunnels.firstIndex(where: { $0.id == tunnel.id }) else {
            add(tunnel)
            return nil
        }
        let old = tunnels[i]
        tunnels[i] = tunnel
        scheduleSave()
        return old
    }

    func delete(_ ids: Set<UUID>) {
        tunnels.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    @discardableResult
    func duplicate(_ ids: [UUID]) -> [UUID] {
        var created: [UUID] = []
        for id in ids {
            guard let i = tunnels.firstIndex(where: { $0.id == id }) else { continue }
            let copy = tunnels[i].duplicated()
            tunnels.insert(copy, at: i + 1)
            created.append(copy.id)
        }
        scheduleSave()
        return created
    }

    func move(from source: IndexSet, to destination: Int) {
        tunnels.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func setAutoConnect(_ id: UUID, _ value: Bool) {
        guard let i = tunnels.firstIndex(where: { $0.id == id }) else { return }
        tunnels[i].autoConnect = value
        scheduleSave()
    }

    func addSmartGroup(_ group: SmartGroup) {
        smartGroups.append(group)
        scheduleSave()
    }

    func updateSmartGroup(_ group: SmartGroup) {
        guard let i = smartGroups.firstIndex(where: { $0.id == group.id }) else { return }
        smartGroups[i] = group
        scheduleSave()
    }

    func deleteSmartGroup(_ id: UUID) {
        smartGroups.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Import / export

    enum ImportSource { case portholeOrLegacy, sshConfig }

    /// Imports tunnels and returns how many were added. Tunnels with an existing id are skipped.
    func importData(_ data: Data, source: ImportSource) throws -> Int {
        var incoming: [Tunnel] = []
        var groups: [SmartGroup] = []
        switch source {
        case .sshConfig:
            incoming = SSHConfigImporter.tunnels(fromConfig: String(decoding: data, as: UTF8.self))
        case .portholeOrLegacy:
            if let doc = try? PortholeDocument.decoder().decode(PortholeDocument.self, from: data),
               !doc.tunnels.isEmpty || !doc.smartGroups.isEmpty,
               doc.tunnels.allSatisfy({ !$0.host.isEmpty }) {
                incoming = doc.tunnels
                groups = doc.smartGroups
            } else {
                incoming = try LegacySSHTunnelImporter.tunnels(from: data)
            }
        }
        let existing = Set(tunnels.map(\.id))
        let fresh = incoming.filter { !existing.contains($0.id) }
        tunnels.append(contentsOf: fresh)
        let existingGroups = Set(smartGroups.map(\.id))
        smartGroups.append(contentsOf: groups.filter { !existingGroups.contains($0.id) })
        scheduleSave()
        return fresh.count
    }

    func exportData(_ ids: Set<UUID>?) throws -> Data {
        let selected = ids.map { set in tunnels.filter { set.contains($0.id) } } ?? tunnels
        let doc = PortholeDocument(tunnels: selected, smartGroups: ids == nil ? smartGroups : [])
        return try PortholeDocument.encoder().encode(doc)
    }

    // MARK: Persistence

    private func load() {
        guard let fileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let doc = try PortholeDocument.decoder().decode(PortholeDocument.self, from: data)
            tunnels = doc.tunnels
            smartGroups = doc.smartGroups
        } catch {
            let path = fileURL.path, reason = error.localizedDescription
            loadError = String(localized: "Could not read \(path): \(reason)")
            // Keep a copy so nothing is lost when the next save overwrites the file.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
        }
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let fileURL else { return }
        do {
            let data = try PortholeDocument.encoder().encode(PortholeDocument(tunnels: tunnels, smartGroups: smartGroups))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Porthole: save failed: \(error)")
        }
    }
}
