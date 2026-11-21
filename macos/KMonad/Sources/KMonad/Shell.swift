import Foundation
import IOKit
import IOKit.hid
import KMonadCore

/// Runs a program to completion and returns its exit status and output.
@discardableResult
func runProgram(_ path: String, _ args: [String], timeout: TimeInterval = 15,
                mergeStderr: Bool = true) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = mergeStderr ? out : FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error)") }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Keyboards as kmonad matches them: IOHIDDevice with a Generic Desktop /
/// Keyboard usage, by product name, skipping Karabiner's virtual devices.
/// Reads the IORegistry only; needs no permission.
func connectedKeyboardNames() -> [String] {
    guard let cfMatching = IOServiceMatching(kIOHIDDeviceKey) else { return [] }
    let matching = cfMatching as NSMutableDictionary
    matching[kIOHIDDeviceUsagePageKey] = NSNumber(value: kHIDPage_GenericDesktop)
    matching[kIOHIDDeviceUsageKey] = NSNumber(value: kHIDUsage_GD_Keyboard)
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, cfMatching, &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var names: [String] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
        let product = IORegistryEntryCreateCFProperty(service, kIOHIDProductKey as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        let name = product ?? "Unknown External Keyboard"
        if !name.hasPrefix("Karabiner ") && !names.contains(name) { names.append(name) }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return names
}

/// Process ids whose executable is exactly `path`.
func pidsRunning(_ path: String) -> [Int32] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(count) + 64)
    let got = pids.withUnsafeMutableBytes { buf in
        proc_listallpids(buf.baseAddress, Int32(buf.count))
    }
    guard got > 0 else { return [] }
    var result: [Int32] = []
    var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids.prefix(Int(got)) where pid > 0 {
        let n = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if n > 0 && String(cString: pathBuffer) == path { result.append(pid) }
    }
    return result
}

/// Process ids whose executable lives in `dir` and starts with `prefix`.
func pidsRunning(inDirectory dir: String, prefix: String) -> [Int32] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(count) + 64)
    let got = pids.withUnsafeMutableBytes { buf in
        proc_listallpids(buf.baseAddress, Int32(buf.count))
    }
    guard got > 0 else { return [] }
    var result: [Int32] = []
    var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let start = dir.hasSuffix("/") ? dir + prefix : dir + "/" + prefix
    for pid in pids.prefix(Int(got)) where pid > 0 && pid != getpid() {
        let n = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if n > 0 && String(cString: pathBuffer).hasPrefix(start) { result.append(pid) }
    }
    return result
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}

/// The version shown in the menu and written into status.json.
var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

/// Resources/bin inside the app (or KMONAD_BIN_DIR for tests).
var binDirectory: String {
    if let d = ProcessInfo.processInfo.environment["KMONAD_BIN_DIR"], !d.isEmpty { return d }
    return (Bundle.main.resourcePath ?? "/Applications/KMonad.app/Contents/Resources") + "/bin"
}

/// `stat` (follows symlinks) as a FileStamp; nil if the file is not there.
func fileStamp(_ path: String) -> FileStamp? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    return FileStamp(mtime: mtime, size: Int64(st.st_size), inode: UInt64(st.st_ino))
}
