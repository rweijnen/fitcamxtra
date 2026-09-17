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
                        if let offer = state.widerScanOffer {
                            widerScanCard(offer)
                        }
                        rememberedCard
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
        .task {
            state.searchBecauseConnectOpened()
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

    /// Offered only when the phone's network is genuinely wider than the
    /// range already swept. A /16 is tens of thousands of probes, so the app
    /// asks rather than deciding to spend minutes on it.
    private func widerScanCard(_ offer: DiscoveryOutcome.WiderScan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Wider network", color: Palette.accentText)

            Text("Your network is bigger than the part just searched")
                .font(Typo.sans(15, .semibold))
                .foregroundStyle(Palette.ink)

            Text("The phone is on \(offer.network), which is \(offer.addressCount) addresses. Only the 254 around the phone were searched. Searching all of it takes roughly \(durationLabel(offer.estimatedSeconds)).")
                .font(Typo.sans(13))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                state.scanWiderNetwork()
            } label: {
                Text("Search the whole network")
                    .font(Typo.sans(14, .semibold))
                    .foregroundStyle(Palette.accentInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                            .fill(Palette.accent)
                    )
            }
            .buttonStyle(.plain)

            Text("If you already know the camera's address, entering it below is instant.")
                .font(Typo.mono(10.5))
                .foregroundStyle(Palette.inkQuaternary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(border: Palette.accent.opacity(0.45))
    }

    private func durationLabel(_ seconds: Int) -> String {
        if seconds < 90 { return "\(seconds) seconds" }
        return "\(Int((Double(seconds) / 60).rounded())) minutes"
    }

    /// What the app is holding on to, so Forget names something real instead
    /// of offering to forget a camera the screen never mentions.
    @ViewBuilder
    private var rememberedCard: some View {
        if state.hasRememberedCamera {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Remembered")

                Text(state.cameraName ?? "A camera you have connected to")
                    .font(Typo.sans(15, .semibold))
                    .foregroundStyle(Palette.ink)

                Text(state.remembered.lastHost.map { "Last answered at \($0). Not on this network now." }
                     ?? "No address kept; the app searches for it.")
                    .font(Typo.mono(11))
                    .foregroundStyle(Palette.inkQuaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .cardSurface()
        }
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
                    Button(state.cameraName.map { "Forget \($0)" } ?? "Forget this camera") {
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
            Text(state.cameraName.map {
                "The app stops looking for \($0) and forgets its name and address. Nothing on the camera changes."
            } ?? "The app stops looking for it and forgets its address. Nothing on the camera changes.")
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
