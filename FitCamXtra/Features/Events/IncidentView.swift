import AVKit
import SwiftUI

/// One incident, treated as a bundle rather than a single file. Loop recording
/// writes roughly one-minute chunks and the button only locks the chunk it
/// landed in, so the start or the aftermath usually sits in a neighbour.
struct IncidentView: View {
    let event: CameraEvent

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var range: IncidentBundle.Range = .plusMinusOne
    @State private var saveState: SaveState = .idle
    @State private var player: AVPlayer?

    private enum SaveState: Equatable {
        case idle
        case saving(Double)
        case saved
        case failed(String)
    }

    private var bundle: IncidentBundle {
        state.library.bundle(for: event, range: range)
    }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                playerArea

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        segmentsStrip
                        rangeSelector
                        explainer
                        saveButton
                        secondaryActions
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear(perform: preparePlayer)
        .onDisappear { player?.pause() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(Typo.sans(15, .semibold))
                    .foregroundStyle(Palette.ink)
                Text("incident bundle - \(bundle.segments.count) segment\(bundle.segments.count == 1 ? "" : "s")")
                    .font(Typo.mono(11.5))
                    .foregroundStyle(Palette.inkQuaternary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Player

    private var playerArea: some View {
        ZStack {
            Color.black

            if let player {
                VideoPlayer(player: player)
            } else {
                VStack(spacing: 4) {
                    CameraPlaceholder(
                        caption: "locked segment \(event.timeLabel)",
                        subcaption: "audio on"
                    )
                }
            }
        }
        .frame(height: 238)
        .clipped()
    }

    /// Plays straight from the camera. Nothing is downloaded until you save,
    /// and audio is on here because this is review rather than monitoring.
    private func preparePlayer() {
        guard let host = state.connection.camera?.host else { return }
        let escaped = event.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.path
        guard let url = URL(string: "http://\(host)\(escaped)") else { return }
        player = AVPlayer(url: url)
    }

    // MARK: - Segments

    private var segmentsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Segments")

            HStack(spacing: 7) {
                ForEach(bundle.segments) { segment in
                    VStack(spacing: 0) {
                        ZStack {
                            CameraPlaceholder()
                                .frame(height: 52)
                            if segment.role == .locked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                        VStack(spacing: 2) {
                            Text(segment.startedAt?.formatted(date: .omitted, time: .shortened) ?? "--:--")
                                .font(Typo.mono(10.5))
                                .foregroundStyle(segment.role == .locked ? Palette.accent : Palette.inkSecondary)
                            Text(segment.role.label)
                                .font(Typo.mono(9.5))
                                .foregroundStyle(Palette.inkQuaternary)
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                            .strokeBorder(
                                segment.role == .locked ? Palette.accent : Color.white.opacity(0.1),
                                lineWidth: 2
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous))
                }
            }

            if bundle.segments.count == 1 && range != .lockedOnly {
                Text(event.recordedAt == nil
                     ? "The camera reported no timestamp for this clip, so neighbouring clips cannot be identified. Browse the card to find them by hand."
                     : "No neighbouring clips were found on the card. They may already have been overwritten by the loop.")
                    .font(Typo.mono(10.5))
                    .foregroundStyle(Palette.accentText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rangeSelector: some View {
        HStack(spacing: 6) {
            ForEach(IncidentBundle.Range.allCases, id: \.rawValue) { option in
                let active = range == option
                Button {
                    range = option
                } label: {
                    Text(option.label)
                        .font(Typo.sans(13))
                        .foregroundStyle(active ? Palette.accent : Palette.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                                .fill(active ? Palette.accent.opacity(0.16) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                                .strokeBorder(active ? Palette.accent.opacity(0.5) : Palette.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var explainer: some View {
        Text("Loop recording writes roughly one-minute chunks, so the start or aftermath of the moment you locked often sits in a neighbour.")
            .font(Typo.sans(12))
            .foregroundStyle(Palette.inkQuaternary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Saving

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Group {
                switch saveState {
                case .idle:
                    Text("Save incident to Photos")
                case .saving(let fraction):
                    Text("Saving \(Int(fraction * 100))%")
                case .saved:
                    Text("Saved to Photos")
                case .failed:
                    Text("Try saving again")
                }
            }
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
        .disabled(isSaving)
        .opacity(isSaving ? 0.7 : 1)
    }

    private var isSaving: Bool {
        if case .saving = saveState { return true }
        return false
    }

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let reason) = saveState {
                Text(reason)
                    .font(Typo.mono(11))
                    .foregroundStyle(Palette.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Saving copies the clips to your phone's album over wifi. The originals stay on the card until the loop overwrites them.")
                .font(Typo.mono(10.5))
                .foregroundStyle(Palette.inkQuaternary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() async {
        saveState = .saving(0)
        do {
            try await state.downloader.saveIncident(bundle) { fraction in
                saveState = .saving(fraction)
            }
            saveState = .saved
            try? await Task.sleep(for: .seconds(1.8))
            if saveState == .saved { saveState = .idle }
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }
}
