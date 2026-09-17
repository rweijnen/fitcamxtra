import SwiftUI

/// Switches the camera between running its own access point and joining your
/// home wifi. This is the feature the stock app does not have.
struct NetworkView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var mode: NetworkMode = .accessPoint
    @State private var homeSSID = ""
    @State private var passphrase = ""
    @State private var showFirmwareNote = false
    @State private var showAdvanced = false
    @State private var applied = false
    @State private var isApplying = false
    @State private var failure: String?

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    statusCard
                    modeCard

                    if showFirmwareNote {
                        firmwareNote
                    }

                    if mode == .station {
                        stationFields
                    } else {
                        apNote
                    }

                    if let failure {
                        Text(failure)
                            .font(Typo.mono(11))
                            .foregroundStyle(Palette.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    advanced
                }
                .padding(.horizontal, Metrics.overlayGutter)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            mode = state.networkMode
            homeSSID = state.remembered.homeSSID ?? ""
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Settings").font(Typo.sans(14))
                }
                .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, 20)
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(state.connection.isConnected ? Palette.accent : Palette.inkFaint)
                    .frame(width: 8, height: 8)
                Eyebrow(text: state.connection.isConnected ? "Connected" : "Not connected",
                        color: Palette.inkFaint)
            }

            statusRow("Mode", state.networkMode.label)
            statusRow("SSID", state.remembered.lastSSID ?? "unknown", mono: true)
            statusRow("Address", state.connection.camera?.host ?? "unknown", mono: true)
            if let firmware = state.connection.camera?.firmware {
                statusRow("Firmware", firmware, mono: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func statusRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Typo.sans(13.5))
                .foregroundStyle(Palette.inkQuaternary)
            Spacer(minLength: 16)
            Text(value)
                .font(mono ? Typo.mono(12.5) : Typo.sans(13.5))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Mode switch

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wi-Fi mode")
                        .font(Typo.sans(14.5, .medium))
                        .foregroundStyle(Palette.ink)
                    Text(modeHint)
                        .font(Typo.sans(11.5))
                        .foregroundStyle(Palette.inkQuaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    showFirmwareNote.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Palette.accentText)
                }
                .buttonStyle(.plain)

                Toggle("", isOn: Binding(
                    get: { mode == .station },
                    set: { newValue in
                        mode = newValue ? .station : .accessPoint
                        applied = false
                        failure = nil
                    }
                ))
                .labelsHidden()
                .tint(Palette.accent)
                .disabled(!state.connection.isConnected || isApplying)
            }

            Rectangle().fill(Palette.divider).frame(height: 1)

            HStack {
                Text("AP")
                    .font(Typo.mono(11, .medium))
                    .foregroundStyle(mode == .accessPoint ? Palette.accent : Palette.inkQuaternary)
                Spacer()
                Text("STATION")
                    .font(Typo.mono(11, .medium))
                    .foregroundStyle(mode == .station ? Palette.accent : Palette.inkQuaternary)
            }
        }
        .padding(15)
        .cardSurface()
    }

    private var modeHint: String {
        mode == .station
            ? "Station: the camera joins your home wifi, so your phone keeps internet and CarPlay."
            : "AP: the camera runs its own access point and your phone loses internet while connected."
    }

    private var firmwareNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "Modified firmware required", color: Palette.destructiveText, tracking: 0.9)
                Spacer()
                Button("Close") { showFirmwareNote = false }
                    .font(Typo.sans(12, .semibold))
                    .foregroundStyle(Palette.destructiveText)
            }

            Text("Stock firmware forgets station mode on every power cycle and the camera comes back up as its own access point. FitCamXtra re-applies the switch each time it reconnects, so day to day it works, but the camera is only truly on your wifi at boot with the patched firmware.")
                .font(Typo.sans(12.5))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Patching is at your own risk and may void warranty.")
                .font(Typo.sans(12.5, .semibold))
                .foregroundStyle(Palette.destructiveText)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                .fill(Palette.record.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                .strokeBorder(Palette.record.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Station

    private var stationFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Home SSID")
                TextField("Your wifi name", text: $homeSSID)
                    .font(Typo.mono(15))
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Passphrase")
                SecureField("Your wifi password", text: $passphrase)
                    .font(Typo.mono(15))
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }

            Text("The passphrase is sent straight to the camera and is not stored on the phone. After applying, the camera restarts its wifi and drops off this network, so rejoin your home wifi and the app will find it again.")
                .font(Typo.mono(10.5))
                .foregroundStyle(Palette.inkQuaternary)
                .fixedSize(horizontal: false, vertical: true)

            applyButton
        }
    }

    private var apNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phone joins the camera directly")
                .font(Typo.sans(14, .medium))
                .foregroundStyle(Palette.ink)
            Text("Reliable anywhere, but your phone loses internet while connected, and wireless CarPlay drops.")
                .font(Typo.sans(12.5))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if mode == .accessPoint && state.networkMode == .station {
                applyButton
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var applyButton: some View {
        Button {
            Task { await apply() }
        } label: {
            Text(applied ? "Applied, rediscovering" : (isApplying ? "Applying..." : "Apply and rejoin"))
                .font(Typo.sans(15, .semibold))
                .foregroundStyle(Palette.accentInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                        .fill(Palette.accent)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canApply)
        .opacity(canApply ? 1 : 0.45)
    }

    private var canApply: Bool {
        guard state.connection.isConnected, !isApplying else { return false }
        if mode == .station {
            return !homeSSID.isEmpty && !passphrase.isEmpty
        }
        return true
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced")
                        .font(Typo.sans(13.5))
                        .foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.inkQuaternary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("SSID prefix", state.remembered.ssidPrefix, mono: true)
                    statusRow("Reserved IP", "recommended", mono: true)
                    Text("Give the camera a fixed lease in your router. The app tries the remembered address first on every launch, so a stable address makes reconnecting instant.")
                        .font(Typo.mono(10.5))
                        .foregroundStyle(Palette.inkQuaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }
        }
    }

    private func apply() async {
        isApplying = true
        failure = nil
        defer { isApplying = false }

        let result = await state.applyNetworkMode(mode, ssid: homeSSID, passphrase: passphrase)
        switch result {
        case .success:
            applied = true
            passphrase = ""
            try? await Task.sleep(for: .seconds(1.8))
            applied = false
            dismiss()
        case .failure(let error):
            failure = error.localizedDescription
        }
    }
}
