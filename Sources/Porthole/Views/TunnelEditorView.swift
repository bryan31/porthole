import AppKit
import PortholeCore
import SwiftUI

struct TunnelEditorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "Server"
        case forwarding = "Forwarding"
        case connection = "Connection"
        case advanced = "Advanced"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return String(localized: "Server")
            case .forwarding: return String(localized: "Forwarding")
            case .connection: return String(localized: "Connection")
            case .advanced: return String(localized: "Advanced")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "server.rack"
            case .forwarding: return "arrow.left.arrow.right"
            case .connection: return "network"
            case .advanced: return "gearshape.2"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let request: EditorRequest
    @State private var draft: Tunnel
    @State private var tab: Tab
    @State private var password = ""
    @State private var proxyPassword = ""
    @State private var attemptedSave = false
    /// Forwarding rules shown open. Kept here so switching tabs doesn't fold them again.
    @State private var expandedRules: Set<UUID>

    private let originalPassword: String
    private let originalProxyPassword: String

    init(request: EditorRequest, initialTab: Tab = .general, expandedRules: Set<UUID>? = nil) {
        self.request = request
        _draft = State(initialValue: request.tunnel)
        _tab = State(initialValue: initialTab)
        // A single rule opens ready to edit; several start folded so they read as a list.
        let rules = request.tunnel.forwardings
        _expandedRules = State(initialValue: expandedRules ?? (rules.count == 1 ? [rules[0].id] : []))
        let pw = request.isNew ? "" : (Keychain.get(Keychain.tunnelPassword(request.tunnel.id)) ?? "")
        let ppw = request.isNew ? "" : (Keychain.get(Keychain.proxyPassword(request.tunnel.id)) ?? "")
        originalPassword = pw
        originalProxyPassword = ppw
        _password = State(initialValue: pw)
        _proxyPassword = State(initialValue: ppw)
    }

    var body: some View {
        // Validated once per change; header, tabs and footer share the result.
        let issues = TunnelValidator.validate(draft)
        let visible = visibleIssues(issues)
        VStack(spacing: 0) {
            header(issues)
            Divider()
            Group {
                switch tab {
                case .general: GeneralTab(draft: $draft, password: $password, issues: visible)
                case .forwarding: ForwardingTab(draft: $draft, expanded: $expandedRules, issues: visible)
                case .connection: ConnectionTab(draft: $draft, proxyPassword: $proxyPassword, issues: visible)
                case .advanced: AdvancedTab(draft: $draft)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer(issues)
        }
        .frame(width: 680, height: 640)
    }

    func visibleIssues(_ issues: [ValidationIssue]) -> [ValidationIssue] {
        attemptedSave ? issues : issues.filter { issue in
            // Before the first save attempt, only complain about things the user typed.
            switch issue.field {
            case .forwarding: return true
            case .host: return !draft.host.isEmpty
            case .user: return !draft.user.isEmpty
            case .proxy: return !draft.proxy.host.isEmpty
            case .port: return true
            default: return false
            }
        }
    }

    func header(_ issues: [ValidationIssue]) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                TunnelBadge(state: .connected, size: 40, tint: Theme.sea)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.isNew ? String(localized: "New Tunnel") : String(localized: "Edit “\(request.tunnel.displayName)”"))
                        .font(.title3.weight(.semibold))
                    Text(draft.host.isEmpty ? String(localized: "Connect to an SSH server and choose which ports to forward.") : draft.hostNotation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.title, systemImage: t.symbol)
                        .badge(errorCount(for: t, issues))
                        .tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    func errorCount(for tab: Tab, _ issues: [ValidationIssue]) -> Int {
        guard attemptedSave else { return 0 }
        return issues.filter { $0.severity == .error && Self.tab(for: $0.field) == tab }.count
    }

    static func tab(for field: ValidationIssue.Field) -> Tab {
        switch field {
        case .name, .host, .port, .user, .identityFile: return .general
        case .forwardings, .forwarding: return .forwarding
        case .proxy: return .connection
        }
    }

    func footer(_ issues: [ValidationIssue]) -> some View {
        HStack(spacing: 10) {
            let errors = issues.filter { $0.severity == .error }
            if attemptedSave, let first = errors.first {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(errors.count == 1 ? first.message : String(localized: "\(first.message) (+\(errors.count - 1) more)"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if model.manager.state(draft.id).isActive && !request.isNew {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                Text("Saving reconnects this tunnel with the new settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if request.isNew {
                // One primary button: Return creates and connects, the plain button only creates.
                Button("Create Tunnel") { save(connect: false) }
                Button("Create & Connect") { save(connect: true) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Save") { save(connect: false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    func save(connect: Bool) {
        let errors = TunnelValidator.validate(draft).filter { $0.severity == .error }
        if let first = errors.first {
            attemptedSave = true
            withAnimation {
                tab = Self.tab(for: first.field)
                // A folded card must not hide what blocks the save.
                for error in errors {
                    if case .forwarding(let id) = error.field { expandedRules.insert(id) }
                }
            }
            return
        }
        var t = draft
        t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        t.host = t.host.trimmingCharacters(in: .whitespaces)
        t.user = t.user.trimmingCharacters(in: .whitespaces)
        if t.name.isEmpty { t.name = t.host }

        // Secrets go to the Keychain, never to the JSON file.
        let pwAccount = Keychain.tunnelPassword(t.id)
        if t.authMethod == .password || t.authMethod == .keyboardInteractive || t.authMethod == .automatic {
            if password != originalPassword {
                if password.isEmpty { Keychain.delete(pwAccount) } else { Keychain.set(password, for: pwAccount, label: "Porthole – \(t.displayName)") }
            }
        }
        let proxyAccount = Keychain.proxyPassword(t.id)
        if t.proxy.requiresPassword, proxyPassword != originalProxyPassword {
            if proxyPassword.isEmpty { Keychain.delete(proxyAccount) } else { Keychain.set(proxyPassword, for: proxyAccount, label: "Porthole proxy – \(t.displayName)") }
        } else if !t.proxy.requiresPassword {
            Keychain.delete(proxyAccount)
        }
        // A remembered jump host password belongs to that jump host and user only.
        let old = request.tunnel.proxy
        if t.proxy.kind != .jumpHost || t.proxy.host != old.host || t.proxy.username != old.username {
            Keychain.delete(Keychain.jumpHostPassword(t.id))
        }

        model.save(t, isNew: request.isNew)
        if connect { model.manager.connect(t.id) }
        dismiss()
    }
}

// MARK: - Shared bits

private struct IssueText: View {
    var issues: [ValidationIssue]

    var body: some View {
        ForEach(issues) { issue in
            Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(issue.severity == .error ? .red : .orange)
        }
    }
}

private struct HelpText: View {
    var text: Text
    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim string: String) { text = Text(string) }
    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension Binding where Value == Int {
    /// Text binding that tolerates empty input while typing.
    var text: Binding<String> {
        Binding<String>(
            get: { self.wrappedValue == 0 ? "" : String(self.wrappedValue) },
            set: { self.wrappedValue = Int($0.filter(\.isNumber).prefix(5)) ?? 0 }
        )
    }
}

private struct StepperRow: View {
    var title: LocalizedStringKey
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var text: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(text).monospacedDigit().foregroundStyle(.secondary)
                Stepper(value: $value, in: range, step: step) { Text(title) }.labelsHidden()
            }
        }
    }
}

// MARK: - Server tab

private struct GeneralTab: View {
    @Binding var draft: Tunnel
    @Binding var password: String
    var issues: [ValidationIssue]

    func issues(_ field: ValidationIssue.Field) -> [ValidationIssue] { issues.filter { $0.field == field } }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Production database"))
                TextField("Note", text: $draft.note, prompt: Text("Optional – searchable"), axis: .vertical)
                    .lineLimit(1...3)
            }

            Section("SSH Server") {
                TextField("Host", text: $draft.host, prompt: Text("server.example.com or 10.0.0.5"))
                    .textContentType(.URL)
                IssueText(issues: issues(.host))
                TextField("Port", text: $draft.port.text, prompt: Text("22"))
                IssueText(issues: issues(.port))
                TextField("User", text: $draft.user, prompt: Text(NSUserName()))
                IssueText(issues: issues(.user))
            }

            Section("Sign In") {
                Picker("Method", selection: $draft.authMethod) {
                    ForEach(AuthMethod.allCases) { Text($0.title).tag($0) }
                }
                switch draft.authMethod {
                case .automatic:
                    HelpText("Uses ssh-agent, your keys in ~/.ssh and ~/.ssh/config. If the server still wants a password, Porthole asks for it.")
                    SecureField("Password", text: $password, prompt: Text("Optional"))
                case .password:
                    SecureField("Password", text: $password, prompt: Text("Leave empty to be asked each time"))
                    HelpText("Saved securely in your macOS Keychain, never in Porthole's settings file.")
                case .publicKey:
                    KeyPicker(path: $draft.identityFile)
                    IssueText(issues: issues(.identityFile))
                    HelpText("If the key has a passphrase, Porthole asks once and can remember it in your Keychain. If the server also wants a one-time code after the key, Porthole asks for it.")
                case .keyboardInteractive:
                    SecureField("Password", text: $password, prompt: Text("Optional"))
                    HelpText("For servers with one-time codes or other prompts. Porthole shows each question from the server.")
                }
            }

            Section("Behavior") {
                Toggle("Connect when Porthole launches", isOn: $draft.autoConnect)
                Toggle("Reconnect automatically when the connection drops", isOn: $draft.autoReconnect)
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyPicker: View {
    @Binding var path: String
    /// Read once when shown: computing it in `body` opened every file in ~/.ssh on each keystroke.
    @State private var keys: [String] = []

    static func privateKeys() -> [String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { name in
            guard !name.hasSuffix(".pub"), !["config", "known_hosts", "known_hosts.old", "authorized_keys", "environment"].contains(name),
                  !name.hasPrefix(".") else { return false }
            let url = dir.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let head = String(decoding: handle.readData(ofLength: 64), as: UTF8.self)
            return head.contains("PRIVATE KEY")
        }
        .sorted()
        .map { "~/.ssh/\($0)" }
    }

    var body: some View {
        LabeledContent("Private key") {
            HStack {
                TextField("", text: $path, prompt: Text("~/.ssh/id_ed25519"))
                    .labelsHidden()
                Menu {
                    ForEach(keys, id: \.self) { key in
                        Button(key) { path = key }
                    }
                    if !keys.isEmpty { Divider() }
                    Button("Choose File…") { browse() }
                } label: {
                    Text("Choose")
                }
                .fixedSize()
            }
        }
        .onAppear { keys = Self.privateKeys() }
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a private key")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

// MARK: - Forwarding tab

private struct ForwardingTab: View {
    @Binding var draft: Tunnel
    @Binding var expanded: Set<UUID>
    var issues: [ValidationIssue]

    struct Preset {
        var title: String
        var kind: ForwardingKind
        var port: Int
        var target: Int
        var note: String
    }

    static var presets: [Preset] { [
        .init(title: "PostgreSQL", kind: .local, port: 5432, target: 5432, note: "PostgreSQL"),
        .init(title: "MySQL / MariaDB", kind: .local, port: 3306, target: 3306, note: "MySQL"),
        .init(title: "Redis", kind: .local, port: 6379, target: 6379, note: "Redis"),
        .init(title: "MongoDB", kind: .local, port: 27017, target: 27017, note: "MongoDB"),
        .init(title: String(localized: "Web app (8080 → 80)"), kind: .local, port: 8080, target: 80, note: "Web"),
        .init(title: String(localized: "Remote Desktop (3389)"), kind: .local, port: 3389, target: 3389, note: "RDP"),
        .init(title: String(localized: "VNC / Screen Sharing (5900)"), kind: .local, port: 5901, target: 5900, note: "VNC"),
        .init(title: String(localized: "Share local dev server (remote 8080 → 3000)"), kind: .remote, port: 8080, target: 3000,
              note: String(localized: "Dev server")),
    ] }

    /// A rule just added or duplicated, scrolled into view once it has been laid out.
    @State private var reveal: UUID?

    var allExpanded: Bool { draft.forwardings.allSatisfy { expanded.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            if draft.forwardings.isEmpty {
                ContentUnavailableView {
                    Label("No Forwarding Rules", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Add a rule to choose which ports travel through this tunnel.")
                } actions: {
                    addMenu.fixedSize()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            let general = issues.filter { $0.field == .forwardings }
                            if !general.isEmpty {
                                VStack(alignment: .leading, spacing: 4) { IssueText(issues: general) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach($draft.forwardings) { $f in
                                ForwardingCard(forwarding: $f,
                                               isExpanded: expandedBinding(f.id),
                                               tunnel: draft,
                                               serverName: draft.host.isEmpty ? String(localized: "the server") : draft.host,
                                               issues: issues.filter { $0.field == .forwarding(f.id) },
                                               canMoveUp: draft.forwardings.first?.id != f.id,
                                               canMoveDown: draft.forwardings.last?.id != f.id,
                                               onMove: { move(f.id, by: $0) },
                                               onDuplicate: { duplicate(f.id) },
                                               onDelete: { delete(f.id) })
                                    .id(f.id)
                            }
                        }
                        .padding(20)
                    }
                    .background(Theme.canvas)
                    .onChange(of: reveal) { _, id in
                        guard let id else { return }
                        DispatchQueue.main.async {
                            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
                            reveal = nil
                        }
                    }
                }
                Divider()
                HStack(spacing: 14) {
                    addMenu.fixedSize()
                    if draft.forwardings.count > 1 {
                        Button { toggleAll() } label: {
                            Label(allExpanded ? String(localized: "Collapse All") : String(localized: "Expand All"),
                                  systemImage: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(draft.enabledForwardings.count) of \(draft.forwardings.count) enabled")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
    }

    var addMenu: some View {
        Menu {
            Button { add(Forwarding(kind: .local, port: nextPort(8080), targetHost: "localhost", targetPort: 80)) } label: {
                Label("Local – reach a service behind the server", systemImage: ForwardingKind.local.symbolName)
            }
            Button { add(Forwarding(kind: .remote, port: 8080, targetHost: "localhost", targetPort: 3000)) } label: {
                Label("Remote – expose a service on this Mac", systemImage: ForwardingKind.remote.symbolName)
            }
            Button { add(Forwarding(kind: .dynamic, port: nextPort(1080), targetHost: "", targetPort: 0)) } label: {
                Label("SOCKS proxy – browse through the server", systemImage: ForwardingKind.dynamic.symbolName)
            }
            Divider()
            Section("Presets") {
                ForEach(Self.presets, id: \.title) { p in
                    Button(p.title) {
                        add(Forwarding(kind: p.kind, port: p.kind == .remote ? p.port : nextPort(p.port), targetHost: "localhost", targetPort: p.target, note: p.note))
                    }
                }
            }
        } label: {
            Label("Add Rule", systemImage: "plus")
        }
    }

    func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { open in if open { expanded.insert(id) } else { expanded.remove(id) } })
    }

    func toggleAll() {
        withAnimation(.snappy(duration: 0.25)) {
            expanded = allExpanded ? [] : Set(draft.forwardings.map(\.id))
        }
    }

    func nextPort(_ preferred: Int) -> Int {
        let used = Set(draft.forwardings.filter { $0.kind.listensLocally }.map(\.port))
        var p = preferred
        while used.contains(p) { p += 1 }
        return p
    }

    func add(_ f: Forwarding) {
        withAnimation {
            draft.forwardings.append(f)
            expanded.insert(f.id)
        }
        reveal = f.id
    }

    func delete(_ id: UUID) {
        withAnimation {
            draft.forwardings.removeAll { $0.id == id }
            expanded.remove(id)
        }
    }

    func duplicate(_ id: UUID) {
        guard let i = draft.forwardings.firstIndex(where: { $0.id == id }) else { return }
        var copy = draft.forwardings[i]
        copy.id = UUID()
        if copy.kind.listensLocally { copy.port = nextPort(copy.port) }
        withAnimation {
            draft.forwardings.insert(copy, at: i + 1)
            expanded.insert(copy.id)
        }
        reveal = copy.id
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = draft.forwardings.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard draft.forwardings.indices.contains(j) else { return }
        withAnimation { draft.forwardings.swapAt(i, j) }
    }
}

/// One forwarding rule as a card: a header that always shows what the rule does, and the
/// fields to change it, which fold away so a long list stays easy to scan.
private struct ForwardingCard: View {
    @Binding var forwarding: Forwarding
    @Binding var isExpanded: Bool
    /// The tunnel being edited, for the route preview (server name, proxy).
    var tunnel: Tunnel
    var serverName: String
    var issues: [ValidationIssue]
    var canMoveUp: Bool
    var canMoveDown: Bool
    var onMove: (Int) -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider()
                details
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .background(Theme.surface)
        // Kind-colored edge: tells rules apart at a glance, dimmed while the rule is off.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(forwarding.kind.tint.opacity(forwarding.enabled ? 0.85 : 0.3))
                .frame(width: 3)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.outline, lineWidth: 1))
        // Cast by a plain shape behind the card. A shadow on the card itself is recomputed from
        // all of its contents on every frame of the fold animation and on every keystroke.
        .background(shape.fill(Theme.surface).shadow(color: Theme.nodeShadow.opacity(0.6), radius: 3, y: 1))
    }

    var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    KindBadge(kind: forwarding.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(forwarding.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        ForwardAddressLine(forwarding: forwarding)
                    }
                    .opacity(forwarding.enabled ? 1 : 0.55)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? String(localized: "Hide rule details") : String(localized: "Show rule details"))
            .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))

            if !isExpanded, let issue = issues.first(where: { $0.severity == .error }) ?? issues.first {
                Image(systemName: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                    .help(issue.message)
            }
            Toggle("Enabled", isOn: $forwarding.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(forwarding.enabled ? String(localized: "Rule is enabled") : String(localized: "Rule is disabled"))
                .fixedSize()
            Menu {
                Button("Move Up") { onMove(-1) }.disabled(!canMoveUp)
                Button("Move Down") { onMove(1) }.disabled(!canMoveDown)
                Button("Duplicate") { onDuplicate() }
                Divider()
                Button("Delete Rule", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $forwarding.kind) {
                ForEach(ForwardingKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            // Live picture of this rule; it follows every edit below.
            RouteDiagram(tunnel: tunnel, forwardings: [forwarding], style: .preview, compact: true)
                .equatable()
                .animation(.snappy(duration: 0.25), value: forwarding.kind)

            HStack(alignment: .bottom, spacing: 8) {
                field(listenTitle) {
                    HStack(spacing: 4) {
                        TextField("", text: $forwarding.bindAddress, prompt: forwarding.kind == .remote ? Text("server default") : Text(verbatim: "localhost"))
                            .frame(minWidth: 90)
                        Text(":").foregroundStyle(.secondary)
                        TextField("", text: $forwarding.port.text, prompt: Text("port"))
                            .frame(width: 64)
                    }
                }
                if forwarding.kind != .dynamic {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(forwarding.kind.tint)
                        .padding(.bottom, 5)
                    field(targetTitle) {
                        HStack(spacing: 4) {
                            TextField("", text: $forwarding.targetHost, prompt: Text("localhost"))
                                .frame(minWidth: 120)
                            Text(":").foregroundStyle(.secondary)
                            TextField("", text: $forwarding.targetPort.text, prompt: Text("port"))
                                .frame(width: 64)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()

            TextField("", text: $forwarding.note, prompt: Text("Note (optional), e.g. “Staging Postgres”"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
                Text(forwarding.explanation(serverName: serverName))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            IssueText(issues: issues)
        }
        .opacity(forwarding.enabled ? 1 : 0.6)
    }

    var listenTitle: String {
        switch forwarding.kind {
        case .local: return String(localized: "Listen on this Mac")
        case .remote: return String(localized: "Listen on the server")
        case .dynamic: return String(localized: "SOCKS proxy on this Mac")
        }
    }

    var targetTitle: String {
        forwarding.kind == .local ? String(localized: "Destination (as seen from the server)") : String(localized: "Destination (as seen from this Mac)")
    }

    func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Connection tab

private struct ConnectionTab: View {
    @Binding var draft: Tunnel
    @Binding var proxyPassword: String
    var issues: [ValidationIssue]
    /// Filled on appear: as an initial `@State` value it was looked up on every redraw of the editor.
    @State private var interfaces: [NetworkInterface] = []

    var body: some View {
        Form {
            Section {
                HopsView(tunnel: draft)
                Picker("Route", selection: $draft.proxy.kind) {
                    ForEach(ProxyKind.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: draft.proxy.kind) { _, kind in
                    if draft.proxy.port == 0 || ProxyKind.allCases.map(\.defaultPort).contains(draft.proxy.port) {
                        draft.proxy.port = kind.defaultPort
                    }
                }
                if draft.proxy.kind != .none {
                    TextField(draft.proxy.kind == .jumpHost ? String(localized: "Jump host") : String(localized: "Proxy server"), text: $draft.proxy.host, prompt: Text("host name or address"))
                    TextField("Port", text: $draft.proxy.port.text, prompt: Text(String(draft.proxy.kind.defaultPort)))
                    TextField(draft.proxy.kind == .socks4 ? String(localized: "User ID") : String(localized: "User"), text: $draft.proxy.username, prompt: Text("Optional"))
                    if draft.proxy.kind == .socks5 || draft.proxy.kind == .http {
                        Toggle("Proxy requires a password", isOn: $draft.proxy.requiresPassword)
                        if draft.proxy.requiresPassword {
                            SecureField("Proxy password", text: $proxyPassword, prompt: Text("Leave empty to be asked"))
                        }
                    }
                    IssueText(issues: issues.filter { $0.field == .proxy })
                }
            } header: {
                Text("Proxy / Jump Host")
            } footer: {
                switch draft.proxy.kind {
                case .none: HelpText("Connect to the SSH server directly.")
                case .jumpHost: HelpText("Hop through another SSH server first (ssh -J). The jump host signs you in with your keys and agent; if it asks for a password, Porthole asks you and remembers it separately from the server's.")
                default: HelpText("Useful behind a restrictive firewall. You can even route through another Porthole SOCKS tunnel, e.g. localhost:1080.")
                }
            }

            Section {
                StepperRow(title: "Connect timeout", value: $draft.connectTimeout, range: 3...120, text: String(localized: "\(draft.connectTimeout) s"))
                StepperRow(title: "Attempts per connect", value: $draft.connectionAttempts, range: 1...10, text: draft.connectionAttempts.formatted())
            } header: {
                Text("Connecting")
            } footer: {
                HelpText("Used when the server is down or unreachable, not when it refuses the connection.")
            }

            Section {
                StepperRow(title: "Send keep-alive every", value: $draft.keepAliveInterval, range: 0...600, step: 5,
                           text: draft.keepAliveInterval == 0 ? String(localized: "Off") : String(localized: "\(draft.keepAliveInterval) s"))
                StepperRow(title: "Give up after", value: $draft.keepAliveCountMax, range: 1...20, text: String(localized: "\(draft.keepAliveCountMax) missed replies"))
            } header: {
                Text("Keep-Alive")
            } footer: {
                HelpText(verbatim: draft.keepAliveInterval == 0
                         ? String(localized: "Without keep-alives a dead connection may go unnoticed for a long time.")
                         : String(localized: "An unresponsive server is detected after about \(draft.keepAliveInterval * draft.keepAliveCountMax) seconds, then Porthole reconnects."))
            }

            Section {
                Picker("Network interface", selection: $draft.bindInterface) {
                    Text("Automatic").tag("")
                    ForEach(interfaces) { Text($0.label).tag($0.name) }
                    if !draft.bindInterface.isEmpty && !interfaces.contains(where: { $0.name == draft.bindInterface }) {
                        Text("\(draft.bindInterface) (not available)").tag(draft.bindInterface)
                    }
                }
            } footer: {
                HelpText("Pick an interface only if this Mac has several networks, e.g. Wi-Fi and a VPN.")
            }

        }
        .formStyle(.grouped)
        .onAppear { interfaces = NetworkInterface.all() }
    }
}

// MARK: - Advanced tab

private struct AdvancedTab: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: Tunnel

    var body: some View {
        Form {
            Section("Security") {
                Picker("Host key checking", selection: $draft.hostKeyPolicy) {
                    ForEach(HostKeyPolicy.allCases) { Text($0.title).tag($0) }
                }
                HelpText("A changed host key is always refused – it could mean someone is intercepting the connection.")
                Toggle("Also check the server's IP address (detects DNS spoofing)", isOn: $draft.checkHostIP)
                Picker("Address family", selection: $draft.addressFamily) {
                    ForEach(AddressFamily.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Compress data", isOn: $draft.compression)
            } footer: {
                HelpText("Helps on slow links; slows things down on fast networks.")
            }

            Section {
                TextField("Host key algorithms", text: $draft.hostKeyAlgorithms, prompt: Text("OpenSSH default"))
                TextField("Key exchange", text: $draft.kexAlgorithms, prompt: Text("OpenSSH default"))
                TextField("Ciphers", text: $draft.ciphers, prompt: Text("OpenSSH default"))
            } header: {
                Text("Algorithms")
            } footer: {
                HelpText("Comma-separated. Prefix with + to append to the defaults, e.g. “+ssh-rsa” for very old servers.")
            }

            Section {
                Toggle("Use settings from ~/.ssh/config", isOn: $draft.useSSHConfig)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra ssh options").font(.callout)
                    TextEditor(text: $draft.extraOptions)
                        .font(.system(.callout, design: .monospaced))
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    HelpText("One per line, e.g. “IPQoS throughput”. Passed to ssh as -o options and take precedence over the settings above.")
                }
            } header: {
                Text("OpenSSH")
            }

            Section("Command Preview") {
                let command = SSHCommandBuilder(context: .init(sshPath: model.manager.sshPath, helperExecutable: Bundle.main.executablePath)).displayCommand(for: draft)
                HStack(alignment: .top) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(value: command, help: "Copy command")
                }
            }
        }
        .formStyle(.grouped)
    }
}
