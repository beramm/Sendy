import SwiftUI

enum OnboardingConfiguration {
    static let alwaysShowOnLaunch = true
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case levelUp
    case moveBetter
    case sideBySide
    case ready
}

struct OnboardingFlowView: View {
    let onFinished: () -> Void

    @State private var step: OnboardingStep
    @State private var motion = OnboardingMotionController()
    @State private var isAdvancing = false

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
#if DEBUG
        let requestedStep = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--onboarding-step=") }
            .flatMap { Int($0.split(separator: "=").last ?? "") }
            .flatMap(OnboardingStep.init(rawValue:))
        _step = State(initialValue: requestedStep ?? .welcome)
#else
        _step = State(initialValue: .welcome)
#endif
    }

    var body: some View {
        ZStack {
            AppBackground()

            page
                .id(step)

            if let completedSteps {
                OnboardingDesignCanvas {
                    ZStack(alignment: .topLeading) {
                        OnboardingProgressIndicator(
                            completedSteps: completedSteps
                        )
                        .offset(x: 45, y: 61)
                    }
                }
                .allowsHitTesting(false)
            }

            DeviceShakeDetector {
                motion.registerSystemShake()
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            configureMotion(for: step)
        }
        .onDisappear {
            motion.stop()
        }
        .onChange(of: step) { _, newStep in
            configureMotion(for: newStep)
        }
    }

    private var completedSteps: Int? {
        switch step {
        case .welcome, .ready: nil
        case .levelUp: 1
        case .moveBetter: 2
        case .sideBySide: 3
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            WelcomeOnboardingPage(
                motion: motion,
                onEntranceCompleted: {
                    motion.start()
                    motion.armShakeDetection()
                },
                onCompleted: advance
            )
        case .levelUp:
            LevelUpOnboardingPage(action: advance)
        case .moveBetter:
            MoveBetterOnboardingPage(action: advance)
        case .sideBySide:
            SideBySideOnboardingPage(action: advance)
        case .ready:
            ReadyOnboardingPage(action: advance)
        }
    }

    private func configureMotion(for newStep: OnboardingStep) {
        if newStep == .welcome {
            motion.finishAlignment()
            motion.pauseForEntrance()
        } else {
            motion.disarmShakeDetection()
            motion.finishAlignment()
            motion.stop()
        }
    }

    private func advance() {
        guard !isAdvancing else { return }
        isAdvancing = true
        guard let nextStep = OnboardingStep(rawValue: step.rawValue + 1) else {
            onFinished()
            return
        }

        step = nextStep
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            isAdvancing = false
        }
    }
}
