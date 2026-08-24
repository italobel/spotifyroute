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
    /// Wanted, but not running — typically Spotify is not launched yet.
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
