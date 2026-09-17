import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        ZStack(alignment: .bottom) {
            Palette.bg.ignoresSafeArea()

            Group {
                switch state.tab {
                case .live: LiveView()
                case .events: EventsView()
                case .files: SDCardView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsTabBar {
                TabBar(selection: $state.tab, unreadCount: state.unreadCount)
                    .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $state.isConnectSheetPresented) {
            ConnectView()
        }
    }

    /// Immersive Live hides the bar, as do the pushed overlays.
    private var showsTabBar: Bool {
        !(state.tab == .live && state.isImmersive)
    }
}

struct TabBar: View {
    @Binding var selection: AppTab
    var unreadCount: Int

    var body: some View {
        HStack(spacing: 0) {
            item(.live, "LIVE", symbol: "dot.radiowaves.left.and.right")
            item(.events, "EVENTS", symbol: "square.stack", badge: unreadCount)
            item(.files, "SD CARD", symbol: "sdcard")
            item(.settings, "SETTINGS", symbol: "gearshape")
        }
        .padding(.top, 14)
        .padding(.horizontal, 10)
        .padding(.bottom, 28)
        .background(Palette.bg.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
        }
    }

    private func item(_ tab: AppTab, _ label: String, symbol: String, badge: Int = 0) -> some View {
        let isActive = selection == tab

        return Button {
            selection = tab
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: isActive ? .semibold : .regular))

                // The badge is an inline sibling of the label, never absolutely
                // positioned: absolute placement drew it over the next tab.
                HStack(spacing: 4) {
                    Text(label)
                        .font(Typo.mono(11.5, .semibold))
                        .tracking(0.92)
                    if badge > 0 {
                        Text("\(badge)")
                            .font(Typo.mono(9.5, .bold))
                            .foregroundStyle(Palette.accentInk)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.Radius.badge, style: .continuous)
                                    .fill(Palette.accent)
                            )
                    }
                }
            }
            .foregroundStyle(isActive ? Palette.accent : Palette.inkTertiary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
