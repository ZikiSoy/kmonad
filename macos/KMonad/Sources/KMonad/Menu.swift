import AppKit
import IOKit.hid
import ServiceManagement
import KMonadCore

/// The menu bar app. It only reads status.json and edits ~/.config/kmonad;
/// the root daemon does the rest. Quitting it does not stop remapping.
final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/kmonad").path
    let statusPath = defaultStateDir + "/status.json"
    var statusItem: NSStatusItem!
    var timer: Timer?
    var permissionPoll: Timer?
    var lastPermissionReload: Date?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: enabledPath) { writeEnabled([]) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshIcon() }
        if !UserDefaults.standard.bool(forKey: "loginItemSet") {
            UserDefaults.standard.set(true, forKey: "loginItemSet")
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: status

    var status: Status? { Status.load(from: statusPath) }

    func isFresh(_ s: Status?) -> Bool {
        guard let s = s else { return false }
        return Date().timeIntervalSince1970 - s.updated < 15
    }

    enum Problem {
        case serviceDown, driverMissing, driverNotActivated, driverUnsupported(String)
        case needsPermission, configError(String, String), keyboardInUse(String)
    }

    func topProblem(_ s: Status?) -> Problem? {
        guard let s = s, isFresh(s) else { return .serviceDown }
        if s.user == nil { return nil }
        let kbs = s.keyboards
        if kbs.contains(where: { $0.state == .driverNotInstalled }) { return .driverMissing }
        if kbs.contains(where: { $0.state == .driverNotActivated }) { return .driverNotActivated }
        if kbs.contains(where: { $0.state == .driverUnsupported }) { return .driverUnsupported(s.driver.version ?? "?") }
        if kbs.contains(where: { $0.state == .needsPermission }) { return .needsPermission }
        if let k = kbs.first(where: { $0.state == .configError || $0.state == .configErrorOldRunning }) {
            return .configError(k.file, k.message)
        }
        if let k = kbs.first(where: { $0.state == .keyboardInUse }) { return .keyboardInUse(k.file) }
        return nil
    }

    // MARK: icon

    func refreshIcon() {
        let s = status
        let alert = topProblem(s) != nil
        statusItem.button?.image = Self.icon(alert: alert)
        statusItem.button?.appearsDisabled = s?.paused == true
        statusItem.button?.toolTip = alert ? "KMonad: needs attention" : "KMonad"
    }

    static let kImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "K", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    static func icon(alert: Bool) -> NSImage {
        let h: CGFloat = 14
        let w = h * 16.46257 / 15.527696
        let size = NSSize(width: (alert ? w + 9 : w + 3).rounded(.up), height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(x: 1.5, y: 2, width: w, height: h)
            if let k = kImage {
                k.draw(in: rect)
            } else {
                ("K" as NSString).draw(at: NSPoint(x: 1, y: 1),
                                       withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
            }
            if alert {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: w + 3, y: 1.5, width: 5.5, height: 5.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = status
        let enabled = Set(readEnabled())
        let byFile = Dictionary((s?.keyboards ?? []).map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })

        if let p = topProblem(s) {
            menu.addItem(problemItem(p))
            menu.addItem(.separator())
        }

        let configs = listConfigs()
        if configs.isEmpty {
            menu.addItem(disabled("No .kbd configs in ~/.config/kmonad yet"))
        }
        for file in configs {
            let on = enabled.contains(file)
            let k = byFile[file]
            let item = NSMenuItem(title: title(file: file, on: on, status: k, paused: s?.paused == true),
                                  action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(action("Enabled", #selector(toggleEnabled(_:)), file, state: on))
            sub.addItem(action("Edit…", #selector(editConfig(_:)), file))
            sub.addItem(action("Show Log", #selector(showLog(_:)), file))
            sub.addItem(action("Show in Finder", #selector(revealConfig(_:)), file))
            if let k = k, on, !k.message.isEmpty {
                sub.addItem(.separator())
                sub.addItem(disabled(String(k.message.prefix(100))))
            }
            item.submenu = sub
            menu.addItem(item)
        }
        for k in (s?.keyboards ?? []) where k.state == .invalidName {
            menu.addItem(disabled("⚠︎ Invalid entry in enabled: \(k.file)"))
        }

        menu.addItem(.separator())
        let paused = s?.paused == true || FileManager.default.fileExists(atPath: pausedPath)
        menu.addItem(action(paused ? "Resume Remapping" : "Pause Remapping", #selector(togglePause), nil, key: "p"))
        menu.addItem(action("Reload", #selector(reloadAll), nil, key: "r"))
        let newItem = NSMenuItem(title: "New Config for Keyboard", action: nil, keyEquivalent: "")
        let newMenu = NSMenu()
        let keyboards = connectedKeyboardNames()
        if keyboards.isEmpty { newMenu.addItem(disabled("No keyboards detected")) }
        for name in keyboards {
            newMenu.addItem(action(name.replacingOccurrences(of: "\n", with: " "), #selector(newConfig(_:)), name))
        }
        newItem.submenu = newMenu
        menu.addItem(newItem)
        menu.addItem(action("Open Config Folder", #selector(openConfigFolder), nil, key: "o"))

        menu.addItem(.separator())
        if let d = s?.driver {
            let daemon: String
            switch d.daemon {
            case .ours: daemon = "Virtual keyboard daemon: run by KMonad"
            case .external: daemon = "Virtual keyboard daemon: run by Karabiner-Elements"
            case .none: daemon = "Virtual keyboard daemon: not running"
            }
            let v = d.version.map { "Driver \($0)" } ?? "Driver not installed"
            menu.addItem(disabled("\(v) · \(daemon)"))
        }
        menu.addItem(action("Input Monitoring Settings…", #selector(openInputMonitoring), nil))
        menu.addItem(action("Service Log", #selector(showDaemonLog), nil))
        menu.addItem(.separator())
        menu.addItem(action("Show Menu at Login", #selector(toggleLoginItem), nil,
                            state: SMAppService.mainApp.status == .enabled))
        menu.addItem(action("Uninstall KMonad…", #selector(uninstall), nil))
        menu.addItem(disabled("Version \(appVersion)"))
        menu.addItem(action("Quit Menu (remapping keeps running)", #selector(quit), nil, key: "q"))
    }

    func title(file: String, on: Bool, status k: KeyboardStatus?, paused: Bool) -> String {
        guard on else { return "   \(file) — off" }
        guard let k = k else { return "○ \(file) — starting" }
        let device = k.allKeyboards ? "all keyboards" : (k.device ?? "")
        let (dot, text) = label(k)
        let d = device.isEmpty ? "" : "  \(device.replacingOccurrences(of: "\n", with: " "))"
        return "\(dot) \(file)\(d) — \(text)"
    }

    func label(_ k: KeyboardStatus) -> (String, String) {
        switch k.state {
        case .starting: return ("○", "starting")
        case .running: return k.connected ? ("●", "running") : ("○", "waiting for keyboard")
        case .paused: return ("○", "paused")
        case .waitingDriver: return ("○", "waiting for virtual keyboard")
        case .driverNotInstalled: return ("⚠︎", "Driver not installed")
        case .driverNotActivated: return ("⚠︎", "driver needs approval")
        case .driverUnsupported: return ("⚠︎", "driver version unsupported")
        case .driverMismatch: return ("⚠︎", "driver version mismatch")
        case .needsPermission: return ("⚠︎", "needs Input Monitoring")
        case .keyboardInUse: return ("⚠︎", "keyboard in use by another app")
        case .configError: return ("⚠︎", "config error")
        case .configErrorOldRunning: return ("⚠︎", "new config has errors; previous one still running")
        case .conflict: return ("⚠︎", "same keyboard as \(k.message)")
        case .restarting: return ("↻", "crashed, restarting")
        case .missing: return ("⚠︎", "file missing")
        case .invalidName: return ("⚠︎", "invalid file name")
        }
    }

    func problemItem(_ p: Problem) -> NSMenuItem {
        switch p {
        case .serviceDown: return action("⚠︎ Background service not running — Fix…", #selector(fixService), nil)
        case .driverMissing: return action("⚠︎ Karabiner driver not installed — Install…", #selector(installDriver), nil)
        case .driverNotActivated: return action("⚠︎ Karabiner driver needs approval — Approve…", #selector(activateDriver), nil)
        case .driverUnsupported(let v): return disabled("⚠︎ Driver \(v) is not supported — update KMonad")
        case .needsPermission: return action("⚠︎ Input Monitoring needed — Grant…", #selector(grantPermission), nil)
        case .configError(let f, _): return action("⚠︎ \(f) has a config error — Show Log", #selector(showLog(_:)), f)
        case .keyboardInUse(let f):
            return action("⚠︎ \(f): keyboard in use (untick it in Karabiner-Elements → Devices)",
                          #selector(showLog(_:)), f)
        }
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

    // MARK: files

    var enabledPath: String { configDir + "/enabled" }
    var pausedPath: String { configDir + "/.paused" }
    var reloadPath: String { configDir + "/.reload" }

    func listConfigs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: configDir)) ?? [])
            .filter { ConfigText.isValidName($0) }.sorted()
    }

    func readEnabled() -> [String] {
        guard let text = try? String(contentsOfFile: enabledPath, encoding: .utf8) else { return [] }
        return ConfigText.parseEnabled(text).names
    }

    func writeEnabled(_ names: [String]) {
        try? ConfigText.renderEnabled(names).write(toFile: enabledPath, atomically: true, encoding: .utf8)
    }

    func touch(_ path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }

    func open(_ args: [String]) { runProgram("/usr/bin/open", args, timeout: 10) }

    // MARK: actions

    @objc func toggleEnabled(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        var list = readEnabled()
        if let i = list.firstIndex(of: file) { list.remove(at: i) } else { list.append(file) }
        writeEnabled(list)
    }

    @objc func editConfig(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: configDir + "/" + file)
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            open(["-t", url.path])
        }
    }

    @objc func showLog(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        let name = file.hasSuffix(".kbd") ? String(file.dropLast(4)) : file
        open(["-a", "Console", defaultLogDir + "/" + name + ".log"])
    }

    @objc func revealConfig(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configDir + "/" + file)])
    }

    @objc func showDaemonLog() { open(["-a", "Console", defaultLogDir + "/daemon.log"]) }

    @objc func togglePause() {
        if FileManager.default.fileExists(atPath: pausedPath) {
            try? FileManager.default.removeItem(atPath: pausedPath)
        } else {
            touch(pausedPath)
        }
        refreshIcon()
    }

    @objc func reloadAll() { touch(reloadPath) }

    @objc func openConfigFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: configDir)) }

    @objc func newConfig(_ sender: NSMenuItem) {
        guard let keyboard = sender.representedObject as? String else { return }
        let file = ConfigText.fileName(forKeyboard: keyboard)
        let path = configDir + "/" + file
        if !FileManager.default.fileExists(atPath: path),
           let url = Bundle.main.url(forResource: "template", withExtension: "kbd"),
           let template = try? String(contentsOf: url, encoding: .utf8) {
            let text = template.replacingOccurrences(of: "CHANGE ME", with: ConfigText.escape(keyboard))
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let item = NSMenuItem()
        item.representedObject = file
        editConfig(item)
    }

    @objc func openInputMonitoring() {
        for u in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
                  "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"] {
            if let url = URL(string: u), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Input Monitoring: ask macOS for KMonad (the daemon is KMonad too); if
    /// the daemon still cannot open the keyboard, guide to re-toggling it.
    @objc func grantPermission() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeGranted {
            if let t = lastPermissionReload, Date().timeIntervalSince(t) < 120 {
                fallbackPermissionGuide()
            } else {
                retryAfterGrant()
            }
            return
        }
        if access == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            openInputMonitoring()
            alert("Turn on KMonad in Input Monitoring", "KMonad was denied before. Switch KMonad on in the Settings page that just opened.")
        }
        permissionPoll?.invalidate()
        var tries = 0
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            tries += 1
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
                t.invalidate()
                self?.retryAfterGrant()
            } else if tries > 150 {
                t.invalidate()
            }
        }
    }

    func retryAfterGrant() {
        lastPermissionReload = Date()
        touch(reloadPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            if self.status?.keyboards.contains(where: { $0.state == .needsPermission }) == true {
                self.fallbackPermissionGuide()
            }
        }
    }

    func fallbackPermissionGuide() {
        openInputMonitoring()
        alert("Turn KMonad off and on in Input Monitoring",
              "macOS still blocks keyboard access. In the Settings page that just opened, switch KMonad off and "
              + "on again (or remove it and grant again). KMonad retries automatically.")
    }

    @objc func fixService() {
        let plist = "/Library/LaunchDaemons/\(daemonLabel).plist"
        guard FileManager.default.fileExists(atPath: plist) else {
            alert("Background service not installed", "Please reinstall the KMonad .pkg.")
            return
        }
        let script = "launchctl enable system/\(daemonLabel); launchctl bootstrap system \(plist) 2>/dev/null"
            + " || launchctl kickstart -k system/\(daemonLabel)"
        guard runAsAdmin(script) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, !self.isFresh(self.status) else { return }
            self.alert("Background service still not running",
                       "KMonad may be switched off under Login Items & Extensions → Allow in the Background. Turn it on in the Settings page that just opened.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc func installDriver() {
        guard let pkg = Bundle.main.url(forResource: "Karabiner-DriverKit-VirtualHIDDevice", withExtension: "pkg") else {
            return
        }
        NSWorkspace.shared.open(pkg)
    }

    @objc func activateDriver() {
        runProgram("/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager",
                   ["activate"], timeout: 5)
        for u in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                  "x-apple.systempreferences:com.apple.preference.security"] {
            if let url = URL(string: u), NSWorkspace.shared.open(url) { break }
        }
        alert("Approve the Karabiner driver", "In Privacy & Security, find the system extension from pqrs.org and click Allow.")
    }

    @objc func toggleLoginItem() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    @objc func uninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall KMonad?"
        a.informativeText = "This stops remapping and removes KMonad and its background service. Your configs in ~/.config/kmonad are kept."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        let removeDriver = NSButton(checkboxWithTitle: "Also remove the Karabiner driver installed by KMonad", target: nil, action: nil)
        let installedDriver = FileManager.default.fileExists(atPath: defaultStateDir + "/installed-driver")
        if installedDriver { a.accessoryView = removeDriver }
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let script = (Bundle.main.resourcePath ?? "/Applications/KMonad.app/Contents/Resources") + "/uninstall.sh"
        let arg = (installedDriver && removeDriver.state == .on) ? " --remove-driver" : ""
        if runAsAdmin("/bin/bash '\(script)'\(arg)") {
            NSApp.terminate(nil)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: helpers

    /// Runs a shell command with an administrator password prompt.
    @discardableResult
    func runAsAdmin(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let r = runProgram("/usr/bin/osascript",
                           ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 300)
        return r.status == 0
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

func runMenu() -> Never {
    let app = NSApplication.shared
    let controller = MenuController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { app.run() }
    exit(0)
}
