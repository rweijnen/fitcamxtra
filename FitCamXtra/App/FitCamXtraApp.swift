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
            if phase == .active {
                state.onForeground()
            }
        }
    }
}
