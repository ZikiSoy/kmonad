import Foundation
import SystemConfiguration
import KMonadCore

/// `KMonad --daemon`: the root LaunchDaemon. Runs the Supervisor once a second.
///
/// Test mode (CI): set KMONAD_TEST_USER_FILE and friends to run unprivileged
/// against temporary directories and a fake kmonad.
final class RealEffects: SupervisorEffects {
    let env = ProcessInfo.processInfo.environment
    let stateDir: String
    let runDir: String
    let logDir: String
    let binDir: String
    let vhidDaemonPath: String
    let vhidManagerPlist = "/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Info.plist"
    let testMode: Bool

    private var processes: [Int32: Process] = [:]
    private var logOffsets: [String: UInt64] = [:]
    private var vhidProcess: Process?
    private var vhidStartedAt = Date.distantPast
    private var activation: (checked: Date, value: Bool?) = (.distantPast, nil)
    private var keyboardCache: (checked: Date, names: [String]) = (.distantPast, [])

    init() {
        stateDir = env["KMONAD_STATE_DIR"] ?? defaultStateDir
        runDir = stateDir + "/run"
        logDir = env["KMONAD_LOG_DIR"] ?? defaultLogDir
        binDir = binDirectory
        vhidDaemonPath = env["KMONAD_VHID_DAEMON"] ?? "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"
        testMode = env["KMONAD_TEST_USER_FILE"] != nil
        let fm = FileManager.default
        for d in [stateDir, logDir] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
            chmod(d, 0o755)
        }
        try? fm.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        chmod(runDir, 0o700)
    }

    func now() -> Date { Date() }

    func consoleUser() -> ConsoleUser? {
        if let file = env["KMONAD_TEST_USER_FILE"] {
            let parts = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
            guard parts.count == 3, let uid = UInt32(parts[1]) else { return nil }
            return ConsoleUser(name: String(parts[0]), uid: uid, home: String(parts[2]))
        }
        var uid: uid_t = 0
        guard let cfName = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) else { return nil }
        let name = cfName as String
        if name.isEmpty || name == "loginwindow" || uid == 0 { return nil }
        guard let pw = getpwuid(uid) else { return nil }
        return ConsoleUser(name: name, uid: uid, home: String(cString: pw.pointee.pw_dir))
    }

    func stat(_ path: String) -> FileStamp? {
        var st = Darwin.stat()
        guard Darwin.stat(path, &st) == 0 else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return FileStamp(mtime: mtime, size: Int64(st.st_size), inode: UInt64(st.st_ino))
    }

    func readAsUser(_ path: String, _ user: ConsoleUser) -> String? {
        if getuid() != 0 {
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        // Never open the user's files as root: read them with their permissions.
        let r = runProgram("/usr/bin/sudo", ["-n", "-u", "#\(user.uid)", "/bin/cat", "--", path],
                           timeout: 10, mergeStderr: false)
        return r.status == 0 ? r.output : nil
    }

    func driver() -> DriverInfo {
        if let file = env["KMONAD_TEST_DRIVER_FILE"] {
            let parts = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard let v = parts.first else { return DriverInfo(version: nil, activated: nil) }
            return DriverInfo(version: String(v), activated: parts.count > 1 ? parts[1] == "1" : true)
        }
        let version = NSDictionary(contentsOfFile: vhidManagerPlist)?["CFBundleVersion"] as? String
        guard version != nil else { return DriverInfo(version: nil, activated: nil) }
        if Date().timeIntervalSince(activation.checked) > 30 {
            activation = (Date(), checkActivated())
        }
        return DriverInfo(version: version, activated: activation.value)
    }

    private func checkActivated() -> Bool? {
        let r = runProgram("/usr/bin/systemextensionsctl", ["list"], timeout: 10)
        guard r.status == 0 else { return nil }
        let lines = r.output.split(separator: "\n").filter { $0.contains("org.pqrs.Karabiner-DriverKit-VirtualHIDDevice") }
        if lines.isEmpty { return false }
        return lines.contains { $0.contains("[activated enabled]") }
    }

    func ensureVHIDDaemon(wanted: Bool) -> VHIDDaemonOwner {
        let ours: Int32? = (vhidProcess?.isRunning == true) ? vhidProcess?.processIdentifier : nil
        let others = pidsRunning(vhidDaemonPath).filter { $0 != ours }
        if !others.isEmpty {
            // Someone else (Karabiner-Elements) runs one: only one may run.
            if let p = vhidProcess, p.isRunning {
                p.terminate()
                log("another VirtualHIDDevice daemon is running; stopped ours")
            }
            vhidProcess = nil
            return .external
        }
        if ours != nil {
            // Give a freshly started daemon a moment to open its socket.
            return Date().timeIntervalSince(vhidStartedAt) < 2 ? .none : .ours
        }
        guard wanted, FileManager.default.isExecutableFile(atPath: vhidDaemonPath) else { return .none }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: vhidDaemonPath)
        let h = appendHandle(logDir + "/vhid-daemon.log")
        p.standardOutput = h
        p.standardError = h
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            vhidProcess = p
            vhidStartedAt = Date()
            log("started the VirtualHIDDevice daemon (pid \(p.processIdentifier))")
        } catch {
            log("cannot start the VirtualHIDDevice daemon: \(error)")
        }
        try? h?.close()
        return .none
    }

    func connectedKeyboards() -> [String] {
        if let file = env["KMONAD_TEST_KEYBOARDS_FILE"] {
            return ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        if Date().timeIntervalSince(keyboardCache.checked) >= 2 {
            keyboardCache = (Date(), connectedKeyboardNames())
        }
        return keyboardCache.names
    }

    func writeCandidate(_ name: String, _ text: String) -> String? {
        let path = runDir + "/" + name + ".candidate"
        guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return path
    }

    func promoteCandidate(_ name: String) -> String? {
        let from = runDir + "/" + name + ".candidate"
        let to = runDir + "/" + name
        guard rename(from, to) == 0 else { return nil }
        return to
    }

    func validate(binary: String, config: String) -> (ok: Bool, output: String) {
        let r = runProgram(binary, ["-d", config], timeout: 10)
        return (r.status == 0, r.output)
    }

    func binaryPath(protocolVersion: Int) -> String { binDir + "/kmonad-p\(protocolVersion)" }

    func spawn(binary: String, config: String, name: String, user: ConsoleUser) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = [config]
        p.environment = [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            // cmd-button commands run as the user, never as root.
            "KMONAD_CMD_WRAPPER": binDir + "/kmonad-cmd",
            "KMONAD_CMD_UID": String(user.uid),
        ]
        let log = logPath(name)
        rotate(log, name: name)
        let h = appendHandle(log)
        h?.write(Data("==== \(timestamp()) starting \(name)\n".utf8))
        p.standardOutput = h
        p.standardError = h
        p.standardInput = FileHandle.nullDevice
        defer { try? h?.close() }
        do { try p.run() } catch {
            self.log("cannot start kmonad for \(name): \(error)")
            return nil
        }
        processes[p.processIdentifier] = p
        return p.processIdentifier
    }

    func isAlive(_ pid: Int32) -> Bool {
        guard let p = processes[pid] else { return false }
        if p.isRunning { return true }
        processes[pid] = nil
        return false
    }

    func terminate(_ pid: Int32) {
        guard let p = processes[pid] else { return }
        processes[pid] = nil
        guard p.isRunning else { return }
        p.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Waits up to `seconds` for every kmonad we started to exit.
    func waitForChildren(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while processes.values.contains(where: { $0.isRunning }) && Date() < deadline {
            usleep(100_000)
        }
        for p in processes.values where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    func newLogLines(_ name: String) -> [String] {
        let path = logPath(name)
        guard let fh = FileHandle(forReadingAtPath: path) else {
            logOffsets[name] = 0 // read a log created later from its start
            return []
        }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var offset = logOffsets[name] ?? size
        if offset > size { offset = 0 }
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            logOffsets[name] = offset
            return []
        }
        let chunk = data[data.startIndex...lastNewline]
        logOffsets[name] = offset + UInt64(chunk.count)
        return String(decoding: chunk, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func logPath(_ name: String) -> String {
        logDir + "/" + (name.hasSuffix(".kbd") ? String(name.dropLast(4)) : name) + ".log"
    }

    /// Keeps a log under 1 MB: the last 256 KB stay.
    private func rotate(_ path: String, name: String) {
        guard let s = stat(path), s.size > 1_048_576,
              let fh = FileHandle(forUpdatingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(s.size - 262_144))
        let tail = (try? fh.readToEnd()) ?? Data()
        try? fh.truncate(atOffset: 0)
        try? fh.seek(toOffset: 0)
        fh.write(tail)
        logOffsets[name] = UInt64(tail.count)
    }

    func housekeeping() {
        for name in processes.values.compactMap({ $0.arguments?.first }).map({ ($0 as NSString).lastPathComponent }) {
            rotate(logPath(name), name: name)
        }
    }

    func writeStatus(_ status: Status) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(status) else { return }
        let tmp = stateDir + "/status.json.tmp"
        let dst = stateDir + "/status.json"
        if FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o644]) {
            rename(tmp, dst)
        }
    }

    func log(_ message: String) {
        print("\(timestamp()) \(message)")
        fflush(stdout)
    }

    func reexec() {
        waitForChildren(2)
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        execv(exe, argv)
        log("re-exec failed (errno \(errno)); continuing")
    }

    /// Stops the VirtualHIDDevice daemon if we started it.
    func stopOwnVHIDDaemon() {
        if let p = vhidProcess, p.isRunning { p.terminate() }
        vhidProcess = nil
    }

    /// kmonad processes left behind by an earlier daemon that crashed.
    func killOrphans() {
        for pid in pidsRunning(inDirectory: binDir, prefix: "kmonad-p") {
            log("stopping leftover kmonad (pid \(pid))")
            kill(pid, SIGTERM)
        }
    }

    private func appendHandle(_ path: String) -> FileHandle? {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

private var daemonEffects: RealEffects?
private var daemonSupervisor: Supervisor?
private var daemonSources: [DispatchSourceProtocol] = []

func runDaemon() -> Never {
    let fx = RealEffects()
    let sup = Supervisor(effects: fx, version: appVersion)
    daemonEffects = fx
    daemonSupervisor = sup
    fx.log("KMonad daemon \(appVersion) starting (uid \(getuid()))")
    fx.killOrphans()

    signal(SIGPIPE, SIG_IGN)
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            fx.log("stopping")
            sup.stopAll()
            fx.waitForChildren(2)
            fx.stopOwnVHIDDaemon()
            exit(0)
        }
        src.resume()
        daemonSources.append(src)
    }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    var ticks = 0
    timer.schedule(deadline: .now(), repeating: 1.0)
    timer.setEventHandler {
        sup.tick()
        ticks += 1
        if ticks % 30 == 0 { fx.housekeeping() }
    }
    timer.resume()
    daemonSources.append(timer)
    dispatchMain()
}
