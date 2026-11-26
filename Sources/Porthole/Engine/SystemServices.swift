import AppKit
import Foundation
import Network
import Security
import ServiceManagement
import UserNotifications

// MARK: - Keychain

enum Keychain {
    static let service = "Porthole"

    static func tunnelPassword(_ id: UUID) -> String { "tunnel.\(id.uuidString).password" }
    static func proxyPassword(_ id: UUID) -> String { "tunnel.\(id.uuidString).proxy" }
    static func jumpHostPassword(_ id: UUID) -> String { "tunnel.\(id.uuidString).jump" }
    static func keyPassphrase(_ path: String) -> String { "key.\((path as NSString).expandingTildeInPath)" }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String, label: String? = nil) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label ?? "Porthole – \(account)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func has(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Ports

enum PortInspector {
    struct Owner: Equatable {
        var pid: Int32
        var command: String
    }

    /// Returns a description of why `port` can't be listened on, or nil when it looks free.
    static func conflict(port: Int, bindAddress: String, ignoringPIDs: Set<Int32>) -> String? {
        let bind = bindAddress.trimmingCharacters(in: .whitespaces).lowercased()
        var address: String?
        switch bind {
        case "", "localhost", "127.0.0.1": address = "127.0.0.1"
        case "*", "0.0.0.0": address = "0.0.0.0"
        default:
            var a = in_addr()
            address = inet_pton(AF_INET, bind, &a) == 1 ? bind : nil
        }
        let owners = listeners(on: port).filter { !ignoringPIDs.contains($0.pid) }
        if let address, !canBind(port: port, address: address) {
            if let o = owners.first { return inUse(port, o) }
            return String(localized: "Port \(String(port)) is already in use by another process.")
        }
        if let o = owners.first {
            return inUse(port, o)
        }
        return nil
    }

    private static func inUse(_ port: Int, _ owner: Owner) -> String {
        let pid = String(owner.pid)
        return String(localized: "Port \(String(port)) is already in use by \(owner.command) (PID \(pid)).")
    }

    static func canBind(port: Int, address: String) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, address, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Processes (of this user) listening on a TCP port, via lsof.
    static func listeners(on port: Int) -> [Owner] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var owners: [Owner] = []
        var pid: Int32?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("c"), let pid { owners.append(Owner(pid: pid, command: String(line.dropFirst()))) }
        }
        return owners
    }

    /// Quick check that something accepts TCP connections on 127.0.0.1:port.
    static func isListening(port: Int, host: String = "127.0.0.1") -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }
}

// MARK: - Network interfaces

struct NetworkInterface: Hashable, Identifiable {
    var name: String
    var addresses: [String]
    var id: String { name }
    var label: String { addresses.isEmpty ? name : "\(name) (\(addresses.joined(separator: ", ")))" }

    static func all() -> [NetworkInterface] {
        var result: [String: [String]] = [:]
        var order: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = ifa.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                if result[name] == nil { order.append(name) }
                let end = host.firstIndex(of: 0) ?? host.endIndex
                result[name, default: []].append(String(decoding: host[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return order.map { NetworkInterface(name: $0, addresses: result[$0] ?? []) }
    }
}

// MARK: - Notifications

@MainActor
enum Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Login item

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Network reachability

final class NetworkWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var lastSatisfied: Bool?
    var onBecameReachable: (@MainActor () -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let previous = self.lastSatisfied
            self.lastSatisfied = satisfied
            if satisfied, previous == false {
                Task { @MainActor in self.onBecameReachable?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "porthole.network"))
    }
}
