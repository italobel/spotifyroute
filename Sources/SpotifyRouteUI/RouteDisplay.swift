import Foundation
import SpotifyRouteCore

/// Whether Spotify exists and whether it is currently producing audio.
public enum SpotifyPresence: Equatable, Sendable {
    case notRunning
    case paused
    case playing
}

/// Whether a command is in flight. There is deliberately no `awaitingPermission`
/// case: the window calls the controller on the main thread, so while Core Audio
/// blocks on a permission dialog no timer fires and no render happens. A state that
/// could never reach the screen would be a lie.
public enum Activity: Equatable, Sendable {
    case idle
    case working
}

public struct DeviceRow: Equatable, Identifiable, Sendable {
    public let uid: String
    public let name: String
    public let isSystemDefault: Bool
    public let isChosenDestination: Bool

    /// The system default is shown but never selectable: `RouteController` refuses
    /// routing a device to itself, so offering it would be a dead end.
    public var isSelectable: Bool { !isSystemDefault }
    public var id: String { uid }

    public init(uid: String, name: String, isSystemDefault: Bool, isChosenDestination: Bool) {
        self.uid = uid
        self.name = name
        self.isSystemDefault = isSystemDefault
        self.isChosenDestination = isChosenDestination
    }
}

public struct RouteDisplay: Equatable, Sendable {
    public let spotifyLine: String
    public let routeLine: String
    public let toggleTitle: String
    public let toggleEnabled: Bool
    public let devices: [DeviceRow]
    public let problem: String?

    /// True while a command is in flight. Distinct from `DeviceRow.isSelectable`, which
    /// means "this device is a legal destination" — conflating the two would make a
    /// disabled row ambiguous between "refused" and "busy right now".
    public let isBusy: Bool
}

public enum RouteDisplayBuilder {
    public static func build(status: RouteStatus,
                             destinationUID: String?,
                             devices: [OutputDevice],
                             systemDefaultUID: String?,
                             spotify: SpotifyPresence,
                             activity: Activity) -> RouteDisplay {

        let rows = devices.map { device in
            DeviceRow(uid: device.uid,
                      name: device.name,
                      isSystemDefault: device.uid == systemDefaultUID,
                      isChosenDestination: device.uid == destinationUID)
        }

        let destinationName = destinationUID.flatMap { uid in
            devices.first { $0.uid == uid }?.name
        }

        // Problems are ordered by what blocks the user soonest.
        var problem: String? = nil
        if devices.isEmpty {
            problem = "Could not read any output devices."
        } else if case .misconfigured(let reason) = status {
            problem = reason
        } else if let uid = destinationUID, destinationName == nil {
            problem = "The chosen destination (\(uid)) is not currently available."
        }

        let spotifyLine: String
        switch spotify {
        case .playing:    spotifyLine = "Spotify is playing"
        case .paused:     spotifyLine = "Spotify is paused"
        case .notRunning: spotifyLine = "Spotify is not running"
        }

        let routeLine: String
        if activity == .working {
            routeLine = "Working…"
        } else {
            switch status {
            case .off:
                if let name = destinationName {
                    routeLine = "Off — \(name) selected"
                } else if destinationUID == nil {
                    routeLine = "Off — no destination chosen"
                } else {
                    routeLine = "Off — selected destination unavailable"
                }
            case .active:
                routeLine = "On — playing through \(destinationName ?? "unknown device")"
            case .armed:
                routeLine = "Waiting for Spotify — will route to \(destinationName ?? "unknown device")"
            case .misconfigured(let reason):
                routeLine = "Not configured — \(reason)"
            }
        }

        let routeIsOn: Bool
        switch status {
        case .active, .armed:      routeIsOn = true
        case .off, .misconfigured: routeIsOn = false
        }

        let canToggle = activity == .idle
            && (routeIsOn || (problem == nil && destinationName != nil))

        return RouteDisplay(spotifyLine: spotifyLine,
                            routeLine: routeLine,
                            toggleTitle: routeIsOn ? "Turn Off" : "Turn On",
                            toggleEnabled: canToggle,
                            devices: rows,
                            problem: problem,
                            isBusy: activity == .working)
    }
}
