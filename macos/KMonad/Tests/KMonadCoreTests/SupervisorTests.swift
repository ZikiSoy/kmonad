import XCTest
@testable import KMonadCore

final class FakeEffects: SupervisorEffects {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var user: ConsoleUser? = ConsoleUser(name: "lily", uid: 501, home: "/Users/lily")
    var files: [String: String] = [:]          // path -> content
    var stamps: [String: Double] = [:]         // path -> mtime
    var driverInfo = DriverInfo(version: "8.5.0", activated: true)
    var daemonOwner: VHIDDaemonOwner = .external
    var keyboards = ["Apple Internal Keyboard / Trackpad"]
    var invalidMarker = "BAD"
    var alive: Set<Int32> = []
    var nextPid: Int32 = 100
    var spawned: [(name: String, binary: String)] = []
    var terminated: [Int32] = []
    var logs: [String: [String]] = [:]
    var statuses: [Status] = []
    var reexecs = 0

    func now() -> Date { clock }
    func consoleUser() -> ConsoleUser? { user }
    func stat(_ path: String) -> FileStamp? {
        guard let c = files[path] else { return nil }
        return FileStamp(mtime: stamps[path] ?? 1, size: Int64(c.utf8.count), inode: 1)
    }
    func readAsUser(_ path: String, _ user: ConsoleUser) -> String? { files[path] }
    func driver() -> DriverInfo { driverInfo }
    func ensureVHIDDaemon(wanted: Bool) -> VHIDDaemonOwner { daemonOwner }
    func connectedKeyboards() -> [String] { keyboards }
    var candidates: [String: String] = [:]
    func writeCandidate(_ name: String, _ text: String) -> String? {
        candidates[name] = text
        return "/run/\(name).candidate"
    }
    func promoteCandidate(_ name: String) -> String? { "/run/\(name)" }
    func validate(binary: String, config: String) -> (ok: Bool, output: String) {
        let name = String(config.dropFirst("/run/".count).dropLast(".candidate".count))
        let text = candidates[name] ?? ""
        return text.contains(invalidMarker) ? (false, "Parse error at line 3") : (true, "")
    }
    func binaryPath(protocolVersion: Int) -> String { "/bin/kmonad-p\(protocolVersion)" }
    func spawn(binary: String, config: String, name: String, user: ConsoleUser) -> Int32? {
        nextPid += 1
        alive.insert(nextPid)
        spawned.append((name, binary))
        return nextPid
    }
    func isAlive(_ pid: Int32) -> Bool { alive.contains(pid) }
    func terminate(_ pid: Int32) {
        alive.remove(pid)
        terminated.append(pid)
    }
    func newLogLines(_ name: String) -> [String] {
        let l = logs[name] ?? []
        logs[name] = []
        return l
    }
    func logPath(_ name: String) -> String { "/logs/\(name).log" }
    func writeStatus(_ status: Status) { statuses.append(status) }
    func log(_ message: String) {}
    func reexec() { reexecs += 1 }

    // helpers
    let dir = "/Users/lily/.config/kmonad"
    func put(_ name: String, _ content: String) {
        let p = dir + "/" + name
        files[p] = content
        stamps[p] = (stamps[p] ?? 1) + 1
    }
    func remove(_ name: String) { files[dir + "/" + name] = nil }
    func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }
}

final class SupervisorTests: XCTestCase {
    var fx: FakeEffects!
    var sup: Supervisor!
    let macbook = "(defcfg input (iokit-name \"Apple Internal Keyboard / Trackpad\") output (kext))"

    override func setUp() {
        fx = FakeEffects()
        sup = Supervisor(effects: fx, version: "test")
        fx.put("enabled", "# header\nmacbook.kbd\n")
        fx.put("macbook.kbd", macbook)
    }

    func state(_ name: String = "macbook.kbd") -> KeyboardState? {
        sup.currentStatus?.keyboards.first(where: { $0.file == name })?.state
    }

    func run(_ ticks: Int, step: TimeInterval = 1) {
        for _ in 0..<ticks {
            sup.tick()
            fx.advance(step)
        }
    }

    func testStartsAndBecomesRunning() {
        run(1)
        XCTAssertEqual(fx.spawned.count, 1)
        XCTAssertEqual(fx.spawned.first?.binary, "/bin/kmonad-p7")
        run(4)
        XCTAssertEqual(state(), .running)
        XCTAssertEqual(sup.currentStatus?.keyboards.first?.connected, true)
    }

    func testLoginWindowRunsNothing() {
        fx.user = nil
        run(3)
        XCTAssertTrue(fx.spawned.isEmpty)
        XCTAssertNil(sup.currentStatus?.user)
    }

    func testUserLeavingStopsKeyboards() {
        run(2)
        let pid = fx.nextPid
        fx.user = nil
        run(1)
        XCTAssertTrue(fx.terminated.contains(pid))
    }

    func testPauseAndResume() {
        run(2)
        fx.put(".paused", "")
        run(1)
        XCTAssertEqual(state(), .paused)
        XCTAssertTrue(fx.alive.isEmpty)
        fx.remove(".paused")
        run(1)
        XCTAssertEqual(fx.spawned.count, 2)
    }

    func testNoVirtualKeyboardMeansNothingRuns() {
        fx.driverInfo = DriverInfo(version: "8.5.0", activated: false)
        run(2)
        XCTAssertTrue(fx.spawned.isEmpty)
        XCTAssertEqual(state(), .driverNotActivated)
        fx.driverInfo = DriverInfo(version: "8.5.0", activated: true)
        fx.daemonOwner = .none
        run(1)
        XCTAssertEqual(state(), .waitingDriver)
        XCTAssertTrue(fx.spawned.isEmpty)
        fx.daemonOwner = .ours
        run(1)
        XCTAssertEqual(fx.spawned.count, 1)
    }

    func testUnsupportedAndMissingDriver() {
        fx.driverInfo = DriverInfo(version: "9.0.0", activated: true)
        run(1)
        XCTAssertEqual(state(), .driverUnsupported)
        fx.driverInfo = DriverInfo(version: nil, activated: nil)
        run(1)
        XCTAssertEqual(state(), .driverNotInstalled)
        XCTAssertTrue(fx.spawned.isEmpty)
    }

    func testProtocolFollowsDriverVersion() {
        fx.driverInfo = DriverInfo(version: "6.14.0", activated: true)
        run(1)
        XCTAssertEqual(fx.spawned.first?.binary, "/bin/kmonad-p5")
    }

    func testVirtualKeyboardLostStopsKmonad() {
        run(2)
        let pid = fx.nextPid
        fx.logs["macbook.kbd"] = ["connect_failed asio.system:2", "You may need to start Karabiner"]
        run(1)
        XCTAssertTrue(fx.terminated.contains(pid))
        XCTAssertEqual(state(), .waitingDriver)
        run(6)
        XCTAssertEqual(fx.spawned.count, 2)
    }

    func testBadConfigKeepsOldOneRunning() {
        run(4)
        let pid = fx.nextPid
        fx.put("macbook.kbd", macbook + " BAD")
        run(1)
        XCTAssertTrue(fx.alive.contains(pid))
        XCTAssertEqual(state(), .configErrorOldRunning)
        fx.put("macbook.kbd", macbook + " ;; fixed")
        run(1)
        XCTAssertFalse(fx.alive.contains(pid))
        XCTAssertEqual(fx.spawned.count, 2)
        run(4)
        XCTAssertEqual(state(), .running)
    }

    func testBadConfigFromTheStart() {
        fx.put("macbook.kbd", "BAD")
        run(2)
        XCTAssertTrue(fx.spawned.isEmpty)
        XCTAssertEqual(state(), .configError)
    }

    func testPermissionTroubleRetries() {
        run(2)
        fx.logs["macbook.kbd"] = ["IOHIDDeviceOpen error: (iokit/common) not permitted"]
        run(1)
        XCTAssertEqual(state(), .needsPermission)
        XCTAssertTrue(fx.alive.isEmpty)
        run(5)
        XCTAssertEqual(fx.spawned.count, 1)
        run(6)
        XCTAssertEqual(fx.spawned.count, 2)
        XCTAssertEqual(state(), .needsPermission) // stays until it has run cleanly
        run(4)
        XCTAssertEqual(state(), .running)
    }

    func testReloadWhileWaitingForPermissionReexecs() {
        run(2)
        fx.logs["macbook.kbd"] = ["IOHIDDeviceOpen error: (iokit/common) not permitted"]
        run(1)
        fx.put(".reload", "")
        run(1)
        XCTAssertEqual(fx.reexecs, 1)
    }

    func testCrashBacksOff() {
        run(2)
        fx.alive.removeAll()
        run(1)
        XCTAssertEqual(state(), .restarting)
        run(1)
        XCTAssertEqual(fx.spawned.count, 2)
        fx.alive.removeAll()
        run(1)
        run(1)
        XCTAssertEqual(fx.spawned.count, 2) // 2 s backoff now
        run(1)
        XCTAssertEqual(fx.spawned.count, 3)
    }

    func testSameKeyboardConflict() {
        fx.put("other.kbd", macbook)
        fx.put("enabled", "macbook.kbd\nother.kbd\n")
        run(2)
        XCTAssertEqual(fx.spawned.count, 1)
        XCTAssertEqual(state("other.kbd"), .conflict)
    }

    func testDisablingStops() {
        run(2)
        let pid = fx.nextPid
        fx.put("enabled", "")
        run(1)
        XCTAssertTrue(fx.terminated.contains(pid))
        XCTAssertEqual(sup.currentStatus?.keyboards.count, 0)
    }

    func testInvalidNamesReported() {
        fx.put("enabled", "../etc/passwd\nmacbook.kbd\n")
        run(1)
        XCTAssertEqual(state("../etc/passwd"), .invalidName)
        XCTAssertEqual(fx.spawned.count, 1)
    }

    func testNotConnectedKeyboardStillRuns() {
        fx.keyboards = []
        run(4)
        XCTAssertEqual(fx.spawned.count, 1)
        XCTAssertEqual(sup.currentStatus?.keyboards.first?.connected, false)
    }
}

final class ConfigTextTests: XCTestCase {
    func testDeviceTarget() {
        XCTAssertEqual(ConfigText.deviceTarget(in: "(defcfg input (iokit-name \"Apple Internal Keyboard / Trackpad\"))"),
                       .named("Apple Internal Keyboard / Trackpad"))
        XCTAssertEqual(ConfigText.deviceTarget(in: "(defcfg input (iokit-name))"), .all)
        XCTAssertEqual(ConfigText.deviceTarget(in: "(defcfg input (iokit-name \"OBINS\\nAnnePro2\"))"),
                       .named("OBINS\nAnnePro2"))
        XCTAssertEqual(ConfigText.deviceTarget(in: ";; (iokit-name \"Old\")\n(defcfg input (iokit-name \"New\"))"),
                       .named("New"))
        XCTAssertEqual(ConfigText.deviceTarget(in: "#| (iokit-name \"Old\") |#\n(iokit-name \"New\")"), .named("New"))
    }

    func testEnabled() {
        let p = ConfigText.parseEnabled("# c\n a.kbd \n\na.kbd\nb.txt\n../x.kbd\n.h.kbd\n")
        XCTAssertEqual(p.names, ["a.kbd"])
        XCTAssertEqual(p.invalid, ["b.txt", "../x.kbd", ".h.kbd"])
    }

    func testFileNameForKeyboard() {
        XCTAssertEqual(ConfigText.fileName(forKeyboard: "Apple Internal Keyboard / Trackpad"),
                       "apple-internal-keyboard-trackpad.kbd")
        XCTAssertEqual(ConfigText.fileName(forKeyboard: "///"), "keyboard.kbd")
    }

    func testLogEvents() {
        XCTAssertEqual(LogEvent.classify("IOHIDDeviceOpen error: (iokit/common) not permitted"), .notPermitted)
        XCTAssertEqual(LogEvent.classify("IOHIDDeviceOpen error: (iokit/common) exclusive access and device already open"),
                       .exclusiveAccess)
        XCTAssertEqual(LogEvent.classify("connect_failed asio.system:2"), .virtualKeyboardUnavailable)
        XCTAssertEqual(LogEvent.classify("driver_version_mismatched 0"), .noise)
        XCTAssertEqual(LogEvent.classify("driver_version_mismatched 1"), .driverMismatch)
        XCTAssertEqual(LogEvent.classify("driver_connected 1"), .noise)
    }

    func testProtocolMapping() {
        XCTAssertEqual(kmonadProtocol(forDriverVersion: "8.5.0"), 7)
        XCTAssertEqual(kmonadProtocol(forDriverVersion: "7.3.0"), 6)
        XCTAssertEqual(kmonadProtocol(forDriverVersion: "6.14.0"), 5)
        XCTAssertNil(kmonadProtocol(forDriverVersion: "9.0.0"))
    }
}
