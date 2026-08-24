import Foundation

public enum Command: Equatable, Sendable {
    case on
    case off
    case toggle
    case status
    case list
    case selftest
    case use(String)
}

public enum CommandParseError: Error, Equatable, Sendable {
    case empty
    case unknown(String)
    case missingArgument(String)
}

public enum Reply: Equatable, Sendable {
    case ok(String)
    case error(String)
}

/// Parses one line of the control protocol.
///
/// `use` is split on the first space only, so device UIDs containing spaces —
/// which real USB interfaces do have — survive intact.
public func parseCommand(_ line: String) -> Result<Command, CommandParseError> {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .failure(.empty) }

    let verb: String
    let rest: String
    if let spaceIndex = trimmed.firstIndex(of: " ") {
        verb = String(trimmed[trimmed.startIndex..<spaceIndex])
        rest = String(trimmed[trimmed.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        verb = trimmed
        rest = ""
    }

    switch verb.lowercased() {
    case "on":       return .success(.on)
    case "off":      return .success(.off)
    case "toggle":   return .success(.toggle)
    case "status":   return .success(.status)
    case "list":     return .success(.list)
    case "selftest": return .success(.selftest)
    case "use":
        guard !rest.isEmpty else { return .failure(.missingArgument("use")) }
        return .success(.use(rest))
    default:
        return .failure(.unknown(verb))
    }
}

public func encodeCommand(_ command: Command) -> String {
    switch command {
    case .on:            return "on"
    case .off:           return "off"
    case .toggle:        return "toggle"
    case .status:        return "status"
    case .list:          return "list"
    case .selftest:      return "selftest"
    case .use(let uid):  return "use \(uid)"
    }
}

public func encodeReply(_ reply: Reply) -> String {
    switch reply {
    case .ok(let body):    return "ok \(body)"
    case .error(let body): return "error \(body)"
    }
}

/// Anything that is not a well-formed `ok ...` is surfaced as an error rather than
/// being dropped, so a protocol mismatch is visible instead of looking like success.
public func parseReply(_ line: String) -> Reply {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "ok" { return .ok("") }
    if trimmed.hasPrefix("ok ") { return .ok(String(trimmed.dropFirst(3))) }
    if trimmed.hasPrefix("error ") { return .error(String(trimmed.dropFirst(6))) }
    return .error(trimmed)
}
