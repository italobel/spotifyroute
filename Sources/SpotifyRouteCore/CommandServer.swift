import Foundation

/// Accepts commands over a Unix domain socket.
///
/// A socket rather than a custom URL scheme because LaunchServices registration for an
/// ad-hoc-signed app outside /Applications is unreliable; and rather than HTTP because
/// this needs no port allocation and is not reachable from off the machine.
public final class CommandServer {
    private let socketURL: URL
    private let handler: (Command) -> Reply
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var stopping = false

    public init(socketURL: URL, handler: @escaping (Command) -> Reply) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public static var defaultSocketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("SpotifyRoute/control.sock")
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A stale socket file from a crash would make bind() fail with EADDRINUSE.
        unlink(socketURL.path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw RouteError.coreAudio("socket()", OSStatus(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw RouteError.selfTestFailed("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8.enumerated().forEach { raw[$0.offset] = $0.element }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bound == 0 else {
            close(listenFD)
            throw RouteError.selfTestFailed("bind() failed: errno \(errno)")
        }
        guard listen(listenFD, 8) == 0 else {
            close(listenFD)
            throw RouteError.selfTestFailed("listen() failed: errno \(errno)")
        }

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "SpotifyRoute.CommandServer"
        t.start()
        thread = t
    }

    public func stop() {
        stopping = true
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketURL.path)
    }

    private func acceptLoop() {
        while !stopping {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if stopping { return }
                continue
            }
            serve(clientFD)
            close(clientFD)
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0,
              let line = String(bytes: buffer[0..<count], encoding: .utf8)
        else { return }

        let reply: Reply
        switch parseCommand(line) {
        case .success(let command):
            // Core Audio work is serialised onto the main thread; the app's run loop
            // is never blocked for long, so this cannot deadlock in practice.
            var result: Reply = .error("no reply")
            if Thread.isMainThread {
                result = handler(command)
            } else {
                DispatchQueue.main.sync { result = handler(command) }
            }
            reply = result
        case .failure(let error):
            switch error {
            case .empty:
                reply = .error("empty command")
            case .unknown(let verb):
                reply = .error("unknown command '\(verb)' — try on, off, toggle, status, list, use <uid>, selftest")
            case .missingArgument(let verb):
                reply = .error("'\(verb)' needs an argument, e.g. use <device-uid>")
            }
        }

        let payload = encodeReply(reply) + "\n"
        _ = payload.withCString { write(fd, $0, strlen($0)) }
    }
}
