import SwiftUI

struct SDCardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("SD card")
                    .font(Typo.sans(30, .semibold))
                    .tracking(-0.9)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Metrics.headerTop)

                if let used = state.sdCardPercentUsed {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "Storage")
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.ink.opacity(0.14))
                                Capsule()
                                    .fill(Palette.ink.opacity(0.55))
                                    .frame(width: geometry.size.width * CGFloat(used) / 100)
                            }
                        }
                        .frame(height: 5)

                        Text("\(used)% USED")
                            .font(Typo.mono(11))
                            .foregroundStyle(Palette.inkQuaternary)
                    }
                    .padding(16)
                    .cardSurface()
                }

                NotBuiltYet(
                    eyebrow: "File browser",
                    headline: "The card browser is not built yet",
                    detail: "Planned: date-grouped grid, filter chips for video, photos and locked, multi-select with save to Photos and delete, and a file detail view. The file list and thumbnail commands are already mapped."
                )
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.scrollBottom)
        }
        .background(Palette.bg)
    }
}
