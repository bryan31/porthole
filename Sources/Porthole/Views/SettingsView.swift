import PortholeCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
            DataSettings()
                .tabItem { Label("Data", systemImage: "externaldrive") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.presentation) private var presentation = Presentation.both.rawValue
    @AppStorage(SettingsKey.notifyOnFailure) private var notifyOnFailure = true
    @AppStorage(SettingsKey.notifyOnConnect) private var notifyOnConnect = false
    @State private var language = AppLanguage.selected
    @State private var languageChanged = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Appearance") {
                    AppearanceTiles(selection: Binding(get: { model.appearance }, set: { model.appearance = $0 }))
                }
            } footer: {
                Text("You can also switch with the toolbar button, the menu bar panel or ⇧⌘D.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Language", selection: $language) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(AppLanguage.supported) { lang in
                        Text(verbatim: lang.nativeName).tag(lang.code)
                    }
                }
                .onChange(of: language) { _, code in
                    AppLanguage.select(code)
                    languageChanged = code != AppLanguage.launchedWith
                }
                if languageChanged {
                    HStack {
                        Text("Restart Porthole to use the new language. Running tunnels reconnect automatically if they are set to connect at launch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Restart Now") { AppRelauncher.relaunch() }
                    }
                }
            } footer: {
                Text("You can also pick a language in System Settings ▸ General ▸ Language & Region ▸ Applications.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open Porthole at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        do {
                            try LoginItem.setEnabled(value)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Picker("Show Porthole in", selection: $presentation) {
                    ForEach(Presentation.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: presentation) { _, _ in AppDelegate.applyPresentation() }
            } footer: {
                Text("Tunnels keep running when the window is closed. Combine with “Connect when Porthole launches” on each tunnel to have them up right after login.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("When a tunnel disconnects or fails", isOn: $notifyOnFailure)
                Toggle("When a tunnel connects", isOn: $notifyOnConnect)
            }
        }
        .formStyle(.grouped)
        .frame(height: 580)
    }
}

struct AdvancedSettings: View {
    @AppStorage(SettingsKey.reconnectOnWake) private var reconnectOnWake = true
    @AppStorage(SettingsKey.sshPath) private var sshPath = ""
    @State private var sshVersion = ""

    var body: some View {
        Form {
            Section("Connections") {
                Toggle("Refresh tunnels after the Mac wakes from sleep", isOn: $reconnectOnWake)
            }

            Section {
                TextField("ssh executable", text: $sshPath, prompt: Text("/usr/bin/ssh"))
                    .onSubmit(refreshVersion)
                Text(sshVersion.isEmpty ? " " : sshVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } header: {
                Text("OpenSSH")
            } footer: {
                Text("Porthole uses the OpenSSH client that ships with macOS. Point this at another build (e.g. from Homebrew) if you need to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
        .onAppear(perform: refreshVersion)
    }

    func refreshVersion() {
        let path = sshPath.isEmpty ? "/usr/bin/ssh" : sshPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-V"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            sshVersion = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            sshVersion = String(localized: "Not found: \(path)")
        }
    }
}

struct DataSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Import") {
                LabeledContent("From SSH Tunnel (Codinn)") {
                    Button("Choose Export…") { model.importFile() }
                }
                Text("In the old app choose File ▸ Export Selected Tunnels…, then import that file here.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("From ~/.ssh/config") {
                    Button("Import Hosts") { model.importSSHConfig() }
                }
            }
            Section("Export") {
                LabeledContent("All tunnels and smart groups") {
                    Button("Export…") { model.export(nil) }
                }
                Text("Exports contain no passwords. Those stay in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Settings file") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([TunnelStore.supportDirectory.appendingPathComponent("tunnels.json")])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Porthole").font(.title.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("SSH tunnels for your Mac. Native on Apple silicon, powered by the OpenSSH client built into macOS.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }
}
