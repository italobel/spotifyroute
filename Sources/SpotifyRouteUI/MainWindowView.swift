import SwiftUI

public struct MainWindowView: View {
    @ObservedObject private var state: AppState
    private let onToggle: () -> Void
    private let onChooseDevice: (String) -> Void

    public init(state: AppState,
                onToggle: @escaping () -> Void,
                onChooseDevice: @escaping (String) -> Void) {
        self.state = state
        self.onToggle = onToggle
        self.onChooseDevice = onChooseDevice
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.display.spotifyLine)
                    .font(.headline)
                Text(state.display.routeLine)
                    .foregroundStyle(.secondary)
            }

            if let problem = state.display.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Send Spotify to")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if state.display.devices.isEmpty {
                Text("No output devices found.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.display.devices) { row in
                        DeviceRowView(row: row, isBusy: state.display.isBusy) { onChooseDevice(row.uid) }
                    }
                }
            }

            Divider()

            Button(state.display.toggleTitle, action: onToggle)
                .disabled(!state.display.toggleEnabled)
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 320, alignment: .topLeading)
    }
}

private struct DeviceRowView: View {
    let row: DeviceRow
    let isBusy: Bool
    let choose: () -> Void

    private var isEnabled: Bool { row.isSelectable && !isBusy }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Image(systemName: row.isChosenDestination ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.isChosenDestination ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(row.name)
                if row.isSystemDefault {
                    Text("system default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
        .help(row.isSelectable
              ? "Send Spotify to \(row.name)"
              : "\(row.name) is your system default — routing it to itself only adds latency")
    }
}
