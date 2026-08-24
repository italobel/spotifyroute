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

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var wasProducingOutput = false
    private var isRunning = false

    /// 2s is a deliberate compromise: fast enough that pressing play feels immediate,
    /// slow enough to be invisible in CPU use.
    private let pollInterval: TimeInterval = 2.0

    public init(onAppeared: @escaping () -> Void,
                onVanished: @escaping () -> Void,
                onPlaybackStarted: @escaping () -> Void) {
        self.onAppeared = onAppeared
        self.onVanished = onVanished
        self.onPlaybackStarted = onPlaybackStarted
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
            self?.wasProducingOutput = false
            self?.onVanished()
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
            wasProducingOutput = false
            return
        }
        let producing = SpotifyProcess.isProducingOutput(object)
        if producing && !wasProducingOutput {
            onPlaybackStarted()
        }
        wasProducingOutput = producing
    }
}
