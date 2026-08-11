import SwiftUI

/// Working name only. Not final — never hardcode it in user-facing strings.
enum AppNaming {
    static let displayName = String(localized: "Video Overlap", comment: "Working name of the app")
}

@main
struct SendSocietyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            SessionListView()
        }
    }
}
