import SwiftUI

/// Shows what the app actually did. Read it on the phone, or share the text
/// out when something needs explaining.
struct DiagnosticsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var showDetail = false
    @State private var minimumLevel: LogLevel = .debug

    /// Newest first, because the last thing that happened is the thing you
    /// opened this screen to read.
    private var entries: [LogEntry] {
        Array(state.diagnostics.entries.filter { $0.level >= minimumLevel }.reversed())
    }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                filterBar

                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Eyebrow(text: "Nothing logged")
                        Text("Nothing has been recorded at this level yet.")
                            .font(Typo.sans(13.5))
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                row(entry)
                                Rectangle()
                                    .fill(Palette.divider)
                                    .frame(height: 1)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
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

            ShareLink(item: state.diagnostics.exportText()) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }

            Button {
                state.diagnostics.clear()
            } label: {
                Text("Clear")
                    .font(Typo.sans(13.5, .semibold))
                    .foregroundStyle(Palette.destructiveText)
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach([LogLevel.debug, .info, .warning, .error], id: \.rawValue) { level in
                let active = minimumLevel == level
                Button {
                    minimumLevel = level
                } label: {
                    Text(level == .debug ? "ALL" : level.label)
                        .font(Typo.mono(10.5, .semibold))
                        .foregroundStyle(active ? Palette.accent : Palette.inkQuaternary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
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

            Spacer()

            Toggle(isOn: $showDetail) {
                Text("Detail")
                    .font(Typo.mono(10.5, .semibold))
                    .foregroundStyle(Palette.inkQuaternary)
            }
            .toggleStyle(.switch)
            .tint(Palette.accent)
            .fixedSize()
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 10)
    }

    private func row(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.at.formatted(.dateTime.hour().minute().second()))
                    .font(Typo.mono(10))
                    .foregroundStyle(Palette.inkFaint)

                Text(entry.category.rawValue)
                    .font(Typo.mono(9.5, .semibold))
                    .foregroundStyle(Palette.inkFaint)

                Spacer(minLength: 0)

                if entry.level > .info {
                    Text(entry.level.label)
                        .font(Typo.mono(9.5, .bold))
                        .foregroundStyle(colour(for: entry.level))
                }
            }

            Text(entry.message)
                .font(Typo.mono(11.5))
                .foregroundStyle(colour(for: entry.level))
                .fixedSize(horizontal: false, vertical: true)

            if showDetail, let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(Typo.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 9)
    }

    private func colour(for level: LogLevel) -> Color {
        switch level {
        case .debug: return Palette.inkQuaternary
        case .info: return Palette.ink
        case .warning: return Palette.accentText
        case .error: return Palette.destructiveText
        }
    }
}
