import Foundation
import CoreAudio

/// Holds all command semantics. Depends only on protocols so it is unit-testable
/// without any audio hardware, which matters because this is where the interesting
/// decisions live: refusing a self-route, arming when Spotify is absent, and never
/// persisting an intent that failed to apply.
public final class RouteController {
    private let store: SettingsStore
    private let router: Routing
    private let devices: DeviceListing
    private let processes: ProcessLocating
    private let audibility: Audibility

    private var settings: Settings

    public init(store: SettingsStore,
                router: Routing,
                devices: DeviceListing,
                processes: ProcessLocating,
                audibility: Audibility) {
        self.store = store
        self.router = router
        self.devices = devices
        self.processes = processes
        self.audibility = audibility
        self.settings = store.load()
    }

    public var status: RouteStatus {
        RouteStatusRule.derive(settings: settings, isActive: router.isActive)
    }

    /// The persisted destination, exposed so UI can show a checkmark without having to
    /// parse a display string back into a UID.
    public var destinationUID: String? { settings.destinationUID }

    public func handle(_ command: Command) -> Reply {
        switch command {
        case .list:     return handleList()
        case .use(let uid): return handleUse(uid)
        case .on:       return handleOn()
        case .off:      return handleOff()
        case .toggle:   return settings.routeEnabled ? handleOff() : handleOn()
        case .status:   return handleStatus()
        case .selftest: return handleSelfTest()
        }
    }

    // MARK: - commands

    private func handleList() -> Reply {
        do {
            let all = try devices.allOutputDevices()
            let defaultUID = devices.currentDefaultUID()
            let lines = all.map { device -> String in
                var flags: [String] = []
                if device.uid == defaultUID { flags.append("system default") }
                if device.uid == settings.destinationUID { flags.append("chosen destination") }
                let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"
                return "\(device.name)\(suffix)\n    \(device.uid)"
            }
            return .ok(lines.joined(separator: "\n"))
        } catch {
            return .error("\(error)")
        }
    }

    private func handleUse(_ uid: String) -> Reply {
        do {
            let all = try devices.allOutputDevices()
            guard let device = all.first(where: { $0.uid == uid }) else {
                return .error("\(RouteError.deviceNotFound(uid))")
            }
            if uid == devices.currentDefaultUID() {
                return .error("\(RouteError.destinationIsDefault(device.name))")
            }
            // Captured before being overwritten so a route already running on the old
            // destination can be restored to its prior mute state once the new one is
            // applied below — otherwise the old device is left unmuted (and its
            // priorMute bookkeeping leaked) for good. See handleOn()'s own restore.
            let previousUID = settings.destinationUID
            settings.destinationUID = uid
            try store.save(settings)
            // If a route is already running, move it to the new destination.
            if settings.routeEnabled, router.isActive {
                if let previousUID, previousUID != uid,
                   let previousDevice = all.first(where: { $0.uid == previousUID }) {
                    audibility.restore(previousDevice)
                }
                return handleOn()
            }
            return .ok("destination set to \(device.name)")
        } catch {
            return .error("\(error)")
        }
    }

    private func handleOn() -> Reply {
        guard let uid = settings.destinationUID else {
            return .error("\(RouteError.noDestinationChosen)")
        }
        let device: OutputDevice
        do {
            guard let found = try devices.allOutputDevices().first(where: { $0.uid == uid })
            else { return .error("\(RouteError.deviceNotFound(uid))") }
            device = found
        } catch {
            return .error("\(error)")
        }

        // Refuse a destination that is (now) the system default. `handleUse` already
        // refuses this at selection time, but the system default can drift out from
        // under an already-persisted destination — e.g. the destination was the
        // built-in speakers while a USB interface was default, the interface is then
        // unplugged or sleeps, and macOS promotes the speakers to default. Without
        // this check here, every activation path (an explicit `on`, and `reapply()` at
        // login or on Spotify launch) would go on to call `audibility.prepare(device)`
        // and `router.enable(destination:...)` on what is now the system default,
        // unconditionally unmuting it and possibly raising its volume — exactly what
        // this app promises never to do to the system default, "under any
        // circumstance."
        if uid == devices.currentDefaultUID() {
            return .error("\(RouteError.destinationIsDefault(device.name))")
        }

        // Spotify absent is not a failure: remember the intent and apply on launch.
        let processObject: AudioObjectID
        do {
            processObject = try processes.spotifyProcessObject()
        } catch {
            settings.routeEnabled = true
            try? store.save(settings)
            return .ok(RouteStatus.armed(destinationUID: uid).shortLabel)
        }

        do {
            audibility.prepare(device)
            try router.enable(destination: device, processObject: processObject)
        } catch {
            // Do not persist an intent that could not be applied.
            audibility.restore(device)
            return .error("\(error)")
        }

        settings.routeEnabled = true
        try? store.save(settings)
        return .ok(RouteStatus.active(destinationUID: uid).shortLabel)
    }

    private func handleOff() -> Reply {
        router.disable()
        if let uid = settings.destinationUID,
           let device = try? devices.allOutputDevices().first(where: { $0.uid == uid }) {
            audibility.restore(device)
        }
        settings.routeEnabled = false
        try? store.save(settings)
        return .ok(RouteStatus.off.shortLabel)
    }

    private func handleStatus() -> Reply {
        let name = settings.destinationUID
            .flatMap { uid in try? devices.allOutputDevices().first { $0.uid == uid } }
            .map(\.name)
        switch status {
        case .off:
            return .ok("off" + (name.map { " (destination: \($0))" } ?? ""))
        case .active:
            return .ok("on -> \(name ?? "unknown device")")
        case .armed:
            return .ok("armed -> \(name ?? "unknown device") (waiting for Spotify)")
        case .misconfigured(let reason):
            return .ok("misconfigured: \(reason)")
        }
    }

    private func handleSelfTest() -> Reply {
        guard let uid = settings.destinationUID,
              let device = try? devices.allOutputDevices().first(where: { $0.uid == uid })
        else { return .error("\(RouteError.noDestinationChosen)") }
        do {
            let outcome = try SelfTest.run(destination: device,
                                           seconds: SelfTest.defaultMeasurementSeconds)
            return outcome.passed
                ? .ok("selftest passed — \(outcome.detail)")
                : .error("selftest failed — \(outcome.detail)")
        } catch {
            return .error("\(error)")
        }
    }

    // MARK: - lifecycle

    /// Applies a persisted-but-inactive route. Called when Spotify launches and on the
    /// isRunningOutput 0->1 edge.
    public func reapply() {
        guard settings.routeEnabled, !router.isActive else { return }
        _ = handleOn()
    }

    /// Tears down audio objects without changing persisted intent, so the route comes
    /// back on next launch.
    public func shutdown() {
        router.disable()
        if let uid = settings.destinationUID,
           let device = try? devices.allOutputDevices().first(where: { $0.uid == uid }) {
            audibility.restore(device)
        }
    }
}
