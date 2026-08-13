import SwiftUI

/// Working name only. Not final — never hardcode it in user-facing strings.
/// Must stay in step with `INFOPLIST_KEY_CFBundleDisplayName`, which is what
/// the home screen shows; this is the name used inside the app.
enum AppNaming {
    static let displayName = String(localized: "Sendyy", comment: "Working name of the app")
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
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            SessionListView()
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .setup: SessionSetupView()
                    case .results: ResultsView()
                    case .report: PipelineReportView()
                    case .tuning: TuningPanelView()
                    }
                }
        }
    }
}
