import Foundation

/// Everything the supervisor does to the outside world. The daemon passes the
/// real implementation; tests pass a fake.
public protocol SupervisorEffects: AnyObject {
    func now() -> Date
    /// nil at the login window / when nobody is logged in.
    func consoleUser() -> ConsoleUser?
    /// Metadata only (follows symlinks). Never opens the file.
    func stat(_ path: String) -> FileStamp?
    /// Reads a file with the user's own permissions.
    func readAsUser(_ path: String, _ user: ConsoleUser) -> String?
    func driver() -> DriverInfo
    /// Makes sure exactly one VirtualHIDDevice daemon runs when `wanted`.
    func ensureVHIDDaemon(wanted: Bool) -> VHIDDaemonOwner
    /// Product names of connected keyboards (as kmonad would match them).
    func connectedKeyboards() -> [String]
    /// Writes `<name>.candidate` in the root-only run dir; returns its path.
    func writeCandidate(_ name: String, _ text: String) -> String?
    /// Renames the candidate to the snapshot kmonad runs; returns its path.
    func promoteCandidate(_ name: String) -> String?
    /// `kmonad -d`.
    func validate(binary: String, config: String) -> (ok: Bool, output: String)
    func binaryPath(protocolVersion: Int) -> String
    func spawn(binary: String, config: String, name: String, user: ConsoleUser) -> Int32?
    func isAlive(_ pid: Int32) -> Bool
    func terminate(_ pid: Int32)
    /// New complete lines in this config's log since the last call.
    func newLogLines(_ name: String) -> [String]
    func logPath(_ name: String) -> String
    func writeStatus(_ status: Status)
    func log(_ message: String)
    /// Replaces the daemon process with a fresh copy (re-evaluates permissions).
    func reexec()
}

/// Keeps one healthy kmonad per enabled config of the console user.
/// `tick()` is called once a second.
public final class Supervisor {
    final class Instance {
        let name: String
        var stamp: FileStamp?
        var loaded = false
        var snapshot: String?
        var target: DeviceTarget = .all
        var pendingError: String?
        var pid: Int32?
        var startedAt: Date?
        var state: KeyboardState = .starting
        var message = ""
        var lastOutput = ""
        var failures = 0
        var nextStart: Date?
        var troubleSince: Date?
        var restartRequested = false
        init(name: String) { self.name = name }
    }

    let fx: SupervisorEffects
    let version: String
    private(set) var user: ConsoleUser?
    private var instances: [String: Instance] = [:]
    private var enabled: [String] = []
    private var invalid: [String] = []
    private var enabledStamp: FileStamp?
    private var enabledLoaded = false
    private var reloadStamp: FileStamp?
    private var reloadSeen = false
    private var paused = false
    private var driverStatus = DriverStatus(installed: false, version: nil, protocolVersion: nil,
                                            supported: false, activated: nil, daemon: .none)
    private var keyboards: [String] = []
    private var lastPublished: Status?
    private var lastPublishTime = Date.distantPast

    /// Trouble (no permission, keyboard taken) is retried every 10 s, then every 60 s.
    static let troubleRetry: TimeInterval = 10
    static let troubleRetrySlow: TimeInterval = 60
    static let troubleSlowAfter: TimeInterval = 300
    static let backoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    static let healthyAfter: TimeInterval = 3
    static let resetFailuresAfter: TimeInterval = 60

    public init(effects: SupervisorEffects, version: String) {
        self.fx = effects
        self.version = version
    }

    // MARK: - tick

    public func tick() {
        let now = fx.now()

        // 1. Follow the console user; nobody logged in = no remapping.
        let current = fx.consoleUser()
        if current != user {
            stopAll()
            instances = [:]
            enabled = []
            invalid = []
            enabledStamp = nil
            enabledLoaded = false
            reloadStamp = nil
            reloadSeen = false
            if let old = user { fx.log("user \(old.name) is no longer at the console") }
            user = current
            if let u = current { fx.log("console user: \(u.name)") }
        }
        guard let user = user else {
            driverStatus.daemon = fx.ensureVHIDDaemon(wanted: false)
            publish(now)
            return
        }
        let dir = user.configDir

        // 2. Pause and reload requests (metadata only).
        paused = fx.stat(dir + "/.paused") != nil
        let r = fx.stat(dir + "/.reload")
        let reload = reloadSeen && r != reloadStamp
        reloadStamp = r
        reloadSeen = true
        if reload { fx.log("reload requested") }

        // 3. Enabled list.
        let es = fx.stat(dir + "/enabled")
        if !enabledLoaded || es != enabledStamp || reload {
            enabledStamp = es
            enabledLoaded = true
            if es != nil, let text = fx.readAsUser(dir + "/enabled", user) {
                let parsed = ConfigText.parseEnabled(text)
                enabled = parsed.names
                invalid = parsed.invalid
            } else {
                enabled = []
                invalid = []
            }
        }
        for name in Array(instances.keys) where !enabled.contains(name) {
            if let inst = instances[name] { stop(inst, reason: "disabled") }
            instances[name] = nil
        }

        // 4. Driver and virtual keyboard: without them kmonad would grab the
        //    keyboard and send nothing, so nothing runs.
        let d = fx.driver()
        let proto = d.version.flatMap(kmonadProtocol(forDriverVersion:))
        let wantDaemon = !enabled.isEmpty && !paused && proto != nil && d.activated != false
        let owner = fx.ensureVHIDDaemon(wanted: wantDaemon)
        driverStatus = DriverStatus(installed: d.version != nil, version: d.version, protocolVersion: proto,
                                    supported: proto != nil, activated: d.activated, daemon: owner)
        var blocked: KeyboardState? = nil
        if d.version == nil { blocked = .driverNotInstalled }
        else if proto == nil { blocked = .driverUnsupported }
        else if d.activated == false { blocked = .driverNotActivated }
        else if owner == .none { blocked = .waitingDriver }

        // 5. A reload while a keyboard waits for permission: start over in a
        //    fresh process so macOS looks at the permission again.
        if reload && instances.values.contains(where: { $0.state == .needsPermission }) {
            fx.log("reload with a keyboard waiting for permission: restarting the daemon")
            stopAll()
            fx.reexec()
            return
        }

        keyboards = fx.connectedKeyboards()
        var claimed: [(DeviceTarget, String)] = []
        for name in enabled {
            let inst: Instance
            if let existing = instances[name] {
                inst = existing
            } else {
                inst = Instance(name: name)
                instances[name] = inst
            }
            handle(inst, user: user, dir: dir, now: now, reload: reload, blocked: blocked, proto: proto,
                   claimed: &claimed)
        }
        publish(now)
    }

    private func handle(_ inst: Instance, user: ConsoleUser, dir: String, now: Date, reload: Bool,
                        blocked: KeyboardState?, proto: Int?, claimed: inout [(DeviceTarget, String)]) {
        if paused {
            stop(inst, reason: "paused")
            inst.state = .paused
            inst.message = ""
            return
        }

        // Config: re-read only when the file changed (or on reload).
        let path = dir + "/" + inst.name
        guard let stamp = fx.stat(path) else {
            stop(inst, reason: "file missing")
            inst.stamp = nil
            inst.loaded = false
            inst.state = .missing
            inst.message = ""
            return
        }
        if !inst.loaded || stamp != inst.stamp || reload {
            inst.stamp = stamp
            inst.loaded = true
            load(inst, path: path, user: user, proto: proto)
        }
        guard inst.snapshot != nil else {
            inst.state = .configError
            inst.message = inst.pendingError ?? ""
            return
        }

        if let b = blocked {
            stop(inst, reason: "virtual keyboard not available")
            inst.state = b
            inst.message = ""
            return
        }

        if let other = claimed.first(where: { $0.0.overlaps(inst.target) }) {
            stop(inst, reason: "same keyboard as \(other.1)")
            inst.state = .conflict
            inst.message = other.1
            return
        }
        claimed.append((inst.target, inst.name))

        // A running kmonad: did it exit, or report trouble?
        if let pid = inst.pid {
            if !fx.isAlive(pid) {
                inst.pid = nil
                inst.startedAt = nil
                exited(inst, now: now, lines: fx.newLogLines(inst.name))
            } else if inst.restartRequested || reload {
                stop(inst, reason: "reload")
                inst.nextStart = now
            } else {
                scanLog(inst, now: now)
            }
        }

        if inst.pid == nil {
            if reload { inst.nextStart = now }
            if now >= (inst.nextStart ?? now), let proto = proto {
                start(inst, proto: proto, user: user, now: now)
            }
        } else if let started = inst.startedAt {
            let up = now.timeIntervalSince(started)
            let settling: [KeyboardState] = [.starting, .restarting, .needsPermission, .keyboardInUse, .waitingDriver]
            if up >= Supervisor.healthyAfter && settling.contains(inst.state) {
                inst.state = .running
                inst.message = ""
            }
            if up >= Supervisor.resetFailuresAfter {
                inst.failures = 0
                inst.troubleSince = nil
            }
        }

        if let e = inst.pendingError, inst.pid != nil {
            inst.state = .configErrorOldRunning
            inst.message = e
        }
    }

    private func load(_ inst: Instance, path: String, user: ConsoleUser, proto: Int?) {
        guard let text = fx.readAsUser(path, user) else {
            inst.pendingError = "无法读取 \(inst.name)"
            fx.log("\(inst.name): cannot read")
            return
        }
        guard let candidate = fx.writeCandidate(inst.name, text) else {
            inst.pendingError = "无法保存配置快照"
            return
        }
        // Parsing is the same in every build, so any binary can check it.
        let result = fx.validate(binary: fx.binaryPath(protocolVersion: proto ?? 7), config: candidate)
        if result.ok, let snapshot = fx.promoteCandidate(inst.name) {
            inst.snapshot = snapshot
            inst.target = ConfigText.deviceTarget(in: text)
            inst.pendingError = nil
            inst.restartRequested = inst.pid != nil
            if inst.pid == nil { inst.nextStart = nil } // a changed config is tried right away
            if inst.state == .configError || inst.state == .configErrorOldRunning {
                inst.state = .starting
                inst.message = ""
            }
            fx.log("\(inst.name): config loaded")
        } else {
            let lines = result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            inst.pendingError = lines.last ?? "配置有误"
            fx.log("\(inst.name): config rejected: \(inst.pendingError ?? "")")
        }
    }

    private func scanLog(_ inst: Instance, now: Date) {
        for line in fx.newLogLines(inst.name) {
            switch LogEvent.classify(line) {
            case .notPermitted:
                trouble(inst, .needsPermission, line, now: now)
                return
            case .exclusiveAccess:
                trouble(inst, .keyboardInUse, line, now: now)
                return
            case .virtualKeyboardUnavailable:
                stop(inst, reason: "virtual keyboard unavailable")
                inst.state = .waitingDriver
                inst.message = ""
                inst.nextStart = now.addingTimeInterval(5)
                return
            case .driverMismatch:
                stop(inst, reason: "driver version mismatch")
                inst.state = .driverMismatch
                inst.message = line
                inst.nextStart = now.addingTimeInterval(60)
                return
            case .other(let text):
                inst.lastOutput = text
            case .noise:
                break
            }
        }
    }

    private func trouble(_ inst: Instance, _ state: KeyboardState, _ line: String, now: Date) {
        stop(inst, reason: state.rawValue)
        inst.state = state
        inst.message = line
        let since = inst.troubleSince ?? now
        inst.troubleSince = since
        let slow = now.timeIntervalSince(since) >= Supervisor.troubleSlowAfter
        inst.nextStart = now.addingTimeInterval(slow ? Supervisor.troubleRetrySlow : Supervisor.troubleRetry)
    }

    private func exited(_ inst: Instance, now: Date, lines: [String]) {
        var message = inst.lastOutput
        for line in lines {
            switch LogEvent.classify(line) {
            case .notPermitted:
                trouble(inst, .needsPermission, line, now: now)
                return
            case .exclusiveAccess:
                trouble(inst, .keyboardInUse, line, now: now)
                return
            case .other(let text):
                message = text
            default:
                break
            }
        }
        inst.failures += 1
        let delay = Supervisor.backoff[min(inst.failures, Supervisor.backoff.count) - 1]
        inst.nextStart = now.addingTimeInterval(delay)
        inst.state = .restarting
        inst.message = message
        fx.log("\(inst.name) exited; restarting in \(Int(delay)) s")
    }

    private func start(_ inst: Instance, proto: Int, user: ConsoleUser, now: Date) {
        guard let snapshot = inst.snapshot else { return }
        _ = fx.newLogLines(inst.name) // skip output of earlier runs
        if let pid = fx.spawn(binary: fx.binaryPath(protocolVersion: proto), config: snapshot,
                              name: inst.name, user: user) {
            inst.pid = pid
            inst.startedAt = now
            inst.restartRequested = false
            inst.nextStart = nil
            if inst.state != .needsPermission && inst.state != .keyboardInUse {
                inst.state = .starting
                inst.message = ""
            }
            fx.log("started \(inst.name) (pid \(pid))")
        } else {
            inst.failures += 1
            inst.state = .restarting
            inst.message = "无法启动 kmonad"
            inst.nextStart = now.addingTimeInterval(30)
        }
    }

    private func stop(_ inst: Instance, reason: String) {
        if let pid = inst.pid {
            fx.terminate(pid)
            fx.log("stopped \(inst.name) (\(reason))")
        }
        inst.pid = nil
        inst.startedAt = nil
    }

    public func stopAll() {
        for inst in instances.values { stop(inst, reason: "stopping all") }
    }

    // MARK: - status

    private func publish(_ now: Date) {
        var list: [KeyboardStatus] = []
        for name in enabled {
            guard let inst = instances[name] else { continue }
            list.append(KeyboardStatus(file: name, device: inst.target.name, allKeyboards: inst.target == .all,
                                       connected: inst.target.isConnected(keyboards), state: inst.state,
                                       message: inst.message, restarts: inst.failures,
                                       log: fx.logPath(name), running: inst.pid != nil))
        }
        for name in invalid {
            list.append(KeyboardStatus(file: name, device: nil, allKeyboards: false, connected: false,
                                       state: .invalidName, message: "", restarts: 0, log: "", running: false))
        }
        var status = Status(version: version, updated: 0, user: user?.name, paused: paused,
                            driver: driverStatus, keyboards: list)
        if status != lastPublished || now.timeIntervalSince(lastPublishTime) >= 5 {
            lastPublished = status
            lastPublishTime = now
            status.updated = now.timeIntervalSince1970
            fx.writeStatus(status)
        }
    }

    /// For tests and `--status`: the last published status.
    public var currentStatus: Status? { lastPublished }
}
