import AVKit
import SwiftUI

struct FileDetailView: View {
    let file: MediaFile

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var saveLabel = "Save to Photos"
    @State private var isBusy = false
    @State private var failure: String?
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                preview
                    .frame(height: 258)
                    .frame(maxWidth: .infinity)
                    .clipped()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        meta
                        saveButton
                        actions

                        if let failure {
                            Text(failure)
                                .font(Typo.mono(.detail))
                                .foregroundStyle(Palette.destructiveText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("Saving copies the file to your phone's album over wifi. The original stays on the card until the loop overwrites it.")
                            .font(Typo.mono(.micro))
                            .foregroundStyle(Palette.inkQuaternary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Metrics.overlayGutter)
                    .padding(.top, 16)
                    .padding(.bottom, 30)
                }
            }
        }
        .task { await load() }
        .onDisappear { player?.pause() }
        .confirmationDialog(
            "Delete this file?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await delete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(file.isLocked
                 ? "This clip is locked, so the loop would otherwise keep it. Deleting cannot be undone."
                 : "Deleting cannot be undone.")
        }
    }

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
                Text(file.recordedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Date not reported")
                    .font(Typo.sans(.cardTitle, .semibold))
                    .foregroundStyle(Palette.ink)
                Text(file.displayName)
                    .font(Typo.mono(.detail))
                    .foregroundStyle(Palette.inkQuaternary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                CameraPlaceholder(caption: file.kind == .photo ? "PHOTO" : "CLIP")
            }

            if file.isLocked {
                VStack {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("LOCKED").font(Typo.mono(.micro))
                        }
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glass()
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    private var meta: some View {
        HStack(spacing: 8) {
            Text(file.kind == .photo ? "PHOTO" : "VIDEO")
                .font(Typo.mono(.micro, .semibold))
                .foregroundStyle(Palette.accentText)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.badge, style: .continuous)
                        .fill(Palette.accent.opacity(0.16))
                )

            Text(metaLine)
                .font(Typo.mono(.detail))
                .foregroundStyle(Palette.inkQuaternary)
            Spacer()
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let duration = file.durationLabel { parts.append(duration) }
        if file.byteCount > 0 { parts.append(file.sizeLabel) }
        return parts.isEmpty ? "size unknown" : parts.joined(separator: " - ")
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Text(saveLabel)
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
        .disabled(isBusy)
        .opacity(isBusy ? 0.7 : 1)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                showDeleteConfirm = true
            } label: {
                Text("Delete")
                    .font(Typo.sans(.body, .semibold))
                    .foregroundStyle(Palette.destructiveText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                            .fill(Palette.destructiveBg)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    private func load() async {
        guard let host = state.connection.camera?.host else { return }
        let escaped = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        guard let url = URL(string: "http://\(host)\(escaped)") else { return }

        if file.kind == .video {
            player = AVPlayer(url: url)
        } else {
            image = await state.downloader.thumbnail(for: file)
        }
    }

    private func save() async {
        isBusy = true
        failure = nil
        saveLabel = "Saving..."
        do {
            try await state.downloader.saveToPhotos(file)
            saveLabel = "Saved to Photos"
            try? await Task.sleep(for: .seconds(1.8))
            saveLabel = "Save to Photos"
        } catch {
            failure = error.localizedDescription
            saveLabel = "Save to Photos"
        }
        isBusy = false
    }

    private func delete() async {
        isBusy = true
        failure = nil
        do {
            try await state.downloader.delete(file, client: state.cameraClient())
            await state.library.loadFiles()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        isBusy = false
    }
}
