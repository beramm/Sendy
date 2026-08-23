import SwiftUI

/// Shared motion-driven presentation used by the Welcome and Loading pages.
/// The page-specific wrappers live in their own files and own their previews.
struct ShakeOnboardingPage: View {
    let firstLine: String
    let accentLine: String
    let showsPrompt: Bool
    let usesWelcomeEntrance: Bool
    let motion: OnboardingMotionController
    let onEntranceCompleted: () -> Void
    let onShakeCompleted: () -> Void

    @State private var entranceHasStarted = false
    @State private var entranceScale: CGFloat = 10
    @State private var greenBackdropOpacity = 1.0
    @State private var headlineOpacity = 0.0
    @State private var motionWavesOpacity = 0.0
    @State private var promptOpacity = 0.0
    @State private var isPlayingExit = false
    @State private var frozenClimberTranslation = CGSize.zero
    @State private var frozenClimberRotation = 0.0
    @State private var frozenWaveTranslation = CGSize.zero
    @State private var frozenWaveRotation = 0.0
    @State private var fallOffset = CGSize.zero
    @State private var fallRotation = 0.0
    @State private var climberExitOpacity = 1.0
    @State private var supportingContentOpacity = 1.0
    @State private var supportingContentOffset = 0.0
    @State private var wavesExitOpacity = 1.0
    @State private var standardEntrancePhase = OnboardingPageAnimationPhase.beforeEntrance

    var body: some View {
        ZStack {
            OnboardingDesignCanvas {
                ZStack(alignment: .topLeading) {
                    OnboardingHeadline(
                        lines: [
                            .init(firstLine, color: .white),
                            .init(accentLine, color: AppTheme.accent)
                        ]
                    )
                    .offset(x: 42, y: 104 + supportingContentOffset)
                    .opacity(
                        (usesWelcomeEntrance ? headlineOpacity : 1)
                            * supportingContentOpacity
                    )
                    .onboardingPageAnimation(
                        .headline,
                        phase: standardEntrancePhase,
                        isEnabled: !usesWelcomeEntrance
                    )

                    jigglingArtwork
                        .onboardingPageAnimation(
                            .artwork,
                            phase: standardEntrancePhase,
                            isEnabled: !usesWelcomeEntrance
                        )

                    if showsPrompt {
                        Text("Shake me!")
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(8))
                            .offset(x: 198, y: 619 + supportingContentOffset)
                            .opacity(
                                (usesWelcomeEntrance ? promptOpacity : 1)
                                    * supportingContentOpacity
                            )
                    }
                }
            }
            
            if usesWelcomeEntrance {
                AppTheme.accent
                    .opacity(greenBackdropOpacity)
                    .ignoresSafeArea()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(firstLine) \(accentLine). Shake your phone to continue.")
        .accessibilityAction(named: "Continue") {
            Task { await handleShake() }
        }
        .task {
            await playEntranceIfNeeded()
        }
        .onChange(of: motion.shakeEvent) {
            Task { await handleShake() }
        }
    }

    private var jigglingArtwork: some View {
        ZStack(alignment: .topLeading) {
            Image("JigglingClimberIllustration")
                .resizable()
                .scaledToFit()
                .frame(width: 330, height: 366)
                .rotationEffect(
                    .degrees(climberShakeRotation + fallRotation),
                    anchor: .center
                )
                .offset(
                    x: 36 + climberShakeTranslation.width + fallOffset.width,
                    y: 280 + climberShakeTranslation.height + fallOffset.height
                )
                .frame(width: 402, height: 874, alignment: .topLeading)
                .scaleEffect(usesWelcomeEntrance ? entranceScale : 1, anchor: .center)
                .opacity(climberExitOpacity)

            motionWaves
                .frame(width: 402, height: 874, alignment: .topLeading)
                .offset(
                    x: waveShakeTranslation.width,
                    y: waveShakeTranslation.height + supportingContentOffset
                )
                .rotationEffect(.degrees(waveShakeRotation), anchor: .center)
                .opacity(
                    (usesWelcomeEntrance ? motionWavesOpacity : 1)
                        * supportingContentOpacity
                        * wavesExitOpacity
                )
        }
        .frame(width: 402, height: 874, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var motionWaves: some View {
        ZStack(alignment: .topLeading) {
            Image("MotionWaves")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 98)
                .scaleEffect(x: -1)
                .rotationEffect(Angle(degrees: -20))
                .offset(x: 65, y: 457)

            Image("MotionWaves")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 98)
                .offset(x: 284, y: 412)
        }
    }

    private var motionWavesFollowClimber: Bool {
        switch OnboardingConfiguration.motionWaveMovement {
        case .shakeWithClimber: true
        case .stationary: false
        }
    }

    private var climberShakeTranslation: CGSize {
        if isPlayingExit { return frozenClimberTranslation }
        return motion.visualTranslation
    }

    private var climberShakeRotation: Double {
        if isPlayingExit { return frozenClimberRotation }
        return motion.visualRotation
    }

    private var waveShakeTranslation: CGSize {
        if isPlayingExit { return frozenWaveTranslation }
        return motionWavesFollowClimber
            ? motion.visualTranslation
            : .zero
    }

    private var waveShakeRotation: Double {
        if isPlayingExit { return frozenWaveRotation }
        return motionWavesFollowClimber
            ? motion.visualRotation
            : 0
    }

    private func playEntranceIfNeeded() async {
        guard !entranceHasStarted else { return }
        entranceHasStarted = true

        guard usesWelcomeEntrance else {
            await Task.yield()
            guard !Task.isCancelled else { return }
            standardEntrancePhase = .visible

            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            onEntranceCompleted()
            return
        }

        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(duration: 1, bounce: 0.12)) {
            entranceScale = 1
        }
        withAnimation(.easeInOut(duration: 0.85)) {
            greenBackdropOpacity = 0
        }

        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.8)) {
            headlineOpacity = 1
            motionWavesOpacity = 1
        }

        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.65)) {
            promptOpacity = 1
        }

        try? await Task.sleep(for: .milliseconds(650))
        guard !Task.isCancelled else { return }
        onEntranceCompleted()
    }

    private func handleShake() async {
        guard !isPlayingExit else { return }

        frozenClimberTranslation = motion.visualTranslation
        frozenClimberRotation = motion.visualRotation
        frozenWaveTranslation = motionWavesFollowClimber ? motion.visualTranslation : .zero
        frozenWaveRotation = motionWavesFollowClimber ? motion.visualRotation : 0
        motion.disarmShakeDetection()
        motion.stop()
        isPlayingExit = true

        // The waves leave first, as a distinct beat before the climber drops.
        withAnimation(.easeOut(duration: 0.22)) {
            wavesExitOpacity = 0
        }

        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 0.52)) {
            fallOffset = CGSize(width: 0, height: 660)
            fallRotation = motion.shakeFallRotation
        }
        withAnimation(.easeOut(duration: 0.46)) {
            climberExitOpacity = 0
            supportingContentOpacity = 0
            supportingContentOffset = -24
        }

        // The longest exit above is 0.52s. Waiting 0.72s guarantees a full
        // 0.2s of the empty onboarding background before the next page enters.
        try? await Task.sleep(for: .milliseconds(720))
        guard !Task.isCancelled else { return }
        onShakeCompleted()
    }
}
