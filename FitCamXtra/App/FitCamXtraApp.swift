import SwiftUI

@main
struct FitCamXtraApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .preferredColorScheme(.dark)
                .task {
                    state.tab = state.landingTab()
                    await state.discover()
                }
        }
    }
}
