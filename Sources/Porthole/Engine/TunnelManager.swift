import AppKit
import Foundation
import Observation
import PortholeCore

/// Owns every tunnel runtime plus the shared askpass server, wake and network handling.
@MainActor
@Observable
final class TunnelManager {
    let store: TunnelStore
    let prompts: PromptPresenter
    @ObservationIgnored let askpass: AskpassServer
    @ObservationIgnored private let network = NetworkWatcher()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private(set) var runningPIDs: Set<Int32> = []

    private(set) var runtimes: [UUID: TunnelRuntime] = [:]

    var sshPath: String {
        let custom = UserDefaults.standard.string(forKey: SettingsKey.sshPath) ?? ""
        return custom.isEmpty ? "/usr/bin/ssh" : custom
    }

    init(store: TunnelStore, prompts: PromptPresenter) {
        self.store = store
        self.prompts = prompts
        let box = WeakManagerBox()
        askpass = AskpassServer { request in
            guard let manager = await MainActor.run(body: { box.manager }) else { return .cancelled }
            return await manager.handle(request)
        }
        box.manager = self
    }

    private final class WeakManagerBox: @unchecked Sendable {
        weak var manager: TunnelManager?
    }

    // MARK: Lifecycle

    func startServices() {
        do {
            try askpass.start()
        } catch {
            NSLog("Porthole: could not start askpass server: \(error)")
        }
        PIDRegistry.killStale(sshPath: sshPath)

        network.onBecameReachable = { [weak self] in
            self?.networkBecameReachable()
        }
        network.start()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        })
    }

    func autoConnect() {
        let targets = store.tunnels.filter(\.autoConnect)
        for (index, tunnel) in targets.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250 * index))
                self.connect(tunnel.id)
            }
        }
    }

    func shutdown() {
        for runtime in runtimes.values { runtime.terminateForQuit() }
        // Give ssh a moment to close listeners cleanly.
        let deadline = Date().addingTimeInterval(1.5)
        while runtimes.values.contains(where: { $0.pid != nil }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        for pid in runningPIDs { kill(pid, SIGKILL) }
        PIDRegistry.save([])
        askpass.stop()
    }

    // MARK: Runtimes

    func runtime(_ id: UUID) -> TunnelRuntime {
        if let r = runtimes[id] { return r }
        let r = TunnelRuntime(tunnelID: id)
        r.manager = self
        runtimes[id] = r
        return r
    }

    func state(_ id: UUID) -> TunnelState { runtimes[id]?.state ?? .off }

    func isOn(_ id: UUID) -> Bool { runtimes[id]?.desiredOn ?? false }

    var connectedCount: Int { runtimes.values.filter { $0.state == .connected }.count }
    var activeCount: Int { runtimes.values.filter { $0.desiredOn || $0.state.isBusy }.count }
    var anyBusy: Bool { runtimes.values.contains { $0.state.isBusy } }
    var anyFailed: Bool { runtimes.values.contains { if case .failed = $0.state { return true } else { return false } } }

    func connect(_ id: UUID) {
        guard let tunnel = store.tunnel(id) else { return }
        runtime(id).start(tunnel)
    }

    func disconnect(_ id: UUID) {
        runtimes[id]?.stop()
    }

    func toggle(_ id: UUID) {
        if isOn(id) || state(id).isBusy { disconnect(id) } else { connect(id) }
    }

    func setOn(_ id: UUID, _ on: Bool) {
        if on { connect(id) } else { disconnect(id) }
    }

    func connect(_ ids: some Sequence<UUID>) {
        for (i, id) in ids.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150 * i))
                if !self.isOn(id) { self.connect(id) }
            }
        }
    }

    func disconnect(_ ids: some Sequence<UUID>) {
        for id in ids { disconnect(id) }
    }

    func connectAll() { connect(store.tunnels.map(\.id)) }
    func disconnectAll() { disconnect(Array(runtimes.keys)) }

    /// Called after a tunnel's settings were saved.
    func tunnelDidChange(_ tunnel: Tunnel, old: Tunnel?) {
        guard let r = runtimes[tunnel.id], r.desiredOn, old != tunnel else { return }
        r.restart(with: tunnel, reason: String(localized: "Settings changed – reconnecting with the new configuration."))
    }

    func tunnelsWillBeDeleted(_ ids: [UUID]) {
        for id in ids {
            runtimes[id]?.stop()
            runtimes[id] = nil
            Keychain.delete(Keychain.tunnelPassword(id))
            Keychain.delete(Keychain.proxyPassword(id))
            Keychain.delete(Keychain.jumpHostPassword(id))
        }
    }

    // MARK: Process bookkeeping

    func processStarted(_ pid: Int32) {
        runningPIDs.insert(pid)
        PIDRegistry.save(runningPIDs)
    }

    func processEnded(_ pid: Int32) {
        runningPIDs.remove(pid)
        PIDRegistry.save(runningPIDs)
    }

    // MARK: Events

    private func networkBecameReachable() {
        for r in runtimes.values {
            if case .reconnecting = r.state { r.retryNow() }
        }
    }

    private func systemDidWake() {
        guard UserDefaults.standard.object(forKey: SettingsKey.reconnectOnWake) as? Bool ?? true else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            for r in self.runtimes.values where r.desiredOn {
                if r.state == .connected, let tunnel = self.store.tunnel(r.tunnelID) {
                    r.restart(with: tunnel, reason: String(localized: "Mac woke from sleep – refreshing the connection."))
                } else if case .reconnecting = r.state {
                    r.retryNow()
                }
            }
        }
    }

    func notify(tunnelID: UUID, title: String, body: String, isFailure: Bool, onlyIfConnectNotifications: Bool = false) {
        let defaults = UserDefaults.standard
        if onlyIfConnectNotifications || !isFailure {
            guard defaults.object(forKey: SettingsKey.notifyOnConnect) as? Bool ?? false else { return }
        } else {
            guard defaults.object(forKey: SettingsKey.notifyOnFailure) as? Bool ?? true else { return }
        }
        Notifier.post(title: title, body: body)
    }

    // MARK: Askpass

    private func handle(_ request: AskpassRequest) async -> AskpassReply {
        guard let id = UUID(uuidString: request.tunnelID), let r = runtimes[id] else { return .cancelled }
        return await r.answer(request)
    }
}

/// Remembers ssh PIDs so tunnels orphaned by a crash can be cleaned up on next launch.
enum PIDRegistry {
    static var url: URL { TunnelStore.supportDirectory.appendingPathComponent("running-pids.json") }

    static func save(_ pids: Set<Int32>) {
        let data = (try? JSONEncoder().encode(Array(pids))) ?? Data("[]".utf8)
        try? data.write(to: url, options: .atomic)
    }

    static func killStale(sshPath: String) {
        guard let data = try? Data(contentsOf: url),
              let pids = try? JSONDecoder().decode([Int32].self, from: data) else { return }
        // An orphaned tunnel has been adopted by launchd. Anything else with a recorded PID is a
        // reused number (e.g. after a restart) and may be the user's own ssh session.
        for pid in pids where executablePath(pid) == sshPath && parentPID(pid) == 1 {
            kill(pid, SIGTERM)
        }
        save([])
    }

    static func parentPID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

enum SettingsKey {
    static let presentation = "presentation"
    static let reconnectOnWake = "reconnectOnWake"
    static let notifyOnFailure = "notifyOnFailure"
    static let notifyOnConnect = "notifyOnConnect"
    static let sshPath = "sshPath"
    static let appearance = "appearance"
}
