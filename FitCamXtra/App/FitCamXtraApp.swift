import SwiftUI

@main
struct FitCamXtraApp: App {
    @State private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .preferredColorScheme(.dark)
                .task {
                    state.tab = state.landingTab()
                    state.startAutoConnect()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Joining the camera's access point happens in Settings, so the
            // app is usually backgrounded at the moment the network changes.
            switch phase {
            case .active:
                state.onForeground()
            case .background:
                // iOS suspends the app here, and a search caught mid-sweep
                // neither finishes nor ends. End it so the app returns ready
                // to look on whatever network the phone is now on.
                state.onBackground()
            default:
                break
            }
        }
    }
}
