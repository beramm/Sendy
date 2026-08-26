import SwiftUI

/// Working name only. Not final — never hardcode it in user-facing strings.
/// Must stay in step with `INFOPLIST_KEY_CFBundleDisplayName`, which is what
/// the home screen shows; this is the name used inside the app.
enum AppNaming {
    static let displayName = String(localized: "Sendyy", comment: "Working name of the app")
}

enum OnboardingStorage {
    static let completionKey = "hasCompletedOnboarding"
}

@main
struct SendSocietyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                // Debug scaffolding, opt-in by launch argument only. Times the
                // on-device model and exits, so a console launch is the whole
                // harness. Never reached in an ordinary launch.
                .task {
                    if ModelLatencyBenchmark.isRequested {
                        await ModelLatencyBenchmark.run()
                        exit(0)
                    }
                    if ModelLatencyBenchmark.seedRequested {
                        await SessionSeeding.run()
                        exit(0)
                    }
                    if ModelLatencyBenchmark.verificationRequested {
                        await NarrationVerification.run()
                        exit(0)
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// Set once, when the first climb is saved, and never cleared by the app.
    ///
    /// `UserDefaults` lives in the app's container, so this survives relaunches
    /// and app updates and goes away only when the app is deleted — which is
    /// exactly "show it on first install and never again".
    @AppStorage(OnboardingStorage.completionKey) private var hasCompletedOnboarding = false
    /// Finishing the pages opens a draft immediately, but onboarding is not
    /// persisted as complete until that first climb is actually saved. This
    /// keeps the pages dismissed while the draft is edited during this launch.
    @State private var finishedOnboardingThisLaunch = false
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
                    guard await model.newSession(name: nil) else { return false }
                    finishedOnboardingThisLaunch = true
                    return true
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
        guard !finishedOnboardingThisLaunch else { return false }
        return OnboardingConfiguration.alwaysShowOnLaunch || !hasCompletedOnboarding
    }
}
