import SwiftUI

enum OnboardingShakeMovement {
    case horizontal
    case vertical
    case both
}

enum OnboardingShakeRotation {
    case on
    case off
}

enum OnboardingShakeTriggerMode {
    case accelerationThreshold
    case sustainedDuration
}

enum OnboardingMotionWaveMovement {
    case shakeWithClimber
    case stationary
}

enum OnboardingConfiguration {
    /// Forces onboarding even though it has already been completed.
    ///
    /// **Opt-in, never on by default.** Onboarding is a first-install
    /// experience: once `hasCompletedOnboarding` is set it stays set for the
    /// life of the install, across relaunches and app updates, and is cleared
    /// only by deleting the app. A debug build that showed it on every launch
    /// made that impossible to verify — the persisted path never ran during
    /// development, which is the one place it would have been noticed if it
    /// were broken.
    ///
    /// Pass `--show-onboarding` in the scheme's launch arguments to see the
    /// flow again without deleting the app or editing this file:
    ///
    ///     xcrun simctl launch <device> <bundle-id> --show-onboarding
#if DEBUG
    static let alwaysShowOnLaunch = true
#else
    static let alwaysShowOnLaunch = false
#endif

    /// Development switch for testing the artwork's shake direction.
    /// Change this to `.horizontal`, `.vertical`, or `.both`.
    static let shakeMovement: OnboardingShakeMovement = .both

    /// Development switch for testing rotation during the shake animation.
    /// Change this to `.on` or `.off`.
    static let shakeRotation: OnboardingShakeRotation = .off

    /// Development switch for deciding when a shake completes the page.
    /// Use `.accelerationThreshold` for one hard shake or `.sustainedDuration`
    /// to require continuous shaking for `sustainedShakeDuration` seconds.
    static let shakeTriggerMode: OnboardingShakeTriggerMode = .sustainedDuration
    static let sustainedShakeDuration: TimeInterval = 1

    /// Development switch for testing whether the motion waves also shake.
    /// Change this to `.shakeWithClimber` or `.stationary`.
    static let motionWaveMovement: OnboardingMotionWaveMovement = .stationary
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case setup
    case goClimb
    case betterClimber
    case analyze
    case alignRoute
    case loading
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
        case .setup:
            SetupOnboardingPage(action: advance)
        case .goClimb:
            GoClimbOnboardingPage(action: advance)
        case .betterClimber:
            BetterClimberOnboardingPage(action: advance)
        case .analyze:
            AnalyzeOnboardingPage(action: advance)
        case .alignRoute:
            AlignRouteOnboardingPage(motion: motion, action: advance)
        case .loading:
            LoadingOnboardingPage(
                motion: motion,
                onEntranceCompleted: {
                    motion.armShakeDetection()
                },
                onCompleted: advance
            )
        }
    }

    private func configureMotion(for newStep: OnboardingStep) {
        if newStep == .welcome {
            motion.finishAlignment()
            motion.pauseForEntrance()
        } else if newStep == .loading {
            motion.start()
            motion.finishAlignment()
            motion.disarmShakeDetection()
        } else if newStep == .alignRoute {
            motion.start()
            motion.disarmShakeDetection()
            motion.prepareForAlignment()
        } else {
            motion.disarmShakeDetection()
            motion.finishAlignment()
            motion.stop()
        }
    }

    private func advance() {
        guard !isAdvancing else { return }
        if step == .alignRoute, !motion.isAligned { return }

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
