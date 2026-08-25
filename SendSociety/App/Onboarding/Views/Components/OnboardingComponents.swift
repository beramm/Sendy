import SwiftUI

struct OnboardingHeadlineLine {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
}

struct OnboardingHeadline: View {
    let lines: [OnboardingHeadlineLine]

    var body: some View {
        VStack(alignment: .leading, spacing: -4) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                Text(line.text)
                    .foregroundStyle(line.color)
                    .lineLimit(1)
            }
        }
        // .largeTitle scales with the user's Dynamic Type setting instead of
        // locking every device/user to a 48pt headline.
        .font(.system(.largeTitle, design: .monospaced).weight(.medium))
        .tracking(-1.2)
    }
}

enum OnboardingPageAnimationPhase: Equatable {
    case beforeEntrance
    case visible
    case exiting
}

enum OnboardingPageAnimationRole: Equatable {
    case headline
    case artwork
    case supportingContent
    case button

    var entranceDelay: TimeInterval {
        switch self {
        case .headline: 0.04
        case .artwork: 0.13
        case .supportingContent: 0.2
        case .button: 0.27
        }
    }

    var travel: CGFloat {
        switch self {
        case .headline, .button: 42
        case .artwork: 64
        case .supportingContent: 50
        }
    }
}

struct OnboardingPageAnimationContext {
    let phase: OnboardingPageAnimationPhase
    let action: () -> Void
}

/// Runs the page's fade-and-move exit to completion, holds on the empty
/// onboarding background for 0.2 seconds, and only then advances the flow.
struct AnimatedOnboardingPage<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (OnboardingPageAnimationContext) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = OnboardingPageAnimationPhase.beforeEntrance

    var body: some View {
        content(
            OnboardingPageAnimationContext(
                phase: phase,
                action: playExit
            )
        )
        .task {
            await Task.yield()
            guard phase == .beforeEntrance, !Task.isCancelled else { return }
            phase = .visible
        }
    }

    private func playExit() {
        guard phase == .visible else { return }
        phase = .exiting

        Task { @MainActor in
            // Reduced Motion uses a 0.2s fade; the normal fade/move is 0.4s.
            // Both then remain fully transparent for another 0.2s.
            let delay = reduceMotion ? 400 : 600
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

private struct OnboardingPageElementAnimation: ViewModifier {
    let role: OnboardingPageAnimationRole
    let phase: OnboardingPageAnimationPhase
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        !isEnabled || phase == .visible
    }

    private var horizontalOffset: CGFloat {
        guard isEnabled, !reduceMotion else { return 0 }
        return switch phase {
        case .beforeEntrance: role.travel
        case .visible: 0
        case .exiting: -role.travel * 0.4
        }
    }

    private var scale: CGFloat {
        guard isEnabled, !reduceMotion else { return 1 }
        if phase == .beforeEntrance, role == .artwork { return 0.92 }
        if phase == .exiting, role == .artwork { return 0.98 }
        return 1
    }

    private var animation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.2)
        }

        switch phase {
        case .beforeEntrance:
            return .linear(duration: 0)
        case .visible:
            return .spring(response: 0.58, dampingFraction: 0.82)
                .delay(role.entranceDelay)
        case .exiting:
            return .easeInOut(duration: 0.4)
        }
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(x: horizontalOffset)
            .scaleEffect(scale)
            .animation(isEnabled ? animation : nil, value: phase)
    }
}

extension View {
    func onboardingPageAnimation(
        _ role: OnboardingPageAnimationRole,
        phase: OnboardingPageAnimationPhase,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            OnboardingPageElementAnimation(
                role: role,
                phase: phase,
                isEnabled: isEnabled
            )
        )
    }
}

/// All reference comps use a 402 × 874 canvas. This preserves their measured
/// layout on current phones, scales down on compact phones, and stays centered
/// instead of becoming tablet-sized on iPad.
struct OnboardingDesignCanvas<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / 402,
                proxy.size.height / 874,
                1.2
            )

            content()
                .frame(width: 402, height: 874, alignment: .topLeading)
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

struct IllustratedOnboardingPage: View {
    let lines: [OnboardingHeadlineLine]
    let headlineOffset: CGPoint
    let imageName: String
    let imageSize: CGSize
    let imageOffset: CGPoint
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        AnimatedOnboardingPage(action: action) { animation in
            OnboardingDesignCanvas {
                ZStack(alignment: .topLeading) {
                    OnboardingHeadline(lines: lines)
                        .offset(x: headlineOffset.x, y: headlineOffset.y)
                        .onboardingPageAnimation(.headline, phase: animation.phase)

                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageSize.width, height: imageSize.height)
                        .offset(x: imageOffset.x, y: imageOffset.y)
                        .accessibilityHidden(true)
                        .onboardingPageAnimation(.artwork, phase: animation.phase)

                    PrimaryButton(title: buttonTitle, action: animation.action)
                        .offset(x: 45, y: 755)
                        .onboardingPageAnimation(.button, phase: animation.phase)
                }
            }
        }
    }
}

struct OnboardingProgressIndicator: View {
    let completedSteps: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(1 ... 3, id: \.self) { step in
                Capsule()
                    .fill(
                        step <= completedSteps
                            ? AppTheme.accent
                            : Color.white.opacity(0.17)
                    )
                    .frame(width: 97.67)
                    .animation(
                        .easeInOut(duration: 0.25),
                        value: completedSteps
                    )
            }
        }
        .frame(width: 313, height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding step \(completedSteps) of 3")
    }
}

struct OnboardingBodyCopy: View {
    let text: Text
    let width: CGFloat

    var body: some View {
        text
            // The system face resolves to SF Pro on iOS. This fixed 15-point
            // treatment intentionally matches the supplied onboarding comps.
            .font(.system(size: 15))
            .foregroundStyle(Color.white.opacity(0.55))
            .lineSpacing(0)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct FeatureOnboardingPage: View {
    let lines: [OnboardingHeadlineLine]
    let headlineOffset: CGPoint
    let bodyCopy: Text
    let bodyOffset: CGPoint
    let bodyWidth: CGFloat
    let imageName: String
    let imageSize: CGSize
    let imageOffset: CGPoint
    let action: () -> Void

    var body: some View {
        AnimatedOnboardingPage(action: action) { animation in
            OnboardingDesignCanvas {
                ZStack(alignment: .topLeading) {
                    OnboardingHeadline(lines: lines)
                        .offset(x: headlineOffset.x, y: headlineOffset.y)
                        .onboardingPageAnimation(.headline, phase: animation.phase)

                    OnboardingBodyCopy(text: bodyCopy, width: bodyWidth)
                        .offset(x: bodyOffset.x, y: bodyOffset.y)
                        .onboardingPageAnimation(
                            .supportingContent,
                            phase: animation.phase
                        )

                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageSize.width, height: imageSize.height)
                        .offset(x: imageOffset.x, y: imageOffset.y)
                        .accessibilityHidden(true)
                        .onboardingPageAnimation(.artwork, phase: animation.phase)

                    PrimaryButton(title: "NEXT", action: animation.action)
                        .offset(x: 45, y: 755)
                        .onboardingPageAnimation(.button, phase: animation.phase)
                }
            }
        }
    }
}

struct OnboardingPreviewContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            AppBackground()
            content()
        }
        .preferredColorScheme(.dark)
    }
}
