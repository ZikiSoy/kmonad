import Foundation
import KMonadCore

// KMonad.app's one executable:
//   KMonad                    menu bar app (default)
//   KMonad --daemon           root LaunchDaemon that runs the keyboards
//   KMonad --pause|--resume   pause / resume remapping (current user)
//   KMonad --restart          restart every kmonad (alias: --reload)
//   KMonad --status           print the daemon's status
//   KMonad --version

let args = Array(CommandLine.arguments.dropFirst())
let userConfigDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/kmonad").path

func touchFile(_ path: String) {
    try? FileManager.default.createDirectory(atPath: userConfigDir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: Data())
    }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
}

switch args.first {
case "--daemon":
    runDaemon()
case "--pause":
    touchFile(userConfigDir + "/.paused")
case "--resume":
    try? FileManager.default.removeItem(atPath: userConfigDir + "/.paused")
case "--restart", "--reload":
    touchFile(userConfigDir + "/.reload")
case "--status":
    let path = (ProcessInfo.processInfo.environment["KMONAD_STATE_DIR"] ?? defaultStateDir) + "/status.json"
    guard let s = Status.load(from: path) else {
        print("no status (is the KMonad daemon running?)")
        exit(1)
    }
    let age = Int(Date().timeIntervalSince1970 - s.updated)
    print("KMonad \(s.version) · user \(s.user ?? "-") · updated \(age)s ago\(s.paused ? " · paused" : "")")
    print("driver \(s.driver.version ?? "not installed") · protocol \(s.driver.protocolVersion.map(String.init) ?? "-") · activated \(s.driver.activated.map { $0 ? "yes" : "no" } ?? "?") · daemon \(s.driver.daemon.rawValue)")
    for k in s.keyboards {
        let device = k.allKeyboards ? "all keyboards" : (k.device ?? "-")
        print("\(k.file)  [\(device)]  \(k.state.rawValue)\(k.connected ? "" : " (not connected)")\(k.message.isEmpty ? "" : ": \(k.message)")")
    }
case "--version":
    print(appVersion)
case nil:
    runMenu()
default:
    print("usage: KMonad [--daemon | --pause | --resume | --restart | --status | --version]")
    exit(2)
}
