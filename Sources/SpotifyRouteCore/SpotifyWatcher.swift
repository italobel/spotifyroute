import Foundation
import AppKit
import CoreAudio

/// Watches Spotify so an armed route applies itself without user action.
///
/// Two mechanisms, because they cover different cases:
///   - NSWorkspace notifications react immediately to launch and quit.
///   - A poll detects the isRunningOutput 0->1 edge, i.e. the user pressing play
///     after a fully paused Spotify released its output stream. Polling rather than a
///     property listener because the process object is only obtainable while the app
///     exists, so there is nothing stable to attach a listener to across relaunches.
public final class SpotifyWatcher {
    private let onAppeared: () -> Void
    private let onVanished: () -> Void
    private let onPlaybackStarted: () -> Void
    private let onPlaybackLevel: (Bool) -> Void

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var wasProducingOutput = false
    private var isRunning = false

    /// 2s is a deliberate compromise: fast enough that pressing play feels immediate,
    /// slow enough to be invisible in CPU use.
    private let pollInterval: TimeInterval = 2.0

    /// Why both `onPlaybackStarted` and `onPlaybackLevel` exist, since they look
    /// confusingly similar:
    ///   - `onPlaybackStarted` fires on false->true only. It drives re-applying an
    ///     armed route, and must fire exactly once per transition — firing it again
    ///     on every tick while already playing would re-apply a route that is
    ///     already correctly applied.
    ///   - `onPlaybackLevel` fires whenever the polled value differs from the
    ///     previous tick, in either direction. It drives a live UI indicator, which
    ///     needs to know about stops as well as starts. It is a level report, not an
    ///     edge report — but it still only fires on change, not on every tick,
    ///     because the UI refresh it triggers enumerates every output device and
    ///     resolves Spotify's process object, which is wasteful to redo every 2s
    ///     when nothing changed.
    public init(onAppeared: @escaping () -> Void,
                onVanished: @escaping () -> Void,
                onPlaybackStarted: @escaping () -> Void,
                onPlaybackLevel: @escaping (Bool) -> Void = { _ in }) {
        self.onAppeared = onAppeared
        self.onVanished = onVanished
        self.onPlaybackStarted = onPlaybackStarted
        self.onPlaybackLevel = onPlaybackLevel
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.bundleIdentifier == SpotifyProcess.bundleID else { return }
            self?.onAppeared()
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.bundleIdentifier == SpotifyProcess.bundleID else { return }
            // Gated on the previous value, exactly like poll()'s absent-Spotify path:
            // otherwise every quit fires a false->false "change" and refreshUI()
            // redundantly re-reads devices and Spotify's process object for a level
            // that never actually changed.
            let wasProducing = self?.wasProducingOutput ?? false
            self?.wasProducingOutput = false
            self?.onVanished()
            if wasProducing {
                self?.onPlaybackLevel(false)
            }
        })

        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    private func poll() {
        guard let object = try? SpotifyProcess.processObject() else {
            if wasProducingOutput {
                onPlaybackLevel(false)
            }
            wasProducingOutput = false
            return
        }
        let producing = SpotifyProcess.isProducingOutput(object)
        if producing && !wasProducingOutput {
            onPlaybackStarted()
        }
        if producing != wasProducingOutput {
            onPlaybackLevel(producing)
        }
        wasProducingOutput = producing
    }
}
