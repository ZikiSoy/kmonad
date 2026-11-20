// KMonad menu bar app.
//
// The keyboards themselves are run by the root LaunchDaemon `kmonad-supervisor`
// (installed by the .pkg). This app only:
//   - shows their status (from /Library/Application Support/KMonad/status.json)
//   - edits the user's ~/.config/kmonad (which configs are enabled, reload
//     requests, auto-reload switch), which the supervisor watches.
// Quitting this app does not stop remapping.

import AppKit
import ServiceManagement

struct KeyboardStatus: Decodable {
    let file: String
    let state: String
    let pid: String
    let restarts: Int
    let message: String
    let log: String
}

struct VHIDStatus: Decodable {
    let state: String
    let version: String
}

struct Status: Decodable {
    let updated: Double
    let user: String
    let configDir: String
    let autoReload: Bool
    let vhid: VHIDStatus
    let keyboards: [KeyboardStatus]
}

// Menu bar icon: K.svg (the "K" of kmonad.svg, CC-BY-SA 4.0 by 6gk), used as
// a template image so it follows the menu bar colour.
let kSVG: NSImage? = Bundle.main.url(forResource: "K", withExtension: "svg")
    .flatMap { NSImage(contentsOf: $0) }

func statusIcon(alert: Bool) -> NSImage {
    let kw = 14 * 16.46257 / 15.527696
    let size = NSSize(width: (alert ? kw + 8 : kw + 3).rounded(.up), height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        let k = NSRect(x: 1.5, y: 2, width: kw, height: 14)
        if let svg = kSVG {
            svg.draw(in: k)
        } else {
            ("K" as NSString).draw(at: NSPoint(x: 1, y: 1),
                                   withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        }
        if alert {
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: kw + 2, y: 1.5, width: 5.5, height: 5.5)).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}

let stateDir = URL(fileURLWithPath: "/Library/Application Support/KMonad")
let logDir = URL(fileURLWithPath: "/Library/Logs/KMonad")
let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/kmonad", isDirectory: true)

func readStatus() -> Status? {
    guard let data = try? Data(contentsOf: stateDir.appendingPathComponent("status.json")) else { return nil }
    return try? JSONDecoder().decode(Status.self, from: data)
}

func stateLabel(_ s: String) -> (String, String) {
    switch s {
    case "running": return ("●", "running")
    case "waiting": return ("○", "waiting for keyboard")
    case "restarting": return ("↻", "restarting after error")
    case "needs-permission": return ("⚠︎", "needs Input Monitoring permission")
    case "config-error": return ("⚠︎", "config error")
    case "no-driver": return ("⚠︎", "Karabiner driver not installed")
    case "missing": return ("⚠︎", "file missing")
    case "": return ("○", "starting…")
    default: return ("?", s)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateIcon() }

        // First run: offer to start at login.
        if #available(macOS 13.0, *), !UserDefaults.standard.bool(forKey: "askedLoginItem") {
            UserDefaults.standard.set(true, forKey: "askedLoginItem")
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: icon

    func updateIcon() {
        let status = readStatus()
        let fresh = status.map { Date().timeIntervalSince1970 - $0.updated < 15 } ?? false
        let bad = !fresh || (status?.keyboards.contains {
            ["needs-permission", "config-error", "no-driver", "restarting", "missing"].contains($0.state)
        } ?? false) || status?.vhid.state == "missing"
        statusItem.button?.image = statusIcon(alert: bad)
        statusItem.button?.toolTip = bad ? "KMonad: needs attention" : "KMonad"
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = readStatus()
        let fresh = status.map { Date().timeIntervalSince1970 - $0.updated < 15 } ?? false
        let enabled = Set(readEnabled())
        let byFile = Dictionary((status?.keyboards ?? []).map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })

        let header = NSMenuItem(title: "KMonad", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if status?.keyboards.contains(where: { $0.state == "needs-permission" }) == true {
            menu.addItem(action("⚠︎ Grant Input Monitoring…", #selector(requestInputMonitoring), nil))
        }
        if !fresh {
            menu.addItem(disabled("⚠︎ Background service is not running"))
            menu.addItem(disabled("   Reinstall KMonad.pkg to fix"))
        }
        menu.addItem(.separator())

        let configs = listConfigs()
        if configs.isEmpty {
            menu.addItem(disabled("No .kbd files in ~/.config/kmonad"))
        }
        for file in configs {
            let on = enabled.contains(file)
            let title: String
            if on, let k = byFile[file] {
                let (dot, text) = stateLabel(k.state)
                title = "\(dot) \(file) — \(text)"
            } else if on {
                title = "○ \(file) — starting…"
            } else {
                title = "   \(file) — off"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(action("Enabled", #selector(toggleEnabled(_:)), file, state: on))
            sub.addItem(action("Edit", #selector(editConfig(_:)), file))
            sub.addItem(action("Restart", #selector(restartConfig(_:)), file))
            sub.addItem(action("Show Log", #selector(showLog(_:)), file))
            if let k = byFile[file], on, !k.message.isEmpty {
                sub.addItem(.separator())
                sub.addItem(disabled(String(k.message.prefix(90))))
                if k.restarts > 0 { sub.addItem(disabled("restarts: \(k.restarts)")) }
            }
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(action("Reload All", #selector(reloadAll), nil, key: "r"))
        menu.addItem(action("Auto-Reload on Save", #selector(toggleAutoReload),
                            nil, state: !FileManager.default.fileExists(atPath: noAutoReloadURL.path)))
        menu.addItem(action("Open Config Folder", #selector(openConfigFolder), nil, key: "o"))
        menu.addItem(action("New Config…", #selector(newConfig), nil, key: "n"))

        menu.addItem(.separator())
        if let v = status?.vhid {
            let d: String
            switch v.state {
            case "running": d = "daemon running"
            case "external": d = "daemon run by Karabiner-Elements"
            default: d = "not installed"
            }
            menu.addItem(disabled("Driver: VirtualHIDDevice \(v.version.isEmpty ? "?" : v.version) · \(d)"))
        }
        menu.addItem(action("Grant Input Monitoring…", #selector(requestInputMonitoring), nil))
        menu.addItem(action("Input Monitoring Settings…", #selector(openInputMonitoring), nil))
        menu.addItem(action("Show kmonad Binary in Finder", #selector(revealBinary), nil))
        menu.addItem(action("Supervisor Log", #selector(showSupervisorLog), nil))

        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            menu.addItem(action("Launch Menu at Login", #selector(toggleLogin), nil,
                                state: SMAppService.mainApp.status == .enabled))
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        menu.addItem(disabled("Version \(version)"))
        menu.addItem(action("Quit Menu (keyboards keep working)", #selector(quit), nil, key: "q"))
    }

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func action(_ title: String, _ sel: Selector, _ obj: Any?, key: String = "", state: Bool? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        i.representedObject = obj
        if let s = state { i.state = s ? .on : .off }
        return i
    }

    // MARK: config files

    var enabledURL: URL { configDir.appendingPathComponent("enabled") }
    var reloadURL: URL { configDir.appendingPathComponent(".reload") }
    var noAutoReloadURL: URL { configDir.appendingPathComponent(".noautoreload") }

    func listConfigs() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: configDir.path)) ?? []
        return files.filter { $0.hasSuffix(".kbd") }.sorted()
    }

    func readEnabled() -> [String] {
        guard let s = try? String(contentsOf: enabledURL, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func writeEnabled(_ files: [String]) {
        let text = "# Configs run by KMonad, one per line (managed by the KMonad menu)\n"
            + files.joined(separator: "\n") + "\n"
        try? text.write(to: enabledURL, atomically: true, encoding: .utf8)
    }

    func touch(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    // MARK: actions

    @objc func toggleEnabled(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        var list = readEnabled()
        if let i = list.firstIndex(of: file) { list.remove(at: i) } else { list.append(file) }
        writeEnabled(list)
    }

    @objc func editConfig(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        run("/usr/bin/open", ["-t", configDir.appendingPathComponent(file).path])
    }

    @objc func restartConfig(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        // A newer mtime makes the supervisor reload that config
        // (or use the global reload when auto-reload is off).
        if FileManager.default.fileExists(atPath: noAutoReloadURL.path) { touch(reloadURL) }
        else { touch(configDir.appendingPathComponent(file)) }
    }

    @objc func showLog(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        let name = (file as NSString).deletingPathExtension + ".log"
        run("/usr/bin/open", ["-a", "Console", logDir.appendingPathComponent(name).path])
    }

    @objc func showSupervisorLog() {
        run("/usr/bin/open", ["-a", "Console", logDir.appendingPathComponent("supervisor.log").path])
    }

    @objc func reloadAll() { touch(reloadURL) }

    @objc func toggleAutoReload() {
        if FileManager.default.fileExists(atPath: noAutoReloadURL.path) {
            try? FileManager.default.removeItem(at: noAutoReloadURL)
        } else {
            touch(noAutoReloadURL)
        }
    }

    @objc func openConfigFolder() { NSWorkspace.shared.open(configDir) }

    @objc func newConfig() {
        let alert = NSAlert()
        alert.messageText = "New keyboard config"
        alert.informativeText = "File name (e.g. annepro2.kbd). It starts from the bundled template; set iokit-name to your keyboard's name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "keyboard.kbd"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.contains("/") { return }
        if !name.hasSuffix(".kbd") { name += ".kbd" }
        let dest = configDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path),
           let tmpl = Bundle.main.url(forResource: "template", withExtension: "kbd") {
            try? FileManager.default.copyItem(at: tmpl, to: dest)
        }
        run("/usr/bin/open", ["-t", dest.path])
    }

    @objc func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    let requestLabel = "io.github.zikisoy.kmonad.request-access"

    /// Path of the kmonad binary that matches the installed driver.
    func currentBinary() -> URL {
        let bin = Bundle.main.resourceURL!.appendingPathComponent("bin")
        if let v = readStatus()?.vhid.version, let major = Int(v.split(separator: ".").first ?? ""),
           let p = [6: 5, 7: 6, 8: 7][major] {
            return bin.appendingPathComponent("kmonad-p\(p)")
        }
        return bin.appendingPathComponent("kmonad-p7")
    }

    /// Runs the kmonad binary once as a launchd job in the user's GUI session,
    /// so it is its own responsible process and macOS shows the Input
    /// Monitoring prompt for *kmonad* (kmonad calls IOHIDRequestAccess when
    /// KMONAD_REQUEST_ACCESS_ONLY is set, then exits).
    @objc func requestInputMonitoring() {
        let uid = getuid()
        let domain = "gui/\(uid)"
        let plistURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(requestLabel).plist")
        let template = Bundle.main.url(forResource: "template", withExtension: "kbd")!.path
        let job: [String: Any] = [
            "Label": requestLabel,
            "ProgramArguments": [currentBinary().path, template],
            "EnvironmentVariables": ["KMONAD_REQUEST_ACCESS_ONLY": "1"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardErrorPath": FileManager.default.temporaryDirectory.appendingPathComponent("kmonad-request-access.log").path,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
              (try? data.write(to: plistURL)) != nil else { return }
        runWait("/bin/launchctl", ["bootout", "\(domain)/\(requestLabel)"])
        runWait("/bin/launchctl", ["bootstrap", domain, plistURL.path])

        // Once the user has decided, clean up and restart the keyboards.
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            tries += 1
            let running = self.runWait("/bin/launchctl", ["print", "\(domain)/\(self.requestLabel)"])
                .contains("state = running")
            if !running || tries > 100 {
                t.invalidate()
                self.runWait("/bin/launchctl", ["bootout", "\(domain)/\(self.requestLabel)"])
                try? FileManager.default.removeItem(at: plistURL)
                self.touch(self.reloadURL)
            }
        }
    }

    @discardableResult
    func runWait(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "" }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: out, encoding: .utf8) ?? ""
    }

    @objc func revealBinary() {
        NSWorkspace.shared.activateFileViewerSelecting([currentBinary()])
    }

    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            else { try? SMAppService.mainApp.register() }
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

@main
struct KMonadMenuApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
