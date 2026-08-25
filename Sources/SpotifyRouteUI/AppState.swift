import Foundation
import SwiftUI
import SpotifyRouteCore

/// Observable shell around `RouteDisplayBuilder`. Deliberately holds no decisions:
/// every string and every enabled flag is derived, so the logic stays in the pure,
/// tested builder and this type stays trivial.
///
/// Main-thread only: all mutations (`apply`, `beginWork`, `endWork`) must be called from the
/// main thread. SwiftUI publishes changes on the main thread, so background mutations would
/// violate the observable layer's invariants.
public final class AppState: ObservableObject {

    /// Everything the display needs, captured at one instant.
    public struct Snapshot: Equatable, Sendable {
        public let status: RouteStatus
        public let destinationUID: String?
        public let devices: [OutputDevice]
        public let systemDefaultUID: String?
        public let spotify: SpotifyPresence

        public init(status: RouteStatus,
                    destinationUID: String?,
                    devices: [OutputDevice],
                    systemDefaultUID: String?,
                    spotify: SpotifyPresence) {
            self.status = status
            self.destinationUID = destinationUID
            self.devices = devices
            self.systemDefaultUID = systemDefaultUID
            self.spotify = spotify
        }
    }

    @Published public private(set) var display: RouteDisplay

    /// The most recent snapshot, kept so `endWork()` can rebuild from real state
    /// rather than leaving a stale "Working…" on screen.
    private var latest: Snapshot
    private var activity: Activity = .idle

    public init() {
        let empty = Snapshot(status: .off, destinationUID: nil, devices: [],
                             systemDefaultUID: nil, spotify: .notRunning)
        self.latest = empty
        self.display = RouteDisplayBuilder.build(status: empty.status,
                                                 destinationUID: empty.destinationUID,
                                                 devices: empty.devices,
                                                 systemDefaultUID: empty.systemDefaultUID,
                                                 spotify: empty.spotify,
                                                 activity: .idle)
    }

    public func apply(_ snapshot: Snapshot) {
        latest = snapshot
        rebuild()
    }

    public func beginWork() {
        activity = .working
        rebuild()
    }

    public func endWork() {
        activity = .idle
        rebuild()
    }

    private func rebuild() {
        display = RouteDisplayBuilder.build(status: latest.status,
                                            destinationUID: latest.destinationUID,
                                            devices: latest.devices,
                                            systemDefaultUID: latest.systemDefaultUID,
                                            spotify: latest.spotify,
                                            activity: activity)
    }
}
