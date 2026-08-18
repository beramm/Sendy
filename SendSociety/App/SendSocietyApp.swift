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
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var completedOnboardingThisLaunch = false

    var body: some View {
        Group {
            if shouldShowOnboarding {
                OnboardingFlowView {
                    hasCompletedOnboarding = true
                    completedOnboardingThisLaunch = true
                }
                .transition(.opacity)
            } else {
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
        .animation(.easeInOut(duration: 0.35), value: shouldShowOnboarding)
    }

    private var shouldShowOnboarding: Bool {
        guard !completedOnboardingThisLaunch else { return false }
        return OnboardingConfiguration.alwaysShowOnLaunch || !hasCompletedOnboarding
    }
}
