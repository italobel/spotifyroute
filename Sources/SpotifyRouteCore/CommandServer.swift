import Foundation

/// Accepts commands over a Unix domain socket.
///
/// A socket rather than a custom URL scheme because LaunchServices registration for an
/// ad-hoc-signed app outside /Applications is unreliable; and rather than HTTP because
/// this needs no port allocation and is not reachable from off the machine.
public final class CommandServer {
    private let socketURL: URL
    private let handler: (Command) -> Reply

    /// Guards `listenFD` and `stopping`, which `stop()` writes from whatever thread the
    /// caller uses and the accept loop reads/writes from its own dedicated thread —
    /// the same pattern `AudioRouter.Metrics` uses for its cross-thread counters.
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = false

    private var thread: Thread?

    /// How long the accept loop waits for the main thread to run a handler before
    /// giving up. A few seconds is generous for any legitimate Core Audio call while
    /// still short enough that a wedged main thread does not take the whole control
    /// channel down with it.
    private let defaultHandlerTimeout: TimeInterval = 3.0

    /// `selftest` is the one command that is unconditionally longer than
    /// `handlerTimeout`: SelfTest.run writes a short WAV, polls for the test player to
    /// hold an output stream (up to 40 * 0.25s = 10s in the worst case), enables the
    /// router, and then sleeps for its measurement window (3s) before returning. That
    /// is comfortably north of 3s even in the common case, so `.selftest` gets its own,
    /// much longer bound; every other command keeps the tight 3s bound that protects
    /// the accept loop from a genuinely wedged main thread.
    private let selfTestHandlerTimeout: TimeInterval = 15.0

    private func handlerTimeout(for command: Command) -> TimeInterval {
        switch command {
        case .selftest: return selfTestHandlerTimeout
        default:        return defaultHandlerTimeout
        }
    }

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

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw RouteError.coreAudio("socket()", OSStatus(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw RouteError.selfTestFailed("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8.enumerated().forEach { raw[$0.offset] = $0.element }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            throw RouteError.selfTestFailed("bind() failed: errno \(errno)")
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw RouteError.selfTestFailed("listen() failed: errno \(errno)")
        }

        // Non-blocking so the accept loop can poll with a timeout instead of blocking
        // inside accept(). That means stop() never has to interrupt a blocked syscall
        // (no risk of racing a closed-and-reused descriptor into an unrelated accept),
        // and a run of accept() failures gets the poll timeout as backoff instead of
        // spinning a thread at full CPU.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        lock.lock()
        listenFD = fd
        stopping = false
        lock.unlock()

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "SpotifyRoute.CommandServer"
        t.start()
        thread = t
    }

    /// Idempotent: safe to call more than once, and safe to call after a `start()`
    /// that failed partway through (in which case `listenFD` is already -1 and this
    /// is a no-op beyond the redundant unlink).
    public func stop() {
        lock.lock()
        if stopping {
            lock.unlock()
            return
        }
        stopping = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()

        if fd >= 0 { close(fd) }
        unlink(socketURL.path)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let shouldStop = stopping
            let fd = listenFD
            lock.unlock()
            if shouldStop || fd < 0 { return }

            // A human-driven control socket, not a hot path — a few hundred ms of
            // poll latency before noticing a stop request is unnoticeable, and it
            // gives every no-connection iteration a built-in backoff.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 300)
            guard ready > 0, pfd.revents & Int16(POLLIN) != 0 else {
                continue // timeout, EINTR, or the fd went away under us — recheck stopping
            }

            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    continue
                }
                fputs("CommandServer: accept() failed: errno \(err)\n", stderr)
                continue // the poll timeout above already provides backoff
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
            reply = runOnMainThread(command)
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

    /// Runs `handler` on the main thread (Core Audio work must be serialised there)
    /// and waits for it, bounded by `handlerTimeout(for:)`. `serve()` always runs on
    /// the dedicated accept thread — never the main thread — so there is no
    /// same-thread case to special-case here.
    ///
    /// The wait is bounded rather than an unconditional `DispatchQueue.main.sync`
    /// specifically because a stalled main thread (a slow Core Audio call, a modal
    /// alert, anything) must not be able to wedge the accept loop: `serve()` only
    /// accepts the next connection after this returns, so an unbounded wait here
    /// would queue every subsequent Stream Deck press and CLI invocation behind it.
    private func runOnMainThread(_ command: Command) -> Reply {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Reply = .error("no reply")
        DispatchQueue.main.async {
            result = self.handler(command)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + handlerTimeout(for: command)) == .success else {
            return .error("app busy — timed out waiting for a reply")
        }
        return result
    }
}
