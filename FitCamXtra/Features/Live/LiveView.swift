import SwiftUI

struct LiveView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            feed
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.18)) {
                        state.isImmersive.toggle()
                    }
                }

            if state.connection.isConnected && !state.isImmersive {
                chrome
            }

            if !state.connection.isConnected {
                disconnectedCover
            }

            if state.snapshotToastVisible {
                snapshotToast
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
        .task(id: state.connection.camera?.host) {
            if let host = state.connection.camera?.host {
                state.liveStream.start(host: host, camera: state.cameraClient())
            } else {
                state.liveStream.stop()
            }
        }
        .onDisappear {
            // Nothing to watch while another tab is open, and the camera has
            // little spare capacity, so give the stream back.
            state.liveStream.stop()
        }
    }

    // MARK: - Feed

    @ViewBuilder
    private var feed: some View {
        ZStack {
            Color.black

            if state.connection.isConnected {
                VideoLayerView(renderer: state.liveStream.renderer)
                    .opacity(state.liveStream.status.isPlaying ? 1 : 0)
            }

            switch state.liveStream.status {
            case .connecting:
                overlayMessage("Starting the live stream")
            case .failed(let reason):
                overlayMessage("Live view unavailable", detail: reason)
            case .playing where state.liveStream.framesRendered == 0:
                overlayMessage("Waiting for the first frame")
            default:
                EmptyView()
            }
        }
    }

    private func overlayMessage(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 6) {
            Eyebrow(text: "Live", color: Palette.inkFaint)
            Text(title)
                .font(Typo.sans(.cardTitle, .semibold))
                .foregroundStyle(Palette.ink)
            if let detail {
                Text(detail)
                    .font(Typo.mono(.detail))
                    .foregroundStyle(Palette.inkQuaternary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 34)
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                recordChip
                Spacer(minLength: 12)
                statusChips
            }
            .padding(.horizontal, 16)
            .padding(.top, Metrics.headerTop)

            Spacer()

            VStack(spacing: 8) {
                controlBar
                Text("live audio muted - tap image for full frame")
                    .font(Typo.mono(.micro))
                    .foregroundStyle(Palette.onVideoCaption)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    private var recordChip: some View {
        HStack(spacing: 6) {
            if state.isRecording {
                Circle()
                    .fill(Palette.record)
                    .frame(width: 7, height: 7)
            }
            Text(state.isRecording ? "REC \(state.elapsedLabel)" : "STANDBY")
                .font(Typo.mono(.detail, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .tracking(0.46)
                .foregroundStyle(state.isRecording ? .white : Color.white.opacity(0.72))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glass()
    }

    /// Why nothing is on screen. After a Forget the app is deliberately not
    /// looking, and saying so beats leaving someone to wonder why opening the
    /// app does nothing.
    private var disconnectedExplanation: String {
        if state.isSearching {
            return "Join the camera's wifi and this will find it by itself."
        }
        if !state.remembered.autoConnectEnabled {
            return "You forgot this camera, so the app is not looking for it. Connect to look again."
        }
        return "The camera records to its card regardless. Reconnect to watch live, pull events, or change settings."
    }

    private var statusChips: some View {
        HStack(spacing: 6) {
            Button {
                state.isConnectSheetPresented = true
            } label: {
                chip(state.networkMode.label, color: Palette.accentText)
            }
            .buttonStyle(.plain)

            // No percentage chips: the camera answers these with codes whose
            // scale is unknown, so a percent sign here would be invented.
            // Card capacity is shown on the SD card screen, from the listing.
            if state.sdCardLooksUnhealthy {
                chip("SD?", color: Palette.destructiveText)
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typo.mono(.micro, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glass()
    }

    private var controlBar: some View {
        HStack {
            // Snapshot
            Button {
                Task { await state.takeSnapshot() }
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)

            Spacer()

            // Record
            Button {
                Task { await state.toggleRecording() }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 3)
                        .frame(width: 66, height: 66)
                    if state.isRecording {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Palette.record)
                            .frame(width: 24, height: 24)
                    } else {
                        Circle()
                            .fill(Palette.record)
                            .frame(width: 50, height: 50)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // No Events shortcut here: the tab bar sits directly below this
            // row and already goes there, with the same unread badge. The
            // hazard-stripe placeholder it used as an icon also read as a
            // picture that had failed to load.
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glass(radius: Metrics.Radius.bar)
    }

    // MARK: - States

    private var snapshotToast: some View {
        VStack {
            Spacer()
            Text(state.snapshotMessage)
                .font(Typo.sans(.body, .semibold))
                .foregroundStyle(Palette.accentInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(Palette.accent.opacity(0.92))
                )
                .padding(.bottom, 16)
        }
        .transition(.opacity)
    }

    private var disconnectedCover: some View {
        ZStack {
            Palette.bg.opacity(0.88).ignoresSafeArea()

            VStack(spacing: 12) {
                Eyebrow(text: "No camera", color: Palette.destructiveText, tracking: 1.32)

                Text(state.isSearching ? "Looking for the camera" : "Not connected to the camera")
                    .font(Typo.sans(.sectionTitle, .semibold))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)

                Text(disconnectedExplanation)
                    .font(Typo.sans(.body))
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let status = state.discoveryStatus {
                    Text(status)
                        .font(Typo.mono(.detail))
                        .foregroundStyle(Palette.inkQuaternary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }

                Button {
                    state.isConnectSheetPresented = true
                } label: {
                    Text("Connect")
                        .font(Typo.sans(.cardTitle, .semibold))
                        .foregroundStyle(Palette.accentInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                                .fill(Palette.accent)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, 34)
        }
    }
}
