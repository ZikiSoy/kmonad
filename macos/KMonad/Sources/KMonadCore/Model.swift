import Foundation

/// Label of the root LaunchDaemon installed by the .pkg.
public let daemonLabel = "io.github.zikisoy.kmonad.daemon"
/// Where the daemon publishes its state for the menu (world readable).
public let defaultStateDir = "/Library/Application Support/KMonad"
public let defaultLogDir = "/Library/Logs/KMonad"

/// The person sitting at the Mac (the console user).
public struct ConsoleUser: Equatable {
    public var name: String
    public var uid: UInt32
    public var home: String
    public init(name: String, uid: UInt32, home: String) {
        self.name = name
        self.uid = uid
        self.home = home
    }
    public var configDir: String { home + "/.config/kmonad" }
}

/// What `stat` says about a file; a change in any field means "changed".
public struct FileStamp: Equatable {
    public var mtime: Double
    public var size: Int64
    public var inode: UInt64
    public init(mtime: Double, size: Int64, inode: UInt64) {
        self.mtime = mtime
        self.size = size
        self.inode = inode
    }
}

/// The Karabiner VirtualHIDDevice driver as installed on this Mac.
public struct DriverInfo: Equatable {
    /// CFBundleVersion of the manager app; nil = not installed.
    public var version: String?
    /// nil = unknown.
    public var activated: Bool?
    public init(version: String?, activated: Bool?) {
        self.version = version
        self.activated = activated
    }
}

/// Who runs the Karabiner VirtualHIDDevice daemon.
public enum VHIDDaemonOwner: String, Codable {
    case ours, external, none
}

/// Which physical keyboard a config grabs (kmonad's `iokit-name`).
public enum DeviceTarget: Equatable {
    /// `(iokit-name)` with no name: every keyboard.
    case all
    case named(String)

    public var name: String? {
        if case .named(let n) = self { return n }
        return nil
    }

    /// Two configs that would grab the same keyboard.
    public func overlaps(_ other: DeviceTarget) -> Bool {
        switch (self, other) {
        case (.named(let a), .named(let b)): return a == b
        default: return true
        }
    }

    public func isConnected(_ keyboards: [String]) -> Bool {
        switch self {
        case .all: return !keyboards.isEmpty
        case .named(let n): return keyboards.contains(n)
        }
    }
}

public enum KeyboardState: String, Codable {
    case starting
    case running
    case paused
    case waitingDriver
    case driverNotInstalled
    case driverNotActivated
    case driverUnsupported
    case driverMismatch
    case needsPermission
    case keyboardInUse
    case configError
    case configErrorOldRunning
    case conflict
    case restarting
    case missing
    case invalidName
}

public struct KeyboardStatus: Codable, Equatable {
    public var file: String
    /// The `iokit-name`; nil with `allKeyboards` = every keyboard.
    public var device: String?
    public var allKeyboards: Bool
    public var connected: Bool
    public var state: KeyboardState
    public var message: String
    public var restarts: Int
    public var log: String
    public var running: Bool

    public init(file: String, device: String?, allKeyboards: Bool, connected: Bool,
                state: KeyboardState, message: String, restarts: Int, log: String, running: Bool) {
        self.file = file
        self.device = device
        self.allKeyboards = allKeyboards
        self.connected = connected
        self.state = state
        self.message = message
        self.restarts = restarts
        self.log = log
        self.running = running
    }
}

public struct DriverStatus: Codable, Equatable {
    public var installed: Bool
    public var version: String?
    public var protocolVersion: Int?
    public var supported: Bool
    public var activated: Bool?
    public var daemon: VHIDDaemonOwner

    public init(installed: Bool, version: String?, protocolVersion: Int?, supported: Bool,
                activated: Bool?, daemon: VHIDDaemonOwner) {
        self.installed = installed
        self.version = version
        self.protocolVersion = protocolVersion
        self.supported = supported
        self.activated = activated
        self.daemon = daemon
    }
}

/// Written by the daemon to `<state dir>/status.json`, read by the menu.
public struct Status: Codable, Equatable {
    public var version: String
    public var updated: Double
    public var user: String?
    public var paused: Bool
    public var driver: DriverStatus
    public var keyboards: [KeyboardStatus]

    public init(version: String, updated: Double, user: String?, paused: Bool,
                driver: DriverStatus, keyboards: [KeyboardStatus]) {
        self.version = version
        self.updated = updated
        self.user = user
        self.paused = paused
        self.driver = driver
        self.keyboards = keyboards
    }

    public static func load(from path: String) -> Status? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }
}

/// VirtualHIDDevice major version → client protocol of the kmonad build to use.
public func kmonadProtocol(forDriverVersion version: String) -> Int? {
    guard let major = Int(version.split(separator: ".").first ?? "") else { return nil }
    switch major {
    case 6: return 5
    case 7: return 6
    case 8: return 7
    default: return nil
    }
}
