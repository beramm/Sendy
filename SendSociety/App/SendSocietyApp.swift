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
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// Set once, when onboarding finishes, and never cleared by the app.
    ///
    /// `UserDefaults` lives in the app's container, so this survives relaunches
    /// and app updates and goes away only when the app is deleted — which is
    /// exactly "show it on first install and never again".
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Covers the gap between finishing onboarding and `@AppStorage` publishing
    /// the write, and keeps `--show-onboarding` from looping straight back into
    /// the flow it just finished.
    @State private var completedOnboardingThisLaunch = false
    /// Cleared by `SplashView` once it has had its beat. Not persisted: the
    /// splash belongs to a cold start, and a relaunch is a cold start.
    @State private var showingSplash = true

    var body: some View {
        Group {
            if showingSplash {
                SplashView { showingSplash = false }
                    .transition(.opacity)
            } else if shouldShowOnboarding {
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
                            case .capture(let role): CaptureView(role: role)
                            case .processing: ProcessingView()
                            case .results: ResultsView()
                            case .report: PipelineReportView()
                            case .tuning: TuningPanelView()
                            }
                        }
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: shouldShowOnboarding)
        .animation(.easeInOut(duration: 0.35), value: showingSplash)
    }

    /// First install only. The debug override is opt-in — see
    /// `OnboardingConfiguration.alwaysShowOnLaunch`.
    private var shouldShowOnboarding: Bool {
        guard !completedOnboardingThisLaunch else { return false }
        return OnboardingConfiguration.alwaysShowOnLaunch || !hasCompletedOnboarding
    }
}
