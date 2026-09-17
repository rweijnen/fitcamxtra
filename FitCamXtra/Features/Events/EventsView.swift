import SwiftUI

struct EventsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Events")
                        .font(Typo.sans(30, .semibold))
                        .tracking(-0.9)
                        .foregroundStyle(Palette.ink)

                    Text(subtitle)
                        .font(Typo.sans(13))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .padding(.top, Metrics.headerTop)

                Button {
                    state.tab = .files
                } label: {
                    HStack {
                        Text("Wasn't it locked? Browse the whole card")
                            .font(Typo.sans(14))
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

                if state.events.isEmpty {
                    NotBuiltYet(
                        eyebrow: "Event list",
                        headline: state.connection.isConnected
                            ? "No locked clips on the card"
                            : "Connect to pull the event list",
                        detail: "Events come from the camera's locked-clip list. The incident bundle view, which pulls the neighbouring loop segments, is the next screen to build."
                    )
                } else {
                    ForEach(state.events) { event in
                        EventCard(event: event, isUnread: state.unreadEventIDs.contains(event.id))
                    }
                }

                Text("Older events are on the card until overwritten")
                    .font(Typo.mono(11.5))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.scrollBottom)
        }
        .background(Palette.bg)
    }

    private var subtitle: String {
        let locked = state.events.count
        let new = state.unreadCount
        if locked == 0 { return "Nothing pulled yet" }
        return "\(locked) locked clips - \(new) new since last connect"
    }
}

struct EventCard: View {
    let event: CameraEvent
    let isUnread: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CameraPlaceholder()
                    .frame(height: 132)

                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("LOCKED")
                            .font(Typo.mono(10))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .glass()

                    if isUnread {
                        Text("NEW")
                            .font(Typo.mono(10, .bold))
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
                        .font(Typo.sans(15, .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(event.recordedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(Typo.sans(12))
                        .foregroundStyle(Palette.ink.opacity(0.45))
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
    }
}

/// Honest empty state for the screens still to be built. It says what is
/// missing rather than showing invented content.
struct NotBuiltYet: View {
    let eyebrow: String
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: eyebrow)
            Text(headline)
                .font(Typo.sans(19, .semibold))
                .foregroundStyle(Palette.ink)
            Text(detail)
                .font(Typo.sans(13.5))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }
}
