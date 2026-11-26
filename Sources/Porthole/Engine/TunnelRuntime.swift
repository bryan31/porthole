import AppKit
import Foundation
import Observation
import PortholeCore

/// Live state of one tunnel: owns the ssh process, parses its output and handles reconnects.
@MainActor
@Observable
final class TunnelRuntime {
    let tunnelID: UUID

    private(set) var state: TunnelState = .off {
        didSet { if state != oldValue { DebugLog.write("[\(tunnel?.displayName ?? tunnelID.uuidString)] state -> \(state)") } }
    }
    private(set) var connectedSince: Date?
    private(set) var lastError: String?
    private(set) var hostKey: String?
    private(set) var authenticatedWith: String?
    private(set) var reconnectCount = 0
    private(set) var forwardStatus: [UUID: ForwardStatus] = [:]
    private(set) var logs: [LogEntry] = []

    /// Whether the user wants this tunnel on.
    private(set) var desiredOn = false

    @ObservationIgnored weak var manager: TunnelManager?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var tunnel: Tunnel?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var stabilityTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var killTask: Task<Void, Never>?
    @ObservationIgnored private var stderrBuffer = Data()
    @ObservationIgnored private var fatalMessage: String?
    /// Consecutive runs that ended because a forwarding rule could not be set up.
    @ObservationIgnored private var forwardFailures = 0
    @ObservationIgnored private var forwardFailedThisRun = false
    @ObservationIgnored private var networkProblemThisRun = false
    @ObservationIgnored private var configProblem: String?
    @ObservationIgnored private var restartRequested = false
    @ObservationIgnored private var usedSavedPassword = false
    @ObservationIgnored private var usedSavedJumpPassword = false
    @ObservationIgnored private var usedSavedPassphrases: Set<String> = []
    @ObservationIgnored private var nextLogID: UInt64 = 0
    @ObservationIgnored private var wasConnectedThisRun = false
    /// ssh reached its main loop after every local rule was listening. A jump host's own ssh also
    /// prints "Entering interactive session", but before Porthole's rules exist, so it doesn't count.
    @ObservationIgnored private var sessionReadyAfterLocals = false
    /// Bumped by every launch and stop, so a slow pre-flight check can tell it is out of date.
    @ObservationIgnored private var launchGeneration = 0

    static let maxLogEntries = 2_000

    init(tunnelID: UUID) {
        self.tunnelID = tunnelID
    }

    var pid: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    private var name: String { tunnel?.displayName ?? String(localized: "Tunnel") }

    // MARK: Public control

    func start(_ tunnel: Tunnel) {
        retryTask?.cancel()
        desiredOn = true
        attempt = 0
        reconnectCount = 0
        forwardFailures = 0
        lastError = nil
        if let process, process.isRunning {
            // The previous ssh is still shutting down (Disconnect, then Connect right away):
            // start again as soon as it has exited instead of running two at once.
            self.tunnel = tunnel
            if state == .disconnecting {
                restartRequested = true
                state = .connecting
            }
            return
        }
        launch(tunnel)
    }

    func stop() {
        desiredOn = false
        launchGeneration += 1
        retryTask?.cancel()
        retryTask = nil
        manager?.prompts.cancel(tunnelID: tunnelID)
        if let process, process.isRunning {
            state = .disconnecting
            log(.info, String(localized: "Disconnecting…"))
            terminate(process)
        } else {
            process = nil
            state = .off
            clearForwardStatus()
        }
    }

    /// Restart immediately (settings changed, wake from sleep).
    func restart(with tunnel: Tunnel, reason: String) {
        guard desiredOn else { return }
        self.tunnel = tunnel
        log(.info, reason)
        retryTask?.cancel()
        if let process, process.isRunning {
            restartRequested = true
            terminate(process)
        } else {
            attempt = 0
            launch(tunnel)
        }
    }

    func retryNow() {
        guard desiredOn, case .reconnecting = state, let tunnel = manager?.store.tunnel(tunnelID) ?? tunnel else { return }
        retryTask?.cancel()
        launch(tunnel)
    }

    /// Synchronous best-effort shutdown used when the app quits.
    func terminateForQuit() {
        desiredOn = false
        retryTask?.cancel()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func clearLog() {
        logs.removeAll()
    }

    // MARK: Launch

    private func launch(_ tunnel: Tunnel) {
        guard let manager else { return }
        launchGeneration += 1
        let generation = launchGeneration
        self.tunnel = tunnel
        fatalMessage = nil
        configProblem = nil
        networkProblemThisRun = false
        forwardFailedThisRun = false
        sessionReadyAfterLocals = false
        usedSavedPassword = false
        usedSavedJumpPassword = false
        usedSavedPassphrases = []
        wasConnectedThisRun = false
        hostKey = nil
        authenticatedWith = nil
        connectedSince = nil

        let errors = TunnelValidator.validate(tunnel).filter { $0.severity == .error }
        if let first = errors.first {
            fail(first.message)
            return
        }

        for f in tunnel.enabledForwardings { forwardStatus[f.id] = .pending }
        for f in tunnel.forwardings where !f.enabled { forwardStatus[f.id] = .idle }
        state = .connecting
        let host = tunnel.hostNotation
        log(.info, attempt > 0 ? String(localized: "Reconnecting to \(host) (attempt \(attempt))…") : String(localized: "Connecting to \(host)…"))

        // Pre-flight: make sure local listening ports are free so the user gets a clear message.
        // lsof can take a moment, so it runs off the main thread.
        let checks = tunnel.enabledForwardings.filter(\.kind.listensLocally).map { (id: $0.id, port: $0.port, bind: $0.bindAddress) }
        let ownPIDs = manager.runningPIDs
        Task { [weak self] in
            let conflict = await Task.detached(priority: .userInitiated) { () -> (id: UUID, message: String)? in
                for check in checks {
                    if let message = PortInspector.conflict(port: check.port, bindAddress: check.bind, ignoringPIDs: ownPIDs) {
                        return (check.id, message)
                    }
                }
                return nil
            }.value
            guard let self, generation == self.launchGeneration, self.desiredOn else { return }
            if let conflict {
                self.forwardStatus[conflict.id] = .failed(conflict.message)
                self.fail(conflict.message)
                return
            }
            self.spawn(tunnel)
        }
    }

    private func spawn(_ tunnel: Tunnel) {
        guard let manager else { return }
        var builder = SSHCommandBuilder(context: .init(sshPath: manager.sshPath, helperExecutable: Bundle.main.executablePath))
        builder.context.verbose = true
        let arguments = builder.arguments(for: tunnel)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: manager.sshPath)
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = Bundle.main.executablePath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env[AskpassEnvironment.socketPath] = manager.askpass.socketPath
        env[AskpassEnvironment.token] = manager.askpass.token
        env[AskpassEnvironment.tunnelID] = tunnelID.uuidString
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        stderrBuffer = Data()

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.consume(data)
            }
        }
        p.terminationHandler = { [weak self, weak manager] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            let pid = proc.processIdentifier
            Task { @MainActor [weak self] in
                // Even if this tunnel was deleted meanwhile, its PID must leave the registry.
                manager?.processEnded(pid)
                errPipe.fileHandleForReading.readabilityHandler = nil
                let rest = errPipe.fileHandleForReading.readDataToEndOfFile()
                self?.consume(rest)
                self?.flushStderr()
                self?.processExited(proc, status: status, reason: reason)
            }
        }

        log(.debug, "$ " + builder.displayCommand(for: tunnel))

        do {
            try p.run()
            process = p
            manager.processStarted(p.processIdentifier)
        } catch {
            fail(String(localized: "Could not start ssh: \(error.localizedDescription)"))
        }
    }

    // MARK: Output

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        while let nl = stderrBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stderrBuffer[stderrBuffer.startIndex..<nl]
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...nl)
            handleLine(String(decoding: lineData, as: UTF8.self))
        }
    }

    private func flushStderr() {
        if !stderrBuffer.isEmpty {
            handleLine(String(decoding: stderrBuffer, as: UTF8.self))
            stderrBuffer = Data()
        }
    }

    private func handleLine(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\r")))
        guard !line.isEmpty else { return }
        let parsed = SSHLogParser.parse(line)
        log(parsed.level, parsed.message)
        if let event = parsed.event { handle(event) }
    }

    private func handle(_ event: SSHEvent) {
        guard let tunnel else { return }
        switch event {
        case .serverHostKey(let type, let fingerprint):
            hostKey = "\(type) \(fingerprint)"
        case .authenticated(let method):
            // Only a sign-in; the tunnel counts as up once its rules are (see updateConnected).
            // With a jump host this may even be the jump host's sign-in.
            authenticatedWith = method
        case .sessionReady:
            if localsUp {
                sessionReadyAfterLocals = true
                updateConnected()
            } else {
                probeLocalForwards()
            }
        case .localForwardListening(let port):
            for f in tunnel.enabledForwardings where f.kind.listensLocally && f.port == port {
                forwardStatus[f.id] = .active
            }
            updateConnected()
        case .remoteForwardSuccess(let port):
            for f in tunnel.enabledForwardings where f.kind == .remote && f.port == port {
                forwardStatus[f.id] = .active
            }
            updateConnected()
        case .forwardFailed(let port, let remote, let message):
            forwardFailedThisRun = true
            lastError = message
            for f in tunnel.enabledForwardings where (port == nil || f.port == port) && (f.kind == .remote) == remote {
                if forwardStatus[f.id] != .active || port != nil { forwardStatus[f.id] = .failed(message) }
            }
        case .authFailed, .hostKeyProblem:
            fatalMessage = SSHLogParser.friendlyMessage(for: event)
            lastError = fatalMessage
        case .configError:
            // Some of these are only warnings (e.g. an option this ssh doesn't support) and ssh
            // carries on; it only matters if ssh then gives up before reaching the network.
            configProblem = SSHLogParser.friendlyMessage(for: event)
        case .connectionFailed, .disconnected:
            networkProblemThisRun = true
            lastError = SSHLogParser.friendlyMessage(for: event)
        case .connecting, .connectionEstablished:
            break
        }
    }

    private var localsUp: Bool {
        guard let tunnel else { return false }
        return tunnel.enabledForwardings.filter(\.kind.listensLocally).allSatisfy { forwardStatus[$0.id] == .active }
    }

    private var remotesUp: Bool {
        guard let tunnel else { return false }
        return tunnel.enabledForwardings.filter { $0.kind == .remote }.allSatisfy { forwardStatus[$0.id] == .active }
    }

    /// The tunnel is up when ssh has entered its main loop with every local rule listening and
    /// the server has confirmed every remote rule. Remote confirmations arrive after the main loop starts.
    private func updateConnected() {
        if sessionReadyAfterLocals && remotesUp { markConnected() }
    }

    /// ssh normally logs "Local forwarding listening on …"; if a build doesn't, look for the listeners.
    private func probeLocalForwards() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, self.process?.isRunning == true, let tunnel = self.tunnel else { return }
            for f in tunnel.enabledForwardings where f.kind.listensLocally && self.forwardStatus[f.id] == .pending {
                let host = (f.bindAddress.isEmpty || f.bindAddress == "localhost" || f.bindAddress == "*") ? "127.0.0.1" : f.bindAddress
                if PortInspector.isListening(port: f.port, host: host) { self.forwardStatus[f.id] = .active }
            }
            if self.localsUp {
                self.sessionReadyAfterLocals = true
                self.updateConnected()
            }
        }
    }

    private func markConnected() {
        guard desiredOn, state != .connected, process?.isRunning == true else { return }
        let wasReconnect = reconnectCount > 0 || attempt > 0
        state = .connected
        connectedSince = Date()
        wasConnectedThisRun = true
        lastError = nil
        log(.success, String(localized: "Tunnel is up."))
        if wasReconnect {
            manager?.notify(tunnelID: tunnelID, title: String(localized: "\(name) reconnected"), body: String(localized: "All forwarding rules are active again."), isFailure: false)
        } else {
            manager?.notify(tunnelID: tunnelID, title: String(localized: "\(name) connected"), body: tunnel?.enabledForwardings.map(\.commandString).joined(separator: "  ") ?? "", isFailure: false, onlyIfConnectNotifications: true)
        }

        // Reset the backoff once the connection has been stable for a while.
        stabilityTask?.cancel()
        stabilityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.state == .connected else { return }
            self.attempt = 0
            self.forwardFailures = 0
        }
    }

    // MARK: Exit / reconnect

    private func processExited(_ p: Process, status: Int32, reason: Process.TerminationReason) {
        guard p === process else { return }
        manager?.processEnded(p.processIdentifier)
        process = nil
        killTask?.cancel()
        stabilityTask?.cancel()
        probeTask?.cancel()
        manager?.prompts.cancel(tunnelID: tunnelID)
        connectedSince = nil
        let wasConnected = wasConnectedThisRun

        if restartRequested, desiredOn, let tunnel = manager?.store.tunnel(tunnelID) ?? tunnel {
            restartRequested = false
            attempt = 0
            launch(tunnel)
            return
        }
        restartRequested = false

        guard desiredOn else {
            state = .off
            clearForwardStatus()
            log(.info, String(localized: "Disconnected."))
            return
        }

        let code = Int(status)
        if fatalMessage == nil, !wasConnected, !networkProblemThisRun, let configProblem {
            fatalMessage = configProblem
        }
        let message = fatalMessage ?? lastError ?? String(localized: "ssh exited unexpectedly (status \(code)).")
        if fatalMessage != nil {
            fail(message)
            return
        }

        if forwardFailedThisRun { forwardFailures += 1 }
        let allowRetry = (tunnel?.autoReconnect ?? true) && forwardFailures < 5
        if allowRetry {
            attempt += 1
            reconnectCount += 1
            let delay = ReconnectPolicy.delay(forAttempt: attempt)
            let at = Date().addingTimeInterval(delay)
            state = .reconnecting(attempt: attempt, at: at)
            for (id, s) in forwardStatus where s == .active { forwardStatus[id] = .pending }
            let sentence = SSHLogParser.sentence(message)
            let seconds = Int(delay)
            log(.warning, String(localized: "Connection lost: \(sentence) Retrying in \(seconds) s."))
            if wasConnected {
                manager?.notify(tunnelID: tunnelID, title: String(localized: "\(name) disconnected"),
                                body: String(localized: "\(sentence) Porthole will keep trying to reconnect."), isFailure: true)
            }
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.desiredOn else { return }
                if let latest = self.manager?.store.tunnel(self.tunnelID) ?? self.tunnel {
                    self.launch(latest)
                }
            }
        } else {
            fail(message)
        }
    }

    private func fail(_ message: String) {
        desiredOn = false
        state = .failed(message)
        lastError = message
        connectedSince = nil
        for (id, s) in forwardStatus where s == .pending || s == .active { forwardStatus[id] = .idle }
        log(.error, message)
        manager?.notify(tunnelID: tunnelID, title: String(localized: "\(name) failed"), body: message, isFailure: true)
    }

    private func terminate(_ process: Process) {
        process.terminate()
        killTask?.cancel()
        let pid = process.processIdentifier
        killTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    private func clearForwardStatus() {
        for key in forwardStatus.keys { forwardStatus[key] = .idle }
    }

    func log(_ level: LogLevel, _ message: String) {
        DebugLog.write("[\(tunnel?.displayName ?? tunnelID.uuidString)] \(level.rawValue): \(message)")
        nextLogID += 1
        logs.append(LogEntry(id: nextLogID, level: level, message: message))
        if logs.count > Self.maxLogEntries { logs.removeFirst(logs.count - Self.maxLogEntries) }
    }

    // MARK: Prompts

    func answer(_ request: AskpassRequest) async -> AskpassReply {
        guard let manager, let tunnel = tunnel ?? manager.store.tunnel(tunnelID) else { return .cancelled }
        guard desiredOn else { return .cancelled }

        if request.kind == .proxyPassword {
            if let saved = Keychain.get(Keychain.proxyPassword(tunnelID)) { return AskpassReply(ok: true, answer: saved) }
            let response = await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .proxyPassword,
                                               message: String(localized: "Password for proxy user “\(tunnel.proxy.username)” at \(tunnel.proxy.host)"),
                                               rememberAccount: Keychain.proxyPassword(tunnelID)))
            return response
        }

        let kind = PromptClassifier.classify(request.prompt)
        DebugLog.write("[\(tunnel.displayName)] askpass prompt classified as \(kind)")
        switch kind {
        case .password:
            // With a jump host, ssh asks for the jump host's password first. Keep the two apart so
            // the server's saved password is never sent to the jump host (and vice versa).
            let jump = PromptClassifier.isJumpHostPrompt(request.prompt, tunnel: tunnel)
            let account = jump ? Keychain.jumpHostPassword(tunnelID) : Keychain.tunnelPassword(tunnelID)
            let alreadyUsed = jump ? usedSavedJumpPassword : usedSavedPassword
            if !alreadyUsed, let saved = Keychain.get(account) {
                if jump { usedSavedJumpPassword = true } else { usedSavedPassword = true }
                log(.info, jump ? String(localized: "Using the jump host password saved in your Keychain.")
                                : String(localized: "Using the password saved in your Keychain."))
                return AskpassReply(ok: true, answer: saved)
            }
            if alreadyUsed { log(.warning, String(localized: "The saved password was not accepted.")) }
            let message: String
            if jump {
                let jumpHost = tunnel.proxy.notation
                message = String(localized: "Password for jump host \(jumpHost)")
            } else {
                message = String(localized: "Password for \(tunnel.hostNotation)")
            }
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .password,
                                       message: message, rememberAccount: account))
        case .passphrase(let keyPath):
            let path = PromptClassifier.resolveKeyPath(fromPrompt: keyPath, identityFile: tunnel.identityFile)
            let account = Keychain.keyPassphrase(path)
            if !usedSavedPassphrases.contains(account), let saved = Keychain.get(account) {
                usedSavedPassphrases.insert(account)
                log(.info, String(localized: "Using the key passphrase saved in your Keychain."))
                return AskpassReply(ok: true, answer: saved)
            }
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .passphrase,
                                       message: String(localized: "Passphrase for key \((path as NSString).abbreviatingWithTildeInPath)"), rememberAccount: account))
        case .hostKey(let host, let keyType, let fingerprint):
            let detail = PromptRequest.HostKeyDetail(host: host ?? tunnel.hostNotation, keyType: keyType ?? "", fingerprint: fingerprint ?? "")
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .hostKey(detail),
                                       message: request.prompt, rememberAccount: nil))
        case .confirmation:
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .confirm,
                                       message: request.prompt, rememberAccount: nil))
        case .proxyPassword, .other:
            return await present(.init(tunnelID: tunnelID, tunnelName: tunnel.displayName, kind: .secret,
                                       message: request.prompt.trimmingCharacters(in: .whitespacesAndNewlines), rememberAccount: nil))
        }
    }

    private func present(_ request: PromptRequest) async -> AskpassReply {
        guard let manager else { return .cancelled }
        let previous = state
        state = .waitingForUser
        let reply = await manager.prompts.ask(request)
        if state == .waitingForUser { state = previous == .waitingForUser ? .connecting : previous }
        if !reply.ok { log(.warning, String(localized: "Prompt cancelled.")) }
        return reply
    }

    // MARK: Demo support (snapshots)

    func applyDemo(state: TunnelState, connectedSince: Date? = nil, hostKey: String? = nil, auth: String? = nil,
                   forwardStatus: [UUID: ForwardStatus] = [:], logs: [(LogLevel, String)] = [], lastError: String? = nil, reconnects: Int = 0) {
        self.state = state
        self.connectedSince = connectedSince
        self.hostKey = hostKey
        self.authenticatedWith = auth
        self.forwardStatus = forwardStatus
        self.lastError = lastError
        self.reconnectCount = reconnects
        self.desiredOn = state.isActive
        for (level, message) in logs { log(level, message) }
    }
}


/// Optional plain-text mirror of every tunnel log line, enabled with `PORTHOLE_DEBUG_LOG=/path/file.log`.
enum DebugLog {
    private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["PORTHOLE_DEBUG_LOG"], !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func write(_ line: String) {
        guard let handle else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        handle.seekToEndOfFile()
        handle.write(Data("\(stamp) \(line)\n".utf8))
    }
}
