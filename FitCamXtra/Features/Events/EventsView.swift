import SwiftUI

struct EventsView: View {
    @Environment(AppState.self) private var state
    @State private var openEvent: CameraEvent?

    private var library: MediaLibrary { state.library }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Events")
                        .font(Typo.sans(.screenTitle, .semibold))
                        .tracking(-0.9)
                        .foregroundStyle(Palette.ink)

                    Text(subtitle)
                        .font(Typo.sans(.label))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .padding(.top, Metrics.headerTop)

                Button {
                    state.tab = .files
                } label: {
                    HStack {
                        Text("Wasn't it locked? Browse the whole card")
                            .font(Typo.sans(.body))
                            .foregroundStyle(Palette.inkSecondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.inkQuaternary)
                    }
                    .padding(13)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                            .strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                if library.isLoadingEvents && library.events.isEmpty {
                    loading
                } else if let problem = library.lastError, library.events.isEmpty {
                    // Not "no locked clips" — we do not know that.
                    EmptyStateCard(
                        eyebrow: "Event list",
                        headline: "Could not read the card",
                        detail: "\(problem)\n\nThe locked clips are still on the camera. Pull down to try again."
                    )
                } else if library.events.isEmpty {
                    EmptyStateCard(
                        eyebrow: "Event list",
                        headline: state.connection.isConnected
                            ? "No locked clips on the card"
                            : "Connect to pull the event list",
                        detail: state.connection.isConnected
                            ? "Press the button on the camera, or let the G-sensor fire, and the clip it protects appears here."
                            : "Events come from the camera's locked-clip list, so the app has to be connected to read them."
                    )
                } else {
                    ForEach(library.events) { event in
                        Button {
                            openEvent = event
                        } label: {
                            EventCard(
                                event: event,
                                isUnread: library.unreadEventIDs.contains(event.id),
                                downloader: state.downloader
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Older events are on the card until overwritten")
                    .font(Typo.mono(.detail))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.scrollBottom)
        }
        .background(Palette.bg)
        .refreshable {
            await library.loadEvents(lastSeenID: state.remembered.lastSeenEventID,
                                     lastSeenAt: state.remembered.lastSeenEventAt)
        }
        .onAppear { state.markEventsSeen() }
        .fullScreenCover(item: $openEvent) { event in
            IncidentView(event: event)
        }
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Palette.accent)
            Text("Reading the card")
                .font(Typo.mono(.detail))
                .foregroundStyle(Palette.inkQuaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var subtitle: String {
        guard !library.events.isEmpty else {
            return state.connection.isConnected ? "Nothing locked yet" : "Not connected"
        }
        let locked = library.events.count
        let new = library.unreadEventIDs.count
        let clips = locked == 1 ? "1 locked clip" : "\(locked) locked clips"
        return new > 0 ? "\(clips) - \(new) new since last connect" : clips
    }
}

struct EventCard: View {
    let event: CameraEvent
    let isUnread: Bool
    let downloader: MediaDownloader

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        CameraPlaceholder()
                    }
                }
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("LOCKED")
                            .font(Typo.mono(.micro))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .glass()

                    if isUnread {
                        Text("NEW")
                            .font(Typo.mono(.micro, .bold))
                            .foregroundStyle(Palette.accentInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.Radius.badge, style: .continuous)
                                    .fill(Palette.accent)
                            )
                    }
                }
                .padding(10)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(Typo.sans(.cardTitle, .semibold))
                        .foregroundStyle(Palette.ink)
                    // The title is the time now, so the second line carries
                    // what the clip is instead of repeating it.
                    Text(event.durationLabel ?? event.triggerLabel)
                        .font(Typo.sans(.label))
                        .foregroundStyle(Palette.inkQuaternary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.inkQuaternary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
        }
        .cardSurface()
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .task {
            thumbnail = await downloader.thumbnail(for: MediaFile(
                id: event.id,
                path: event.path,
                cameraPath: event.cameraPath,
                recordedAt: event.recordedAt,
                byteCount: 0,
                kind: .video,
                isLocked: true
            ))
        }
    }
}

/// Honest empty state: says what is missing rather than showing invented content.
struct EmptyStateCard: View {
    let eyebrow: String
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: eyebrow)
            Text(headline)
                .font(Typo.sans(.sectionTitle, .semibold))
                .foregroundStyle(Palette.ink)
            Text(detail)
                .font(Typo.sans(.body))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }
}
