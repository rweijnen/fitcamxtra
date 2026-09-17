import SwiftUI

struct ConnectView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var manualExpanded = false
    @State private var manualAddress = ""
    @State private var manualFailed = false
    @State private var isTesting = false
    @State private var showForgetConfirm = false

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    Text("Find your camera")
                        .font(Typo.sans(30, .semibold))
                        .tracking(-0.9)
                        .foregroundStyle(Palette.ink)

                    Text("Looking on your wifi and for the camera's own network.")
                        .font(Typo.sans(14))
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let status = state.discoveryStatus {
                        Text(status)
                            .font(Typo.mono(11))
                            .foregroundStyle(Palette.inkQuaternary)
                    }

                    if let camera = state.connection.camera {
                        foundOnLAN(camera)
                    }

                    apCard

                    manualEntry

                    Text("Matching names that start with \(state.remembered.ssidPrefix). Joining the AP needs the local-network and hotspot prompts iOS shows once.")
                        .font(Typo.mono(10.5))
                        .foregroundStyle(Palette.inkQuaternary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

                    footer
                }
                .padding(.horizontal, Metrics.overlayGutter)
                .padding(.bottom, 40)
            }
        }
    }

    private var header: some View {
        HStack {
            Eyebrow(text: "Discovery", tracking: 1.4)
            Spacer()
            Button("Close") { dismiss() }
                .font(Typo.sans(13.5, .semibold))
                .foregroundStyle(Palette.accent)
        }
        .padding(.top, 20)
    }

    private func foundOnLAN(_ camera: DiscoveredCamera) -> some View {
        Button {
            Task {
                await state.connect(to: camera)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Circle().fill(Palette.accent).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(camera.model ?? state.remembered.name)
                        .font(Typo.sans(15, .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("STATION - \(camera.host)")
                        .font(Typo.mono(11))
                        .foregroundStyle(Palette.inkQuaternary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.inkQuaternary)
            }
            .padding(14)
            .cardSurface(border: Palette.accent.opacity(0.45))
        }
        .buttonStyle(.plain)
    }

    private var apCard: some View {
        // Joining the camera's own AP needs NEHotspotConfiguration, which needs
        // the Hotspot Configuration capability on the App ID. Disabled until
        // that entitlement is provisioned.
        HStack(spacing: 12) {
            Circle().fill(Palette.inkQuaternary).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(state.remembered.ssidPrefix)DW")
                    .font(Typo.sans(15, .semibold))
                    .foregroundStyle(Palette.ink)
                Text("AP - JOIN THIS NETWORK")
                    .font(Typo.mono(11))
                    .foregroundStyle(Palette.inkQuaternary)
            }
            Spacer()
            Text("SOON")
                .font(Typo.mono(9.5, .bold))
                .foregroundStyle(Palette.inkFaint)
        }
        .padding(14)
        .cardSurface()
        .opacity(0.55)
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { manualExpanded.toggle() }
            } label: {
                HStack {
                    Text("Enter an address manually")
                        .font(Typo.sans(14))
                        .foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Image(systemName: manualExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.inkQuaternary)
                }
                .padding(14)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Palette.hairline)
                )
            }
            .buttonStyle(.plain)

            if manualExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "IP address")

                    TextField("192.168.2.41", text: $manualAddress)
                        .font(Typo.mono(16))
                        .foregroundStyle(Palette.ink)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )

                    if manualFailed {
                        Text("Nothing answered at that address.")
                            .font(Typo.mono(10.5))
                            .foregroundStyle(Palette.destructiveText)
                    }

                    Button {
                        Task { await testAndSave() }
                    } label: {
                        Text(isTesting ? "Testing..." : "Test and save")
                            .font(Typo.sans(15, .semibold))
                            .foregroundStyle(Palette.accentInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                                    .fill(Palette.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting || IPv4Address(manualAddress) == nil)

                    Text("Give the camera a reserved lease in your router so this address stays valid. The app remembers it and tries it first on every launch.")
                        .font(Typo.mono(10.5))
                        .foregroundStyle(Palette.inkQuaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !state.remembered.autoConnectEnabled {
                Text("Forgotten. The app will not look for this camera until you scan again.")
                    .font(Typo.mono(10.5))
                    .foregroundStyle(Palette.accentText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(state.isSearching ? "Searching..." : "Scan again") {
                    state.rescan()
                }
                .font(Typo.sans(13.5, .semibold))
                .foregroundStyle(Palette.accent)
                .disabled(state.isSearching)

                Spacer()

                Button("Forget this camera") {
                    showForgetConfirm = true
                }
                .font(Typo.sans(13.5, .semibold))
                .foregroundStyle(Palette.destructiveText)
            }
        }
        .padding(.top, 6)
        .confirmationDialog(
            "Forget this camera?",
            isPresented: $showForgetConfirm,
            titleVisibility: .visible
        ) {
            Button("Forget this camera", role: .destructive) {
                state.forgetCamera()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app stops looking for it and forgets its address. Nothing on the camera changes.")
        }
    }

    private func testAndSave() async {
        isTesting = true
        manualFailed = false
        let ok = await state.probeManual(host: manualAddress)
        isTesting = false
        if ok {
            dismiss()
        } else {
            manualFailed = true
        }
    }
}
