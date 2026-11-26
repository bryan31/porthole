import Foundation
import PortholeCore

// One executable, three roles:
//   Porthole --proxy-connect …   ProxyCommand helper used by ssh for SOCKS/HTTP proxies
//   (env PORTHOLE_ASKPASS_SOCKET) SSH_ASKPASS helper: relays ssh's prompts to the running app
//   otherwise                     the SwiftUI app
let arguments = CommandLine.arguments

if arguments.count >= 2, arguments[1] == "--proxy-connect" {
    exit(ProxyHelper.run(Array(arguments.dropFirst(2))))
}

if ProcessInfo.processInfo.environment[AskpassEnvironment.socketPath] != nil {
    exit(AskpassHelper.run(prompt: arguments.dropFirst().joined(separator: " ")))
}

PortholeApp.main()
