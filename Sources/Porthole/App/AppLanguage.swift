import AppKit
import Foundation

/// Languages Porthole ships translations for, and the per-app language override.
enum AppLanguage {
    struct Option: Identifiable, Hashable {
        let code: String
        let nativeName: String
        var id: String { code }
    }

    static let supported: [Option] = [
        Option(code: "en", nativeName: "English"),
        Option(code: "zh-Hans", nativeName: "简体中文"),
        Option(code: "zh-Hant", nativeName: "繁體中文"),
        Option(code: "ja", nativeName: "日本語"),
        Option(code: "ko", nativeName: "한국어"),
        Option(code: "de", nativeName: "Deutsch"),
        Option(code: "fr", nativeName: "Français"),
        Option(code: "es", nativeName: "Español"),
        Option(code: "pt-BR", nativeName: "Português (Brasil)"),
        Option(code: "ru", nativeName: "Русский"),
    ]

    private static let key = "AppleLanguages"

    /// The language chosen inside Porthole, or "" to follow the system.
    static var selected: String {
        guard let id = Bundle.main.bundleIdentifier,
              let langs = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = langs.first else { return "" }
        return supported.contains { $0.code == first } ? first : ""
    }

    /// Captured at launch so the UI can tell whether a restart is needed.
    static let launchedWith: String = selected

    static func select(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([code], forKey: key)
        }
    }
}

enum AppRelauncher {
    /// Quits and reopens the app once this process has exited.
    @MainActor
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
