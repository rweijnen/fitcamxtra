import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(Typo.sans(30, .semibold))
                    .tracking(-0.9)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Metrics.headerTop)

                cameraCard

                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "General")
                    VStack(spacing: 0) {
                        row("Camera connection", value: state.connection.isConnected ? "Connected" : "Not connected") {
                            state.isConnectSheetPresented = true
                        }
                        divider
                        row("Network", value: state.networkMode.label, showChevron: true)
                        divider
                        row("Wi-Fi name", value: state.remembered.lastSSID ?? "Unknown")
                        divider
                        row("SSID prefix", value: state.remembered.ssidPrefix)
                    }
                    .cardSurface()
                }

                NotBuiltYet(
                    eyebrow: "Camera settings",
                    headline: "The settings groups are not wired up yet",
                    detail: "Planned: Video with the new record-bitrate slider, Advanced, Parking mode, and the destructive actions. Every row maps to a command in the firmware table, and the Network screen carries the AP to station flip."
                )
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.scrollBottom)
        }
        .background(Palette.bg)
    }

    private var cameraCard: some View {
        HStack(spacing: 12) {
            CameraPlaceholder()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(state.connection.camera?.model ?? state.remembered.name)
                    .font(Typo.sans(15, .semibold))
                    .foregroundStyle(Palette.ink)
                Text(metaLine)
                    .font(Typo.mono(11))
                    .foregroundStyle(Palette.inkQuaternary)
            }

            Spacer()
            DutchMark()
        }
        .padding(14)
        .cardSurface()
    }

    private var metaLine: String {
        var parts: [String] = []
        if let firmware = state.connection.camera?.firmware { parts.append("FW \(firmware)") }
        if let sd = state.sdCardPercentUsed { parts.append("SD \(sd)%") }
        if let battery = state.batteryPercent { parts.append("\(battery)%") }
        if let host = state.connection.camera?.host { parts.append(host) }
        return parts.isEmpty ? "Not connected" : parts.joined(separator: " - ")
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 1)
    }

    private func row(
        _ label: String,
        value: String,
        showChevron: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack {
                Text(label)
                    .font(Typo.sans(14.5, .medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(value)
                    .font(Typo.sans(13.5))
                    .foregroundStyle(Palette.inkQuaternary)
                if showChevron || action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.inkQuaternary)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}
