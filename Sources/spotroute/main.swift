import Foundation
import SpotifyRouteCore

// A thin socket client. It deliberately contains no Core Audio code at all: a process
// tap outside a signed .app bundle silently returns zeroed audio, so all audio work
// belongs to the bundled app. This binary only asks the app to do things.

let usage = """
spotroute — control SpotifyRoute

  spotroute on              route Spotify to the chosen destination
  spotroute off             send Spotify back to the system default
  spotroute toggle          flip between the two
  spotroute status          show current state
  spotroute list            list available output devices
  spotroute use "<uid>"     choose the destination device (quote UID if it contains spaces)
  spotroute selftest        verify audio really flows (uses the app's permission)

Stream Deck: use a Multi Action Switch whose two states run
'spotroute on' and 'spotroute off', so the key icon tracks the real state.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    FileHandle.standardError.write((usage + "\n").data(using: .utf8)!)
    exit(2)
}
if arguments.first == "-h" || arguments.first == "--help" {
    print(usage)
    exit(0)
}

// Validate locally so a typo does not need a round trip.
let line = arguments.joined(separator: " ")
if case .failure(let error) = parseCommand(line) {
    switch error {
    case .empty:
        FileHandle.standardError.write("error: empty command\n".data(using: .utf8)!)
    case .unknown(let verb):
        FileHandle.standardError.write("error: unknown command '\(verb)'\n\n\(usage)\n"
            .data(using: .utf8)!)
    case .missingArgument(let verb):
        FileHandle.standardError.write("error: '\(verb)' needs an argument\n\n\(usage)\n"
            .data(using: .utf8)!)
    }
    exit(2)
}

let socketPath = CommandServer.defaultSocketURL.path

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    FileHandle.standardError.write("error: could not create socket\n".data(using: .utf8)!)
    exit(1)
}
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)

// Check path length against sun_path buffer (104 bytes on Darwin)
let pathBytes = socketPath.utf8
if pathBytes.count >= MemoryLayout<sockaddr_un>.size - MemoryLayout.offset(of: \sockaddr_un.sun_path)! {
    FileHandle.standardError.write("error: socket path too long: \(socketPath)\n".data(using: .utf8)!)
    exit(1)
}

withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    pathBytes.enumerated().forEach { raw[$0.offset] = $0.element }
}
let size = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
}
guard connected == 0 else {
    FileHandle.standardError.write("""
        error: SpotifyRoute is not running (no socket at \(socketPath))

        Start it with:  open /Applications/SpotifyRoute.app
        or from a build: open ./build/SpotifyRoute.app

        """.data(using: .utf8)!)
    exit(1)
}

_ = (line + "\n").withCString { write(fd, $0, strlen($0)) }

var response = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let count = read(fd, &buffer, buffer.count)
    if count == 0 {
        // EOF - connection closed, no more data
        break
    } else if count < 0 {
        // Error on read
        if errno == EINTR {
            // Interrupted; retry
            continue
        } else {
            FileHandle.standardError.write("error: read failed: \(String(cString: strerror(errno)))\n"
                .data(using: .utf8)!)
            exit(1)
        }
    } else {
        response.append(contentsOf: buffer[0..<count])
    }
}

let text = String(data: response, encoding: .utf8) ?? ""
switch parseReply(text) {
case .ok(let body):
    if !body.isEmpty { print(body) }
    exit(0)
case .error(let body):
    FileHandle.standardError.write("error: \(body)\n".data(using: .utf8)!)
    exit(1)
}
