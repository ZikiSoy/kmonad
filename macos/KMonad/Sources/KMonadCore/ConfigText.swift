import Foundation

/// Parsing of the user's files in ~/.config/kmonad.
public enum ConfigText {
    /// A config file name we accept in `enabled`: `something.kbd`, no path.
    public static func isValidName(_ name: String) -> Bool {
        name.count > 4 && name.hasSuffix(".kbd") && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\0")
    }

    /// `enabled`: one file name per line, `#` comments, duplicates ignored.
    public static func parseEnabled(_ text: String) -> (names: [String], invalid: [String]) {
        var names: [String] = []
        var invalid: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if isValidName(line) {
                if !names.contains(line) { names.append(line) }
            } else if !invalid.contains(line) {
                invalid.append(line)
            }
        }
        return (names, invalid)
    }

    /// Renders `enabled` back, keeping a header comment.
    public static func renderEnabled(_ names: [String]) -> String {
        "# KMonad: enabled configs, one file name per line\n" + names.map { $0 + "\n" }.joined()
    }

    /// The keyboard a config grabs, from `(iokit-name "...")` outside comments.
    /// No `iokit-name` at all is treated like an empty one: every keyboard.
    public static func deviceTarget(in text: String) -> DeviceTarget {
        let code = stripComments(text)
        let pattern = #"\(\s*iokit-name\s*("(?:[^"\\]|\\.)*")?\s*\)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return .all }
        let ns = code as NSString
        guard let m = re.firstMatch(in: code, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return .all
        }
        let r = m.range(at: 1)
        if r.location == NSNotFound { return .all }
        let quoted = ns.substring(with: r)
        let inner = String(quoted.dropFirst().dropLast())
        let name = unescape(inner)
        return name.isEmpty ? .all : .named(name)
    }

    /// Removes `#| ... |#` block comments and `;;` line comments.
    static func stripComments(_ text: String) -> String {
        var out = text
        if let block = try? NSRegularExpression(pattern: #"#\|.*?\|#"#, options: [.dotMatchesLineSeparators]) {
            let ns = out as NSString
            out = block.stringByReplacingMatches(in: out, options: [], range: NSRange(location: 0, length: ns.length),
                                                 withTemplate: "")
        }
        return out.components(separatedBy: "\n").map { line -> String in
            var inString = false
            var escaped = false
            var previous: Character? = nil
            var result = ""
            for ch in line {
                if inString {
                    if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                } else if ch == "\"" {
                    inString = true
                } else if ch == ";" && previous == ";" {
                    result.removeLast()
                    return result
                }
                result.append(ch)
                previous = ch
            }
            return result
        }.joined(separator: "\n")
    }

    /// Haskell-style escapes as kmonad's parser reads them.
    static func unescape(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// A file name for a new config made for a keyboard.
    public static func fileName(forKeyboard name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var slug = ""
        var lastDash = false
        for scalar in name.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash && !slug.isEmpty {
                slug.append("-")
                lastDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return (slug.isEmpty ? "keyboard" : slug) + ".kbd"
    }

    /// Escapes a keyboard name for a kbd string literal.
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}

/// What a line of kmonad's output means for the supervisor.
public enum LogEvent: Equatable {
    case notPermitted
    case exclusiveAccess
    case virtualKeyboardUnavailable
    case driverMismatch
    case noise
    case other(String)

    public static func classify(_ rawLine: String) -> LogEvent {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("==== ") { return .noise }
        if line.contains("IOHIDDeviceOpen") {
            if line.contains("not permitted") { return .notPermitted }
            if line.contains("exclusive access") { return .exclusiveAccess }
            return .other(line)
        }
        if line.hasPrefix("connect_failed") || line.contains("You may need to start Karabiner") || line == "closed" {
            return .virtualKeyboardUnavailable
        }
        if line.hasPrefix("driver_version_mismatched") {
            return (line.hasSuffix(" 1") || line.hasSuffix(" true")) ? .driverMismatch : .noise
        }
        let noisy = ["connected", "driver_connected", "driver_activated", "virtual_hid_keyboard_ready",
                     "error_occurred", "virtual_hid_pointing_ready"]
        if noisy.contains(where: { line.hasPrefix($0) }) { return .noise }
        return .other(line)
    }
}
