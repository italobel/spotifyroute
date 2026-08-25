import Foundation

/// Persisted user intent. Deliberately does not record whether the route is
/// currently running — that is runtime state, derived by RouteStatusRule.
public struct Settings: Codable, Equatable, Sendable {
    public var routeEnabled: Bool
    public var destinationUID: String?

    public init(routeEnabled: Bool = false, destinationUID: String? = nil) {
        self.routeEnabled = routeEnabled
        self.destinationUID = destinationUID
    }
}

public enum RouteStatus: Equatable, Sendable {
    case off
    /// Wanted and currently running.
    case active(destinationUID: String)
    /// Wanted, but not currently running. The common cause is Spotify not being
    /// launched yet — hence the UI's "waiting for Spotify" wording — but `.armed`
    /// is produced by `RouteStatusRule.derive` from `!isActive` alone, with no
    /// record of *why* the route isn't running. A route that failed to (re)apply
    /// for some other reason — e.g. a Core Audio call throwing mid-switch — also
    /// lands here, and looks, to anyone reading just this case, identical to
    /// "Spotify hasn't started." See `RouteStatusRule.derive`'s doc comment: this
    /// is a known, deliberately-deferred design limitation, not an oversight.
    case armed(destinationUID: String)
    /// Wanted, but cannot run as configured.
    case misconfigured(reason: String)

    /// Stable wire/UI label. The Stream Deck and menu bar both key off these.
    public var shortLabel: String {
        switch self {
        case .off:            return "off"
        case .active:         return "on"
        case .armed:          return "armed"
        case .misconfigured:  return "misconfigured"
        }
    }
}

public enum RouteStatusRule {
    /// Derives the user-visible route status from persisted intent plus whether the
    /// route is actually running right now.
    ///
    /// NOTE — pre-existing, deliberately deferred limitation (flagged in this
    /// project's earlier final review as "armed always blames Spotify" and left
    /// unfixed then, and again now): `.armed` is produced from `!isActive` alone,
    /// with no distinction between "Spotify isn't running yet" and "not active for
    /// any other reason" (a failed re-apply, a mid-switch Core Audio error, etc.).
    /// `.armed`'s own doc comment carries the same caveat — read it before assuming
    /// this case means Spotify specifically. Fixing this would mean `RouteStatus`
    /// (or this function's signature) carrying a reason alongside "not active,"
    /// which is a real design change, not a one-line fix; out of scope here.
    public static func derive(settings: Settings, isActive: Bool) -> RouteStatus {
        guard settings.routeEnabled else { return .off }
        guard let uid = settings.destinationUID else {
            return .misconfigured(reason: "no destination device chosen")
        }
        return isActive ? .active(destinationUID: uid) : .armed(destinationUID: uid)
    }
}

public protocol SettingsStore {
    func load() -> Settings
    func save(_ settings: Settings) throws
}

public final class FileSettingsStore: SettingsStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("SpotifyRoute/settings.json")
    }

    /// Never throws. A missing or corrupt file yields defaults, because this is
    /// read during login and a crash there would be invisible and unrecoverable.
    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return decoded
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: url, options: .atomic)
    }
}
