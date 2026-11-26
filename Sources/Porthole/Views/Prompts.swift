import AppKit
import PortholeCore
import SwiftUI

struct PromptRequest: Identifiable {
    struct HostKeyDetail {
        var host: String
        var keyType: String
        var fingerprint: String
    }

    enum Kind {
        case password
        case passphrase
        case proxyPassword
        case secret
        case hostKey(HostKeyDetail)
        case confirm
    }

    let id = UUID()
    let tunnelID: UUID
    let tunnelName: String
    let kind: Kind
    let message: String
    /// Keychain account to save the answer to when "Remember" is checked.
    let rememberAccount: String?
}

/// Shows ssh's questions as small native panels, one at a time.
@MainActor
final class PromptPresenter {
    private struct Pending {
        let request: PromptRequest
        let continuation: CheckedContinuation<AskpassReply, Never>
    }

    private var queue: [Pending] = []
    private var current: (pending: Pending, panel: NSPanel)?

    func ask(_ request: PromptRequest) async -> AskpassReply {
        await withCheckedContinuation { continuation in
            queue.append(Pending(request: request, continuation: continuation))
            showNextIfIdle()
        }
    }

    func cancel(tunnelID: UUID) {
        let (drop, keep) = (queue.filter { $0.request.tunnelID == tunnelID }, queue.filter { $0.request.tunnelID != tunnelID })
        queue = keep
        for p in drop { p.continuation.resume(returning: .cancelled) }
        if let current, current.pending.request.tunnelID == tunnelID {
            finish(.cancelled)
        }
    }

    private func showNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let view = PromptView(request: pending.request) { [weak self] reply, remember in
            if reply.ok, remember, let account = pending.request.rememberAccount {
                Keychain.set(reply.answer, for: account)
            }
            self?.finish(reply)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        current = (pending, panel)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if let current = self?.current, current.panel === panel { self?.finish(.cancelled) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ reply: AskpassReply) {
        guard let current else { return }
        self.current = nil
        current.panel.orderOut(nil)
        current.pending.continuation.resume(returning: reply)
        showNextIfIdle()
    }
}

struct PromptView: View {
    var request: PromptRequest
    var onFinish: (AskpassReply, Bool) -> Void

    @State private var answer = ""
    @State private var remember = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(iconColor.gradient)
                    .frame(width: 44, height: 44)
                    .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(request.tunnelName).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            switch request.kind {
            case .hostKey(let detail):
                hostKeyBody(detail)
            case .confirm:
                Text(request.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            default:
                Text(request.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("", text: $answer, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .onSubmit(submit)
                if request.rememberAccount != nil {
                    Toggle("Remember in my Keychain", isOn: $remember)
                        .toggleStyle(.checkbox)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onFinish(.cancelled, false) }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    func submit() {
        switch request.kind {
        case .hostKey, .confirm:
            onFinish(AskpassReply(ok: true, answer: "yes"), false)
        default:
            onFinish(AskpassReply(ok: true, answer: answer), remember)
        }
    }

    @ViewBuilder
    func hostKeyBody(_ detail: PromptRequest.HostKeyDetail) -> some View {
        Text("Porthole hasn't connected to this server before. Make sure the fingerprint below matches the one your server administrator gave you.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Server", value: detail.host)
            if !detail.keyType.isEmpty { LabeledContent("Key type", value: detail.keyType) }
            LabeledContent("Fingerprint") {
                Text(detail.fingerprint.isEmpty ? "—" : detail.fingerprint)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    var title: String {
        switch request.kind {
        case .password: return String(localized: "Enter password")
        case .passphrase: return String(localized: "Unlock private key")
        case .proxyPassword: return String(localized: "Proxy password")
        case .secret: return String(localized: "The server is asking for more information")
        case .hostKey: return String(localized: "Trust this server?")
        case .confirm: return String(localized: "Confirm")
        }
    }

    var placeholder: String {
        switch request.kind {
        case .passphrase: return String(localized: "Passphrase")
        case .secret: return String(localized: "Response")
        default: return String(localized: "Password")
        }
    }

    var primaryTitle: String {
        switch request.kind {
        case .hostKey: return String(localized: "Trust and Connect")
        case .confirm: return String(localized: "Yes")
        default: return String(localized: "Connect")
        }
    }

    var icon: String {
        switch request.kind {
        case .hostKey: return "checkmark.shield.fill"
        case .passphrase: return "key.fill"
        case .confirm: return "questionmark.circle.fill"
        default: return "lock.fill"
        }
    }

    var iconColor: Color {
        switch request.kind {
        case .hostKey: return .orange
        default: return .blue
        }
    }
}
