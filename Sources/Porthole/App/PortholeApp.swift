import AppKit
import PortholeCore
import SwiftUI

struct PortholeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(SettingsKey.presentation) private var presentation = Presentation.both.rawValue

    var body: some Scene {
        Window("Porthole", id: "main") {
            MainWindow()
                .environment(delegate.model)
        }
        .defaultSize(width: 1080, height: 700)
        .commands { PortholeCommands(model: delegate.model) }

        Settings {
            SettingsView()
                .environment(delegate.model)
        }

        MenuBarExtra(isInserted: Binding(get: { presentation != Presentation.dockOnly.rawValue }, set: { _ in })) {
            MenuBarPanel()
                .environment(delegate.model)
        } label: {
            MenuBarLabel(manager: delegate.model.manager)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let snapshotDirectory: String?
    /// `--demo`: the normal window with sample tunnels kept in memory, for trying the UI
    /// without touching real tunnels. Nothing is saved.
    let demo: Bool

    override init() {
        let args = CommandLine.arguments
        demo = args.contains("--demo")
        if let i = args.firstIndex(of: "--render-snapshots"), i + 1 < args.count {
            snapshotDirectory = args[i + 1]
            model = MainActor.assumeIsolated { DemoData.makeModel() }
        } else if demo {
            snapshotDirectory = nil
            model = MainActor.assumeIsolated { DemoData.makeModel() }
        } else {
            snapshotDirectory = nil
            model = MainActor.assumeIsolated { AppModel(store: TunnelStore()) }
        }
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.applyPresentation()
            if snapshotDirectory == nil { model.appearance.apply() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let dir = snapshotDirectory {
                Snapshotter.run(model: model, directory: dir)
                return
            }
            if demo {
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            model.manager.startServices()
            installSignalHandlers()
            Notifier.requestAuthorization()
            model.manager.autoConnect()
            if let error = model.store.loadError {
                model.alert = AppAlert(title: String(localized: "Some data could not be read"), message: error)
            }
        }
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// `kill`, `pkill` or Ctrl-C in a terminal shut every tunnel's ssh down instead of leaving it
    /// running without Porthole. This does the quit cleanup directly: `NSApp.terminate` is
    /// ignored while a sheet is open, and a signal must not be.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [model] in
                MainActor.assumeIsolated {
                    model.store.saveNow()
                    model.manager.shutdown()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { model.showMainWindow() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard snapshotDirectory == nil else { return }
            model.store.saveNow()
            model.manager.shutdown()
        }
    }

    @MainActor
    static func applyPresentation() {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.presentation) ?? Presentation.both.rawValue
        let p = Presentation(rawValue: raw) ?? .both
        NSApp.setActivationPolicy(p == .menuBarOnly ? .accessory : .regular)
    }
}

// MARK: - Menu commands

struct PortholeCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tunnel") { model.newTunnel() }
                .keyboardShortcut("n")
            Button("New Smart Group…") { model.newSmartGroup() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Import Tunnels…") { model.importFile() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Import from ~/.ssh/config") { model.importSSHConfig() }
            Divider()
            Button("Export Selected Tunnels…") { model.export(model.selection) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
            Button("Export All Tunnels…") { model.export(nil) }
        }

        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.appearance = $0 })) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            Button("Switch Light/Dark") { model.toggleAppearance() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Tunnel") {
            let selection = model.selection
            Button("Connect") { model.manager.connect(selection) }
                .keyboardShortcut("r")
                .disabled(selection.isEmpty)
            Button("Disconnect") { model.manager.disconnect(selection) }
                .keyboardShortcut(".")
                .disabled(selection.isEmpty)
            Divider()
            Button("Connect All") { model.manager.connectAll() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Disconnect All") { model.manager.disconnectAll() }
                .keyboardShortcut(".", modifiers: [.command, .option])
            Divider()
            Button("Edit…") { if let id = selection.first { model.edit(id) } }
                .keyboardShortcut("e")
                .disabled(selection.count != 1)
            Button("Duplicate") { model.duplicate(selection) }
                .keyboardShortcut("d")
                .disabled(selection.isEmpty)
            Button("Copy SSH Command") { if let id = selection.first { model.copyCommand(id) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(selection.count != 1)
            Button("Show Log") { if let id = selection.first { model.showLog(id) } }
                .keyboardShortcut("l")
                .disabled(selection.count != 1)
            Divider()
            Button("Delete…") { model.requestDelete(selection) }
                .keyboardShortcut(.delete)
                .disabled(selection.isEmpty)
        }
    }
}

// MARK: - Menu bar icon

struct MenuBarLabel: View {
    var manager: TunnelManager

    var body: some View {
        let mode: StatusIcon.Mode = manager.anyBusy ? .busy : (manager.connectedCount > 0 ? .on : (manager.anyFailed ? .failed : .off))
        Image(nsImage: StatusIcon.image(mode))
    }
}

enum StatusIcon {
    enum Mode { case off, on, busy, failed }

    /// A porthole: an outer ring with an inner disc that fills when tunnels are up.
    static func image(_ mode: Mode) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.6, dy: 1.6))
            ring.lineWidth = 1.8
            ring.stroke()
            // Rivets
            for angle in stride(from: 45.0, to: 360.0, by: 90.0) {
                let r = (rect.width / 2) - 1.6
                let c = CGPoint(x: rect.midX + cos(angle * .pi / 180) * r, y: rect.midY + sin(angle * .pi / 180) * r)
                NSBezierPath(ovalIn: NSRect(x: c.x - 1.3, y: c.y - 1.3, width: 2.6, height: 2.6)).fill()
            }
            let inner = rect.insetBy(dx: 5.4, dy: 5.4)
            switch mode {
            case .on:
                NSBezierPath(ovalIn: inner).fill()
            case .busy:
                let path = NSBezierPath()
                path.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.midY), radius: inner.width / 2, startAngle: 90, endAngle: 270)
                path.close()
                path.fill()
                let outline = NSBezierPath(ovalIn: inner)
                outline.lineWidth = 1.2
                outline.stroke()
            case .failed:
                let bar = NSBezierPath()
                bar.move(to: CGPoint(x: inner.minX + 1, y: inner.maxY - 1))
                bar.line(to: CGPoint(x: inner.maxX - 1, y: inner.minY + 1))
                bar.lineWidth = 1.6
                bar.stroke()
                let outline = NSBezierPath(ovalIn: inner)
                outline.lineWidth = 1.2
                outline.stroke()
            case .off:
                let outline = NSBezierPath(ovalIn: inner)
                outline.lineWidth = 1.2
                outline.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
