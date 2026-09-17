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

                    Text("Looking on the wifi your phone is joined to, whether that is your home network or the camera's own.")
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
                    } else if !state.isSearching {
                        apInstructions
                    }

                    manualEntry

                    Text("The first connection asks for local network permission. Refusing it means the app can never find the camera.")
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
                    Text(state.cameraName ?? camera.host)
                        .font(Typo.sans(15, .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("\(state.networkMode.label) - \(camera.host)")
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

    /// How to reach a camera running its own access point.
    ///
    /// iOS never lets an app list the wifi networks in range, so there is no
    /// honest way to show one as "found". Even with the Hotspot Configuration
    /// entitlement an app can only ask to join a name it already knows. Until
    /// that entitlement exists this says what to do instead of implying the
    /// app found something.
    private var apInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "On the camera's own wifi")

            Text("Join it in iOS Settings")
                .font(Typo.sans(15, .semibold))
                .foregroundStyle(Palette.ink)

            Text("Open Settings, then Wi-Fi, and pick the network starting with \(state.remembered.ssidPrefix). Come back here and the app finds the camera by itself. Your phone has no internet while on the camera's wifi, which is expected.")
                .font(Typo.sans(13))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Joining it from inside the app needs an Apple entitlement this build does not carry yet.")
                .font(Typo.mono(10.5))
                .foregroundStyle(Palette.inkQuaternary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface()
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

                if state.hasRememberedCamera {
                    Button("Forget this camera") {
                        showForgetConfirm = true
                    }
                    .font(Typo.sans(13.5, .semibold))
                    .foregroundStyle(Palette.destructiveText)
                }
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
